import Foundation

/// Temporary draft-wipe diagnostics. Lengths only; no draft text.
enum DraftTrace {
    static func appear(
        kind: String,
        object: String,
        runtime: String,
        storeGeneration: UUID,
        draftChars: Int
    ) {
        event(
            "appear kind=\(kind) object=\(object) runtime=\(runtime) storeGeneration=\(short(storeGeneration)) draftChars=\(draftChars)"
        )
    }

    static func disappear(
        kind: String,
        object: String,
        runtime: String,
        storeGeneration: UUID,
        draftChars: Int
    ) {
        event(
            "disappear kind=\(kind) object=\(object) runtime=\(runtime) storeGeneration=\(short(storeGeneration)) draftChars=\(draftChars)"
        )
    }

    static func change(
        kind: String,
        object: String,
        runtime: String,
        oldChars: Int,
        newChars: Int,
        source: String,
        storeGeneration: UUID
    ) {
        event(
            "change kind=\(kind) object=\(object) runtime=\(runtime) old=\(oldChars) new=\(newChars) source=\(source) storeGeneration=\(short(storeGeneration))"
        )
    }

    static func send(
        kind: String,
        object: String,
        runtime: String,
        chars: Int,
        accepted: Bool
    ) {
        event("send kind=\(kind) object=\(object) runtime=\(runtime) chars=\(chars) accepted=\(accepted)")
    }

    static func clear(
        kind: String,
        object: String,
        runtime: String,
        oldChars: Int,
        source: String
    ) {
        event("clear kind=\(kind) object=\(object) runtime=\(runtime) old=\(oldChars) source=\(source)")
    }

    static func streamStart(object: String, runtime: String, model: String) {
        event("stream-start object=\(object) runtime=\(runtime) model=\(model)")
    }

    static func storeReopen(generation: UUID, runtimes: [(object: String, runtime: String, draftChars: Int)]) {
        event("store-reopen generation=\(short(generation)) runtimes=\(runtimes.count)")
        for item in runtimes {
            event(
                "store-reopen-runtime object=\(item.object) runtime=\(item.runtime) draftChars=\(item.draftChars)"
            )
        }
    }

    static func runtimeID(_ runtime: AnyObject) -> String {
        String(UInt(bitPattern: ObjectIdentifier(runtime)), radix: 16)
    }

    static func event(_ message: String) {
        ChatTrace.event("draft-trace \(message)")
    }

    private static func short(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}
