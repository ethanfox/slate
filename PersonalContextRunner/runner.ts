import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { Agent, type Run, type SDKAgent, type SDKCustomTool, type SDKCustomToolResult } from "@cursor/sdk";

type Request = {
  apiKey: string;
  env: Record<string, string>;
  agentId?: string;
  name: string;
  text: string;
  model?: string;
  cwd: string;
  mcpCommand: string;
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
  process.stdout.write(JSON.stringify(event) + "\n");
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
  return recordsFrom(unwrapResult(result) ?? args)
    .slice(0, pin ? 1 : 8)
    .map((record) => ({
      id: record.id ?? record.url ?? record.title,
      title: record.title,
      url: record.url,
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
async function slateTools(command: string): Promise<Record<string, SDKCustomTool>> {
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
  return Object.fromEntries(
    tools.map((tool) => [
      tool.name,
      {
        description: tool.description,
        inputSchema: tool.inputSchema,
        annotations: tool.annotations,
        execute: async (args) => {
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

async function readRequest(): Promise<Request> {
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;
  return JSON.parse(raw) as Request;
}

async function main() {
  const request = await readRequest();
  Object.assign(process.env, request.env);
  const apiKey = request.apiKey;
  if (!apiKey) throw new Error("Add a Cursor API key in Settings.");

  const options = {
    apiKey,
    model: { id: request.model || "auto" },
    local: { cwd: request.cwd, settingSources: [], customTools: await slateTools(request.mcpCommand) },
    tools: ["mcp", "webSearch", "webFetch"],
  };

  const agent: SDKAgent = request.agentId
    ? await Agent.resume(request.agentId, options)
    : await Agent.create({ ...options, name: request.name.slice(0, 100) });
  emit({ type: "agent", agentId: agent.agentId });
  log("agent", { agentId: agent.agentId, resumed: Boolean(request.agentId), model: options.model, cwd: request.cwd });

  let run: Run | undefined;
  const stop = async () => {
    try {
      if (run?.supports("cancel")) await run.cancel();
    } finally {
      process.exit(130);
    }
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);

  run = await agent.send(request.text);
  log("run", { runId: run.id });
  let lastAssistant = "";
  for await (const message of run.stream()) {
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
  const result = await run.wait();
  if (result.status !== "finished") log("result", result);
  emit({ type: "result", status: result.status, text: result.result, error: result.error?.message });
  agent.close();
}

main().then(
  () => process.exit(0),
  (error: unknown) => {
    log("failed", error);
    emit({ type: "error", message: error instanceof Error ? error.message : String(error) });
    process.exit(1);
  },
);
