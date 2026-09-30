import SwiftData

/// The app and the MCP server open the same store. Both carry the same App Group
/// entitlement, so SwiftData places it in that group's container for either process.
enum Store {
    /// Darwin notification posted by the MCP server after it saves, so a running app can refetch.
    static let changedNotification = "com.ethanfox.PersonalContext.storeChanged"

    static let schema = Schema([
        Project.self,
        ProjectThread.self,
        Note.self,
        Decision.self,
        Conversation.self,
        ChatMessage.self,
        Tag.self,
        AgendaItem.self,
        AgendaTrackLink.self,
        AgendaNoteLink.self
    ])

    static var configuration: ModelConfiguration {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }

    static func open() throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: configuration)
    }
}
