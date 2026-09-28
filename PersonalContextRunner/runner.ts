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

type Event =
  | { type: "agent"; agentId: string }
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "tool"; name: string; status: string }
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
        execute: async (args) => (await call("tools/call", { name: tool.name, arguments: args })) as SDKCustomToolResult,
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
  for await (const message of run.stream()) {
    if (message.type !== "assistant" && message.type !== "thinking") log(message.type, message);
    switch (message.type) {
      case "assistant":
        for (const block of message.message.content) {
          if (block.type === "text" && block.text) emit({ type: "text", text: block.text });
        }
        break;
      case "thinking":
        if (message.text) emit({ type: "thinking", text: message.text });
        break;
      case "tool_call":
        if (message.status !== "running") {
          emit({ type: "tool", name: toolName(message.name, message.args), status: message.status });
        }
        break;
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
