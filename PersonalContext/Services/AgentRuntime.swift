import Foundation

struct AgentProposedCall: Equatable {
    var id: String
    var name: String
    var arguments: [String: Any]

    static func == (lhs: AgentProposedCall, rhs: AgentProposedCall) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

struct AgentModelTurn {
    var calls: [AgentProposedCall]
    var replay: [[String: Any]]
}

protocol AgentModelTransport {
    func complete(
        instructions: String,
        input: [[String: Any]],
        tools: [[String: Any]],
        onText: (String) async -> Void,
        onThinking: (String?) async -> Void
    ) async throws -> AgentModelTurn
}

enum AgentRuntime {
    enum Event {
        case text(String)
        case thinking(String?)
        case callStarted(AgentProposedCall)
        case callFinished(AgentProposedCall, output: String)
    }

    static func toolsForRound(_ round: Int, tools: [[String: Any]], maxRounds: Int) -> [[String: Any]] {
        round < maxRounds ? tools : []
    }

    static func run(
        instructions: String,
        input starting: [[String: Any]],
        tools: [[String: Any]],
        maxRounds: Int,
        transport: any AgentModelTransport,
        gateway: any AgentToolGateway,
        onEvent: (Event) async -> Void
    ) async throws {
        var input = starting
        for round in 0...maxRounds {
            try Task.checkCancellation()
            let roundTools = toolsForRound(round, tools: tools, maxRounds: maxRounds)
            let turn = try await transport.complete(
                instructions: instructions,
                input: input,
                tools: roundTools,
                onText: { await onEvent(.text($0)) },
                onThinking: { await onEvent(.thinking($0)) }
            )
            if turn.calls.isEmpty || roundTools.isEmpty { break }
            input.append(contentsOf: turn.replay)
            for call in turn.calls {
                try Task.checkCancellation()
                await onEvent(.callStarted(call))
                let output: String
                do {
                    output = try await gateway.execute(name: call.name, arguments: call.arguments)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    output = "Error: \(error.localizedDescription)"
                }
                await onEvent(.callFinished(call, output: output))
                input.append([
                    "type": "function_call_output",
                    "call_id": call.id,
                    "output": output
                ])
            }
            if round == maxRounds - 1 {
                input.append([
                    "role": "user",
                    "content": ChatGPTProvider.answerNowMessage
                ])
            }
        }
    }
}
