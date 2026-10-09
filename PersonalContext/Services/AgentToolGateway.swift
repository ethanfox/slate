import Foundation

protocol AgentToolGateway {
    func definitions() async throws -> [[String: Any]]
    func execute(name: String, arguments: [String: Any]) async throws -> String
}
