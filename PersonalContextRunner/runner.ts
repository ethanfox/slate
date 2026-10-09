import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readAttachedFile, recordReadProvenance } from "./source-read";
import { writeSync } from "node:fs";
import { mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { Agent, type Run, type SDKAgent, type SDKCustomTool, type SDKCustomToolResult } from "@cursor/sdk";

const runFile = promisify(execFile);

type Request = {
  apiKey: string;
  env: Record<string, string>;
  agentId?: string;
  name: string;
  text: string;
  model?: string;
  cwd: string;
  mcpCommand: string;
  codeRoots: { title: string; locator?: string; path: string }[];
  includeSlateTools: boolean;
  includeProjectTools: boolean;
  includeWorkerTool?: boolean;
  includeFinishRun?: boolean;
  allowedTools?: string[];
  runtime: "local" | "cloud";
  cloudRepos: { url: string; startingRef?: string }[];
  codeSnapshots: {
    title: string;
    locator: string;
    kind: string;
    branch: string;
    token?: string;
    path: string;
    archiveURL?: string;
    commitsURL?: string;
  }[];
  readProvenancePath?: string;
};

type Source = { id?: string; title: string; url?: string; kind: string; pin?: boolean };

type Event =
  | { type: "agent"; agentId: string }
  | { type: "text"; text: string }
  | { type: "break" }
  | { type: "thinking"; text: string }
  | { type: "status"; status: string }
  | { type: "tool"; name: string; status: string; id?: string; detail?: string; sources?: Source[] }
  | { type: "result"; status: string; text?: string; error?: string }
  | { type: "host_tool"; name: string; id: string; text?: string }
  | { type: "error"; message: string };

function log(label: string, value: unknown) {
  process.stderr.write(`${label}: ${describe(value)}\n`);
}

function describe(value: unknown): string {
  if (value instanceof Error) {
    const fields = Object.fromEntries(Object.entries(value));
    const cause = value.cause === undefined ? "" : `\ncause: ${describe(value.cause)}`;
    return `${value.name}: ${value.message} ${JSON.stringify(fields)}\n${value.stack ?? ""}${cause}`;
  }
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function emit(event: Event) {
  writeSync(1, `${JSON.stringify(event)}\n`);
}

function isBusy(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /already has active run|agent_busy|AgentBusy/i.test(message);
}

async function expireActiveRuns(agentId: string, cwd: string) {
  try {
    const { items } = await Agent.listRuns(agentId, { runtime: "local", cwd });
    for (const item of items) {
      const status = String(item.status ?? "");
      if (!/running|creating|pending|started/i.test(status)) continue;
      try {
        await Agent.cancelRun(item.id, { runtime: "local", cwd });
        log("cancelRun", { id: item.id, status });
      } catch (error) {
        log("cancelRun failed", error);
      }
    }
  } catch (error) {
    log("listRuns failed", error);
  }
}

async function startRun(agent: SDKAgent, request: Request): Promise<Run> {
  if (request.runtime === "cloud") return await agent.send(request.text);
  const options = { local: { force: true } };
  try {
    return await agent.send(request.text, options);
  } catch (error) {
    if (!isBusy(error)) throw error;
    log("busy", { agentId: agent.agentId, error: describe(error) });
    await expireActiveRuns(agent.agentId, request.cwd);
    return await agent.send(request.text, options);
  }
}

function toolName(name: string, args: unknown): string {
  if (name !== "mcp" || typeof args !== "object" || args === null) return name;
  const fields = args as Record<string, unknown>;
  for (const key of ["toolName", "tool_name", "name", "tool"]) {
    if (typeof fields[key] === "string") return fields[key] as string;
  }
  return name;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function field(record: Record<string, unknown> | undefined, ...keys: string[]): string | undefined {
  if (!record) return undefined;
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return undefined;
}

function unwrapResult(result: unknown): unknown {
  const record = asRecord(result);
  const content = record?.content;
  if (Array.isArray(content)) {
    const text = content
      .map((block) => (typeof block === "object" && block && "text" in block ? String((block as { text?: unknown }).text ?? "") : ""))
      .join("\n")
      .trim();
    if (!text) return result;
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }
  return result;
}

function titlesFrom(value: unknown): string[] {
  if (typeof value === "string") return value.length > 80 ? [`${value.slice(0, 77)}…`] : [value];
  if (Array.isArray(value)) return value.flatMap((item) => titlesFrom(item)).filter(Boolean);
  const record = asRecord(value);
  if (!record) return [];
  const title = field(record, "title", "name", "query", "url");
  return title ? [title] : [];
}

function toolDetail(name: string, args: unknown, result?: unknown): string {
  const fields = asRecord(args);
  if (name === "webSearch") return field(fields, "query", "search", "q") ?? "";
  if (name === "webFetch" || name === "WebFetch") return field(fields, "url", "href") ?? "";
  const fromResult = titlesFrom(unwrapResult(result)).slice(0, 4);
  if (fromResult.length) return fromResult.join(" · ");
  return field(fields, "title", "name", "query", "url") ?? "";
}

function hostName(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

function kindFromTool(name: string): Source["kind"] | undefined {
  const n = name.toLowerCase();
  if (n.includes("note")) return "note";
  if (n.includes("thread")) return "thread";
  if (n.includes("decision")) return "decision";
  if (n.includes("project")) return "project";
  return undefined;
}

function urlsFrom(value: unknown): string[] {
  if (typeof value === "string") {
    return (value.match(/https?:\/\/[^\s"'<>]+/g) ?? []).map((url) => url.replace(/[.,);]+$/, ""));
  }
  if (Array.isArray(value)) return [...new Set(value.flatMap(urlsFrom))];
  const record = asRecord(value);
  if (!record) return [];
  const url = field(record, "url", "href", "link");
  const rest = Object.values(record).flatMap(urlsFrom);
  return [...new Set(url ? [url, ...rest] : rest)];
}

function recordsFrom(value: unknown): { id?: string; title: string; url?: string }[] {
  if (Array.isArray(value)) return value.flatMap(recordsFrom);
  const record = asRecord(value);
  if (!record) return [];
  const title = field(record, "title", "name");
  const id = field(record, "id");
  const rawURL = field(record, "url", "href", "source");
  const url = rawURL?.startsWith("http") ? rawURL : undefined;
  if (title || url) return [{ id, title: title ?? hostName(url ?? ""), url }];
  return Object.values(record).flatMap(recordsFrom);
}

function sourcesFrom(name: string, args: unknown, result?: unknown): Source[] {
  const n = name.toLowerCase();
  if (n === "webfetch") {
    const url = field(asRecord(args), "url", "href") ?? urlsFrom(unwrapResult(result))[0];
    return url ? [{ id: url, title: hostName(url), url, kind: "url", pin: true }] : [];
  }
  if (n === "websearch") {
    return urlsFrom(unwrapResult(result))
      .slice(0, 4)
      .map((url) => ({ id: url, title: hostName(url), url, kind: "url", pin: true }));
  }
  const kind = kindFromTool(name);
  if (!kind) return [];
  const pin = n.startsWith("get_");
  return recordsFrom(unwrapResult(result))
    .filter((record) => record.id)
    .slice(0, pin ? 1 : 8)
    .map((record) => ({
      id: record.id,
      title: record.title,
      url: record.url ?? `slate://${kind}/${record.id}`,
      kind,
      pin,
    }));
}

function toolEvent(name: string, status: string, args?: unknown, result?: unknown, id?: string): Event {
  const detail = toolDetail(name, args, result);
  const sources = sourcesFrom(name, args, result);
  return {
    type: "tool",
    name,
    status,
    id,
    ...(detail ? { detail } : {}),
    ...(sources.length ? { sources } : {}),
  };
}

type McpTool = { name: string; description?: string; inputSchema?: SDKCustomTool["inputSchema"]; annotations?: SDKCustomTool["annotations"] };

/** Runs the Slate MCP as a child and exposes its tools in-process, since MCP server calls need an approval a headless run can't give. */
async function slateTools(command: string, allowed?: string[]): Promise<Record<string, SDKCustomTool>> {
  const child = spawn(command, [], { stdio: ["pipe", "pipe", "inherit"] });
  const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  let nextId = 1;
  createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error.message));
    else waiter.resolve(message.result);
  });
  child.on("exit", (code) => {
    for (const waiter of pending.values()) waiter.reject(new Error(`Slate MCP exited (${code}).`));
    pending.clear();
  });
  const call = (method: string, params: unknown): Promise<any> =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });

  await call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "slate-runner", version: "1.0" } });
  const { tools } = (await call("tools/list", {})) as { tools: McpTool[] };
  const allow = allowed?.length ? new Set(allowed) : null;
  return Object.fromEntries(
    tools
      .filter((tool) => !allow || allow.has(tool.name))
      .map((tool) => [
        tool.name,
        {
          description: tool.description,
          inputSchema: tool.inputSchema,
          annotations: tool.annotations,
          execute: async (args) => {
            if (allow && !allow.has(tool.name)) {
              throw new Error(`This run cannot use ${tool.name}.`);
            }
            emit(toolEvent(tool.name, "running", args));
            try {
              const result = (await call("tools/call", { name: tool.name, arguments: args })) as SDKCustomToolResult;
              emit(toolEvent(tool.name, "completed", args, result));
              return result;
            } catch (error) {
              emit(toolEvent(tool.name, "error", args));
              throw error;
            }
          },
        } satisfies SDKCustomTool,
      ]),
  );
}

const ignoredDirectories = new Set([".git", ".build", "build", "DerivedData", "node_modules", ".swiftpm"]);

async function projectFiles(roots: Request["codeRoots"], limit = 2000): Promise<{ root: string; absolute: string; relative: string }[]> {
  const output: { root: string; absolute: string; relative: string }[] = [];
  const visit = async (root: Request["codeRoots"][number], folder: string) => {
    if (output.length >= limit) return;
    let entries;
    try {
      entries = await readdir(folder, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (output.length >= limit || entry.name.startsWith(".") && entry.name !== ".github") continue;
      const absolute = resolve(folder, entry.name);
      if (entry.isDirectory()) {
        if (!ignoredDirectories.has(entry.name)) await visit(root, absolute);
      } else if (entry.isFile()) {
        output.push({ root: root.title, absolute, relative: relative(root.path, absolute) });
      }
    }
  };
  for (const root of roots) await visit(root, root.path);
  return output;
}

function rootMatches(root: { title: string; locator?: string; path: string }, requested: string): boolean {
  const needle = requested.trim().toLowerCase();
  if (!needle) return false;
  const title = root.title.toLowerCase();
  const locator = (root.locator ?? "").toLowerCase();
  const path = root.path.toLowerCase();
  return title === needle || locator === needle || path === needle
    || title.endsWith(`/${needle}`) || locator.endsWith(`/${needle}`) || path.endsWith(`/${needle}`);
}

function selectedRoots(roots: Request["codeRoots"], requested?: unknown) {
  if (typeof requested === "string" && requested.trim()) {
    const matches = roots.filter((root) => rootMatches(root, requested));
    if (matches.length) return matches;
    return roots.length === 1 ? roots : [];
  }
  return roots;
}

function selectedRoot(roots: Request["codeRoots"], requested?: unknown) {
  return selectedRoots(roots, requested)[0];
}

function safeFile(root: Request["codeRoots"][number], requested: unknown): string {
  if (typeof requested !== "string" || !requested.trim()) throw new Error("path is required");
  const file = resolve(root.path, requested);
  const rel = relative(resolve(root.path), file);
  if (rel === ".." || rel.startsWith(`..${sep}`)) throw new Error("path is outside the attached repository");
  return file;
}


function toolText(value: unknown): SDKCustomToolResult {
  return { content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) }] } as SDKCustomToolResult;
}

async function commitsForRoot(root: Request["codeRoots"][number]): Promise<Record<string, unknown>[]> {
  try {
    const items = JSON.parse(await readFile(resolve(root.path, ".slate-commits.json"), "utf8"));
    if (Array.isArray(items) && items.length) {
      return items.map((item) => ({ ...(asRecord(item) ?? {}), root: root.title }));
    }
  } catch {
    // Fall through to git on local folders.
  }
  try {
    const { stdout } = await runFile(
      "/usr/bin/git",
      ["-C", root.path, "log", "-20", "--pretty=format:%H%x1f%an%x1f%aI%x1f%s"],
      { timeout: 8000 }
    );
    return String(stdout).split("\n").flatMap((line) => {
      const parts = line.split("\u001f");
      if (parts.length < 4) return [];
      return [{ sha: parts[0], author: parts[1], date: parts[2], message: parts[3], root: root.title }];
    });
  } catch {
    return [];
  }
}

function tipSHA(commits: unknown): string | undefined {
  if (!Array.isArray(commits) || !commits.length) return undefined;
  const first = asRecord(commits[0]);
  const sha = field(first, "sha", "id");
  return sha || undefined;
}

async function storedTip(destination: string): Promise<string | undefined> {
  try {
    return tipSHA(JSON.parse(await readFile(resolve(destination, ".slate-commits.json"), "utf8")));
  } catch {
    return undefined;
  }
}

function snapshotHeaders(snapshot: Request["codeSnapshots"][number]): Record<string, string> {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "Slate",
  };
  if (snapshot.token) {
    headers.Authorization = snapshot.kind === "gitlab" ? snapshot.token : `Bearer ${snapshot.token}`;
    if (snapshot.kind === "gitlab") {
      headers["PRIVATE-TOKEN"] = snapshot.token;
      delete headers.Authorization;
    }
  }
  return headers;
}

function normalizeCommits(kind: string, items: unknown): Record<string, string>[] {
  if (!Array.isArray(items)) return [];
  return items.map((item) => {
    const record = asRecord(item) ?? {};
    if (kind === "github") {
      const commit = asRecord(record.commit);
      const author = asRecord(commit?.author);
      return {
        sha: String(record.sha ?? ""),
        message: String(commit?.message ?? ""),
        author: String(author?.name ?? ""),
        date: String(author?.date ?? ""),
        url: String(record.html_url ?? ""),
      };
    }
    return {
      sha: String(record.id ?? ""),
      message: String(record.message ?? record.title ?? ""),
      author: String(record.author_name ?? ""),
      date: String(record.committed_date ?? ""),
      url: String(record.web_url ?? ""),
    };
  });
}

async function fetchJSON(url: string, snapshot: Request["codeSnapshots"][number]): Promise<unknown> {
  const response = await fetch(url, { headers: snapshotHeaders(snapshot) });
  if (!response.ok) throw new Error(`Could not read ${url} (${response.status}).`);
  return await response.json();
}

async function prepareSnapshot(snapshot: Request["codeSnapshots"][number]): Promise<string> {
  let commits: Record<string, string>[] = [];
  try {
    if (snapshot.commitsURL) {
      commits = normalizeCommits(snapshot.kind, await fetchJSON(snapshot.commitsURL, snapshot));
    }
  } catch (error) {
    log("snapshot commits failed", { locator: snapshot.locator, error: describe(error) });
  }
  const tip = tipSHA(commits);
  if (tip && tip === (await storedTip(snapshot.path))) return snapshot.path;
  if (!snapshot.archiveURL) {
    if (tip || (await storedTip(snapshot.path))) return snapshot.path;
    throw new Error(`This attachment cannot be downloaded.`);
  }
  if (!commits.length) {
    try {
      await stat(resolve(snapshot.path, ".slate-snapshot"));
      return snapshot.path;
    } catch {
      // download
    }
  }
  const response = await fetch(snapshot.archiveURL, { headers: snapshotHeaders(snapshot) });
  if (!response.ok) throw new Error(`Could not download ${snapshot.locator} (${response.status}).`);
  const parent = dirname(snapshot.path);
  await mkdir(parent, { recursive: true });
  const archiveFile = join(parent, `${randomUUID()}.zip`);
  const extracted = join(parent, randomUUID());
  await writeFile(archiveFile, Buffer.from(await response.arrayBuffer()));
  try {
    await mkdir(extracted, { recursive: true });
    await runFile("/usr/bin/ditto", ["-x", "-k", archiveFile, extracted]);
    const children = (await readdir(extracted, { withFileTypes: true })).filter((entry) => entry.name !== ".DS_Store");
    const source = children[0] ? join(extracted, children[0].name) : "";
    if (!source) throw new Error("The repository archive was empty.");
    await rm(snapshot.path, { recursive: true, force: true });
    await mkdir(snapshot.path, { recursive: true });
    for (const name of await readdir(source)) {
      await runFile("/bin/mv", [join(source, name), join(snapshot.path, name)]);
    }
    if (commits.length) {
      await writeFile(resolve(snapshot.path, ".slate-commits.json"), JSON.stringify(commits));
    }
    await writeFile(resolve(snapshot.path, ".slate-snapshot"), snapshot.locator);
  } finally {
    await rm(archiveFile, { force: true });
    await rm(extracted, { recursive: true, force: true });
  }
  return snapshot.path;
}

async function prepareCodeRoots(request: Request): Promise<Request["codeRoots"]> {
  const roots = [...(request.codeRoots ?? [])];
  for (const snapshot of request.codeSnapshots ?? []) {
    const path = await prepareSnapshot(snapshot);
    roots.push({ title: snapshot.title, locator: snapshot.locator, path });
  }
  return roots;
}

function asHostRoots(text?: string): Request["codeRoots"] {
  try {
    const parsed = JSON.parse(text ?? "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed.flatMap((item) => {
      const rec = asRecord(item);
      const path = field(rec, "path");
      const title = field(rec, "title") ?? path;
      if (!path || !title) return [];
      return [{ title, locator: field(rec, "locator") ?? "", path }];
    });
  } catch {
    return [];
  }
}

async function resolveRootsFromHost(): Promise<Request["codeRoots"]> {
  const id = randomUUID();
  emit({ type: "host_tool", name: "resolve_project_code_roots", id, text: "" });
  const reply = await readHostReply(id);
  if (reply.error) throw new Error(reply.error);
  return asHostRoots(reply.text);
}

function rootsKey(request: Request): string {
  return JSON.stringify({
    roots: (request.codeRoots ?? []).map((root) => [root.title, root.locator, root.path]),
    snapshots: request.codeSnapshots ?? [],
  });
}

function projectCodeTools(session: { request: Request }): Record<string, SDKCustomTool> {
  let prepared: Promise<Request["codeRoots"]> | undefined;
  let preparedFor = "";
  const rootsFor = () => {
    const key = rootsKey(session.request);
    if (preparedFor !== key) {
      prepared = undefined;
      preparedFor = key;
    }
    prepared ??= (async () => {
      const roots = await prepareCodeRoots(session.request);
      if (roots.length) return roots;
      return resolveRootsFromHost();
    })();
    return prepared;
  };
  return {
    project_list_files: {
      description: "List files in the Slate project's attached code. Read-only.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Optional case-insensitive path filter." },
        },
      },
      execute: async (args) => {
        emit(toolEvent("project_list_files", "running", args));
        const roots = await rootsFor();
        const query = field(asRecord(args), "query")?.toLowerCase() ?? "";
        const files = (await projectFiles(roots))
          .filter((file) => !query || file.relative.toLowerCase().includes(query))
          .slice(0, 300)
          .map((file) => ({ root: file.root, path: file.relative }));
        const result = roots.length ? files : { error: "No code is attached to this Slate project." };
        emit(toolEvent("project_list_files", "completed", args, result));
        return toolText(result);
      },
    },
    project_search_code: {
      description: "Search text in the Slate project's attached code. Read-only.",
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", description: "Text to search for." },
        },
        required: ["query"],
      },
      execute: async (args) => {
        emit(toolEvent("project_search_code", "running", args));
        const roots = await rootsFor();
        const query = field(asRecord(args), "query");
        if (!query) throw new Error("query is required");
        const matches: { root: string; path: string; line: number; text: string }[] = [];
        for (const file of await projectFiles(roots, 1200)) {
          if (matches.length >= 120) break;
          let info;
          try {
            info = await stat(file.absolute);
            if (info.size > 1_000_000) continue;
            const text = await readFile(file.absolute, "utf8");
            for (const [index, line] of text.split(/\r?\n/).entries()) {
              if (line.toLowerCase().includes(query.toLowerCase())) {
                matches.push({ root: file.root, path: file.relative, line: index + 1, text: line.trim().slice(0, 400) });
                if (matches.length >= 120) break;
              }
            }
          } catch {
            continue;
          }
        }
        const result = roots.length ? matches : { error: "No code is attached to this Slate project." };
        emit(toolEvent("project_search_code", "completed", args, result));
        return toolText(result);
      },
    },
    project_read_file: {
      description: "Read a line range from a file in the Slate project's attached code. Read-only.",
      inputSchema: {
        type: "object",
        properties: {
          root: { type: "string", description: "Attachment title. Required when several code roots are attached." },
          path: { type: "string", description: "Path relative to the selected attachment." },
          start_line: { type: "number", description: "First line, starting at 1." },
          end_line: { type: "number", description: "Last line, inclusive." },
        },
        required: ["path"],
      },
      execute: async (args) => {
        emit(toolEvent("project_read_file", "running", args));
        const roots = await rootsFor();
        const fields = asRecord(args);
        const root = selectedRoot(roots, fields?.root);
        if (!root) throw new Error(roots.length ? "Specify root because this project has several code attachments." : "No code is attached to this Slate project.");
        const file = safeFile(root, fields?.path);
        const { hash, text } = await readAttachedFile(file, fields?.start_line, fields?.end_line);
        await recordReadProvenance(session.request.readProvenancePath, fields?.path, hash);
        emit(toolEvent("project_read_file", "completed", args, { root: root.title, path: fields?.path, content_hash: hash }));
        return toolText(text);
      },
    },
    project_git_log: {
      description: "Read recent commits for the Slate project's attached remote repositories. Read-only.",
      inputSchema: {
        type: "object",
        properties: {
          root: { type: "string", description: "Optional attachment title." },
        },
      },
      execute: async (args) => {
        emit(toolEvent("project_git_log", "running", args));
        const roots = await rootsFor();
        const requested = field(asRecord(args), "root");
        const selected = selectedRoots(roots, requested);
        const commits: Record<string, unknown>[] = [];
        for (const root of selected) {
          commits.push(...(await commitsForRoot(root)));
        }
        if (!roots.length) throw new Error("No code is attached to this Slate project.");
        if (!selected.length) throw new Error(`Unknown code root. Use one of: ${roots.map((root) => root.title).join(", ")}.`);
        if (!commits.length) throw new Error("Git history is unavailable for this attachment.");
        emit(toolEvent("project_git_log", "completed", args, commits.slice(0, 40)));
        return toolText(commits.slice(0, 40));
      },
    },
  };
}

const stdinLines = createInterface({ input: process.stdin });
const lineQueue: string[] = [];
const lineWaiters: ((line: string) => void)[] = [];
stdinLines.on("line", (line) => {
  const waiter = lineWaiters.shift();
  if (waiter) waiter(line);
  else lineQueue.push(line);
});

function readStdinLine(): Promise<string> {
  const queued = lineQueue.shift();
  if (queued !== undefined) return Promise.resolve(queued);
  return new Promise((resolve) => lineWaiters.push(resolve));
}

async function readJSON(): Promise<Record<string, unknown>> {
  return JSON.parse(await readStdinLine()) as Record<string, unknown>;
}

async function readHostReply(id: string): Promise<{ text?: string; error?: string }> {
  for (;;) {
    const message = await readJSON();
    if (message.type === "turn" || message.type === "shutdown") {
      lineQueue.unshift(JSON.stringify(message));
      throw new Error("The host ended the tool call.");
    }
    if (message.id === id) {
      return {
        text: typeof message.text === "string" ? message.text : undefined,
        error: typeof message.error === "string" ? message.error : undefined,
      };
    }
  }
}

function asRequest(message: Record<string, unknown>): Request | undefined {
  if (message.type === "host_tool_result" || message.type === "shutdown") return undefined;
  if (message.type === "turn" || message.apiKey || message.text) return message as unknown as Request;
  return undefined;
}

function finishRunTool(): Record<string, SDKCustomTool> {
  return {
    finish_run: {
      description: "Stock the run receipt with a short summary and optional links. Do not complete the assigned task.",
      inputSchema: {
        type: "object",
        properties: {
          summary: { type: "string", description: "What was done." },
          links: {
            type: "array",
            items: {
              type: "object",
              properties: {
                label: { type: "string" },
                url: { type: "string" },
              },
              required: ["url"],
            },
          },
        },
        required: ["summary"],
      },
      execute: async (args) => {
        const id = randomUUID();
        emit({ type: "host_tool", name: "finish_run", id, text: JSON.stringify(args ?? {}) });
        const reply = await readHostReply(id);
        if (reply.error) throw new Error(reply.error);
        return toolText(reply.text ?? "{\"ok\":true}");
      },
    },
  };
}

function workerTool(): Record<string, SDKCustomTool> {
  return {
    consult_code: {
      description:
        "Ask the project's Worker to inspect attached code. Pass a brief. Do not use this for decisions, tracks, or notes — those are Slate tools.",
      inputSchema: {
        type: "object",
        properties: {
          brief: { type: "string", description: "What the Worker should inspect in the attached code." },
        },
        required: ["brief"],
      },
      execute: async (args) => {
        const brief = field(asRecord(args), "brief", "question") ?? "";
        if (!brief) throw new Error("brief is required");
        const id = randomUUID();
        emit({ type: "host_tool", name: "consult_code", id, text: brief });
        const reply = await readHostReply(id);
        if (reply.error) throw new Error(reply.error);
        return toolText(reply.text ?? "");
      },
    },
  };
}

type Session = {
  agent: SDKAgent;
  request: Request;
  run?: Run;
};

const idleMs = 8 * 60 * 1000;

async function createSession(request: Request): Promise<Session> {
  const apiKey = request.apiKey;
  if (!apiKey) throw new Error("Add a Cursor API key in Settings.");
  const session: Session = { agent: undefined as unknown as SDKAgent, request };
  if (request.runtime === "cloud") {
    if (!request.cloudRepos?.length) throw new Error("Attach a GitHub or GitLab repository before using a cloud worker.");
    session.agent = await Agent.create({
      apiKey,
      model: { id: request.model || "auto" },
      cloud: {
        repos: request.cloudRepos,
        autoCreatePR: false,
      },
      tools: ["webSearch", "webFetch"],
      name: request.name.slice(0, 100),
    });
  } else {
    const customTools = {
      ...(request.includeSlateTools ? await slateTools(request.mcpCommand, request.allowedTools) : {}),
      ...(request.includeProjectTools ? projectCodeTools(session) : {}),
      ...(request.includeWorkerTool ? workerTool() : {}),
      ...(request.includeFinishRun ? finishRunTool() : {}),
    };
    const options = {
      apiKey,
      model: { id: request.model || "auto" },
      local: { cwd: request.cwd, settingSources: [], customTools },
      tools: ["mcp", "webSearch", "webFetch"],
    };
    session.agent = request.agentId
      ? await Agent.resume(request.agentId, options)
      : await Agent.create({ ...options, name: request.name.slice(0, 100) });
  }
  emit({ type: "agent", agentId: session.agent.agentId });
  log("agent", {
    agentId: session.agent.agentId,
    resumed: Boolean(request.agentId),
    model: request.model,
    runtime: request.runtime,
    cwd: request.cwd,
  });
  return session;
}

async function handleTurn(session: Session, request: Request) {
  session.request = { ...session.request, ...request };
  session.run = await startRun(session.agent, session.request);
  log("run", { runId: session.run.id });
  let lastAssistant = "";
  for await (const message of session.run.stream()) {
    if (message.type !== "assistant" && message.type !== "thinking") log(message.type, message);
    switch (message.type) {
      case "assistant": {
        let chunk = "";
        for (const block of message.message.content) {
          if (block.type === "text" && block.text) chunk += block.text;
        }
        if (!chunk) break;
        if (lastAssistant && chunk.startsWith(lastAssistant)) {
          const delta = chunk.slice(lastAssistant.length);
          lastAssistant = chunk;
          if (delta) emit({ type: "text", text: delta });
        } else {
          lastAssistant = chunk;
          emit({ type: "text", text: chunk });
        }
        break;
      }
      case "thinking":
        if (message.text) emit({ type: "thinking", text: message.text });
        break;
      case "status":
        emit({ type: "status", status: message.status });
        break;
      case "tool_call": {
        const id = "call_id" in message && typeof message.call_id === "string" ? message.call_id : undefined;
        emit(toolEvent(toolName(message.name, message.args), message.status, message.args, message.result, id));
        break;
      }
    }
  }
  const result = await session.run.wait();
  session.run = undefined;
  if (result.status !== "finished") log("result", result);
  emit({ type: "result", status: result.status, text: result.result, error: result.error?.message });
}

async function main() {
  const first = asRequest(await readJSON());
  if (!first) throw new Error("The runner expected a turn.");
  if (first.env) Object.assign(process.env, first.env);
  const session = await createSession(first);

  const stop = async () => {
    try {
      if (session.run?.supports("cancel")) await session.run.cancel();
    } finally {
      session.agent.close();
      process.exit(130);
    }
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);

  await handleTurn(session, first);

  let idle = setTimeout(() => {
    log("idle stop", {});
    session.agent.close();
    process.exit(0);
  }, idleMs);

  for (;;) {
    const message = await readJSON();
    if (message.type === "shutdown") break;
    const request = asRequest(message);
    if (!request) continue;
    clearTimeout(idle);
    await handleTurn(session, request);
    idle = setTimeout(() => {
      log("idle stop", {});
      session.agent.close();
      process.exit(0);
    }, idleMs);
  }

  clearTimeout(idle);
  session.agent.close();
}

main().then(
  () => process.exit(0),
  (error: unknown) => {
    log("failed", error);
    emit({ type: "error", message: error instanceof Error ? error.message : String(error) });
    process.exit(1);
  },
);
