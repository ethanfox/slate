import Foundation
import Observation

struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date

    var directoryName: String { id.uuidString }
}

struct BrowserSessionRecord: Codable, Equatable, Sendable {
    var profiles: [BrowserProfile]
    var rememberedHosts: [String]
    var allowPrivateNetwork: Bool
    var maxConcurrentPages: Int
    var idleSeconds: Int

    static let empty = BrowserSessionRecord(
        profiles: [],
        rememberedHosts: [],
        allowPrivateNetwork: false,
        maxConcurrentPages: 4,
        idleSeconds: 180
    )
}

@MainActor
@Observable
final class BrowserSessionStore {
    private let url: URL
    private(set) var record: BrowserSessionRecord

    init(url: URL = BrowserSupport.root.appendingPathComponent("sessions.json")) {
        self.url = url
        self.record = Self.load(url) ?? .empty
        record.maxConcurrentPages = min(8, max(1, record.maxConcurrentPages))
        record.idleSeconds = min(600, max(30, record.idleSeconds))
    }

    var profiles: [BrowserProfile] { record.profiles.sorted { $0.lastUsedAt > $1.lastUsedAt } }
    var allowPrivateNetwork: Bool { record.allowPrivateNetwork }
    var maxConcurrentPages: Int { record.maxConcurrentPages }
    var idleSeconds: TimeInterval { TimeInterval(record.idleSeconds) }

    func profileDirectory(_ profile: BrowserProfile) -> URL {
        BrowserSupport.profiles.appendingPathComponent(profile.directoryName, isDirectory: true)
    }

    func save(_ next: BrowserSessionRecord) throws {
        record = next
        try persist()
    }

    func setAllowPrivateNetwork(_ allowed: Bool) throws {
        record.allowPrivateNetwork = allowed
        try persist()
    }

    func setMaxConcurrentPages(_ value: Int) throws {
        record.maxConcurrentPages = min(8, max(1, value))
        try persist()
    }

    func upsertProfile(named name: String, host: String = "") throws -> BrowserProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserSupportError("Session name is required.") }
        if var existing = record.profiles.first(where: { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }) {
            existing.updatedAt = .now
            existing.lastUsedAt = .now
            if !host.isEmpty { existing.host = host }
            record.profiles = record.profiles.map { $0.id == existing.id ? existing : $0 }
            try persist()
            return existing
        }
        let profile = BrowserProfile(id: UUID(), name: trimmed, host: host, createdAt: .now, updatedAt: .now, lastUsedAt: .now)
        record.profiles.append(profile)
        try FileManager.default.createDirectory(at: profileDirectory(profile), withIntermediateDirectories: true)
        try persist()
        return profile
    }

    func touch(_ id: UUID, host: String? = nil) throws {
        record.profiles = record.profiles.map { profile in
            guard profile.id == id else { return profile }
            var next = profile
            next.lastUsedAt = .now
            next.updatedAt = .now
            if let host, !host.isEmpty { next.host = host }
            return next
        }
        if let host, !host.isEmpty, !record.rememberedHosts.contains(host) {
            record.rememberedHosts.append(host)
        }
        try persist()
    }

    func reset(_ id: UUID) throws {
        guard let profile = record.profiles.first(where: { $0.id == id }) else { return }
        let directory = profileDirectory(profile)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try touch(id)
    }

    func remove(_ id: UUID) throws {
        if let profile = record.profiles.first(where: { $0.id == id }) {
            let directory = profileDirectory(profile)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        record.profiles.removeAll { $0.id == id }
        try persist()
    }

    func clearBrowsingData() throws {
        let fm = FileManager.default
        for profile in record.profiles {
            let directory = profileDirectory(profile)
            if fm.fileExists(atPath: directory.path) {
                try fm.removeItem(at: directory)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        if fm.fileExists(atPath: BrowserSupport.downloads.path) {
            try fm.removeItem(at: BrowserSupport.downloads)
            try fm.createDirectory(at: BrowserSupport.downloads, withIntermediateDirectories: true)
        }
        record.rememberedHosts = []
        try persist()
    }

    private func persist() throws {
        try BrowserSupport.ensureDirectories()
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    private static func load(_ url: URL) -> BrowserSessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrowserSessionRecord.self, from: data)
    }
}
