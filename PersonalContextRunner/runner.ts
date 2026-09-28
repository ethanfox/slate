import { Agent, type McpServerConfig, type Run, type SDKAgent } from "@cursor/sdk";

type Request = {
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

function emit(event: Event) {
  process.stdout.write(JSON.stringify(event) + "\n");
}

async function readRequest(): Promise<Request> {
  let raw = "";
  for await (const chunk of process.stdin) raw += chunk;
  return JSON.parse(raw) as Request;
}

async function main() {
  const request = await readRequest();
  const apiKey = process.env.CURSOR_API_KEY;
  if (!apiKey) throw new Error("Add a Cursor API key in Settings.");

  const mcpServers: Record<string, McpServerConfig> = {
    "personal-context": { type: "stdio", command: request.mcpCommand, args: [] },
  };
  const options = {
    apiKey,
    model: { id: request.model || "auto" },
    local: { cwd: request.cwd, settingSources: [] },
    tools: ["mcp", "webSearch", "webFetch"],
    mcpServers,
  };

  const agent: SDKAgent = request.agentId
    ? await Agent.resume(request.agentId, options)
    : await Agent.create({ ...options, name: request.name.slice(0, 100) });
  emit({ type: "agent", agentId: agent.agentId });

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
  for await (const message of run.stream()) {
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
        emit({ type: "tool", name: message.name, status: message.status });
        break;
    }
  }
  const result = await run.wait();
  emit({ type: "result", status: result.status, text: result.result, error: result.error?.message });
  agent.close();
}

main().then(
  () => process.exit(0),
  (error: unknown) => {
    emit({ type: "error", message: error instanceof Error ? error.message : String(error) });
    process.exit(1);
  },
);
