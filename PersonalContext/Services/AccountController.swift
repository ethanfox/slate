import AppKit
import AuthenticationServices
import Foundation

enum AccountStatus: Equatable {
    case signedOut
    case working(String)
    case signedIn
    case failed(String)
}

struct AccountDevice: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var createdAt: String
    var lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct AccountSummary: Decodable, Equatable {
    var id: String
    var paid: Bool
    var devices: [AccountDevice]
    var thisDevice: String

    enum CodingKeys: String, CodingKey {
        case id, paid, devices
        case thisDevice = "this_device"
    }
}

struct AccountError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The Membrae account: made with a passkey, owning the user's database in Cloudflare. This device
/// holds a key from the account in the Keychain, and sync signs every request with that key.
@MainActor
@Observable
final class AccountController {
    private(set) var status: AccountStatus = .signedOut
    private(set) var accountID: String
    private(set) var deviceID: String
    private(set) var summary: AccountSummary?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    static let relyingParty = "membrae.com"

    private enum Keys {
        static let accountID = "account.id"
        static let deviceID = "account.deviceID"
    }

    init() {
        let defaults = UserDefaults.standard
        accountID = defaults.string(forKey: Keys.accountID) ?? ""
        deviceID = defaults.string(forKey: Keys.deviceID) ?? ""
        status = KeychainStore.read(.deviceKey) == nil ? .signedOut : .signedIn
    }

    func attach(_ app: AppModel) {
        self.app = app
        if isSignedIn { Task { await refresh() } }
    }

    var isSignedIn: Bool { !accountID.isEmpty && deviceKey != nil }
    var deviceKey: String? { KeychainStore.read(.deviceKey) }
    var isWorking: Bool { if case .working = status { return true } else { return false } }

    private var endpoint: String {
        (app?.importRelay.endpoint ?? ImportKeyStore.defaultRelayURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var deviceName: String { Host.current().localizedName ?? "Mac" }

    // MARK: Sign in

    /// A new account from a new passkey.
    func createAccount() async {
        await run("Creating your account…") { try await self.register() }
    }

    /// An existing account on this device, with the passkey iCloud Keychain already holds.
    func signIn() async {
        await run("Signing in…") { try await self.assert() }
    }

    func signOut() async {
        if let key = deviceKey {
            _ = try? await send("POST", "/account/signout", key: key, body: Data("{}".utf8)) as Empty
        }
        forget()
    }

    func removeDevice(_ id: String) async {
        guard let key = deviceKey else { return }
        do {
            _ = try await send("DELETE", "/account/devices/\(id)", key: key) as Empty
            await refresh()
        } catch {
            status = .failed(describe(error))
        }
    }

    func refresh() async {
        guard let key = deviceKey, !accountID.isEmpty else { return }
        do {
            summary = try await send("GET", "/account", key: key)
            status = .signedIn
        } catch let error as AccountError where error.message == Self.signedOutMessage {
            forget()
        } catch {
            NavTrace.event("account.refresh failed \(error.localizedDescription)")
        }
    }

    private func run(_ label: String, _ work: () async throws -> Void) async {
        status = .working(label)
        do {
            try await work()
            status = .signedIn
            await refresh()
            app?.sync.syncSoon()
        } catch {
            status = .failed(describe(error))
            NavTrace.event("account.failed \(error.localizedDescription)")
        }
    }

    private func register() async throws {
        let options: RegistrationOptions = try await send("POST", "/account/register/options", body: Data("{}".utf8))
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialRegistrationRequest(
            challenge: try base64URLDecode(options.options.challenge),
            name: options.options.user.name,
            userID: try base64URLDecode(options.options.user.id)
        )
        let authorization = try await PasskeyPrompt.perform(request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject else {
            throw AccountError("The passkey could not be made.")
        }
        let id = base64URLEncode(credential.credentialID)
        let response: [String: Any] = [
            "id": id,
            "rawId": id,
            "type": "public-key",
            "authenticatorAttachment": "platform",
            "clientExtensionResults": [String: String](),
            "response": [
                "clientDataJSON": base64URLEncode(credential.rawClientDataJSON),
                "attestationObject": base64URLEncode(attestation),
                "transports": ["internal"],
            ],
        ]
        let signedIn: SignedIn = try await send("POST", "/account/register/verify", body: try json([
            "challenge_id": options.challengeID,
            "response": response,
            "device_name": deviceName,
        ]))
        try keep(signedIn)
    }

    private func assert() async throws {
        let options: AssertionOptions = try await send("POST", "/account/signin/options", body: Data("{}".utf8))
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: try base64URLDecode(options.options.challenge))
        let authorization = try await PasskeyPrompt.perform(request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AccountError("The passkey could not be used.")
        }
        let id = base64URLEncode(credential.credentialID)
        let response: [String: Any] = [
            "id": id,
            "rawId": id,
            "type": "public-key",
            "clientExtensionResults": [String: String](),
            "response": [
                "clientDataJSON": base64URLEncode(credential.rawClientDataJSON),
                "authenticatorData": base64URLEncode(credential.rawAuthenticatorData),
                "signature": base64URLEncode(credential.signature),
                "userHandle": base64URLEncode(credential.userID),
            ],
        ]
        let signedIn: SignedIn = try await send("POST", "/account/signin/verify", body: try json([
            "challenge_id": options.challengeID,
            "response": response,
            "device_name": deviceName,
        ]))
        try keep(signedIn)
    }

    private func keep(_ signedIn: SignedIn) throws {
        try KeychainStore.save(signedIn.deviceKey, account: .deviceKey)
        accountID = signedIn.accountID
        deviceID = signedIn.deviceID
        UserDefaults.standard.set(accountID, forKey: Keys.accountID)
        UserDefaults.standard.set(deviceID, forKey: Keys.deviceID)
        NavTrace.event("account.signed-in device=\(deviceID)")
    }

    private func forget() {
        try? KeychainStore.delete(.deviceKey)
        accountID = ""
        deviceID = ""
        summary = nil
        UserDefaults.standard.removeObject(forKey: Keys.accountID)
        UserDefaults.standard.removeObject(forKey: Keys.deviceID)
        status = .signedOut
    }

    private func describe(_ error: Error) -> String {
        if let auth = error as? ASAuthorizationError, auth.code == .canceled { return "Cancelled." }
        return error.localizedDescription
    }

    // MARK: Wire

    static let signedOutMessage = "This device is not signed in."

    private struct Empty: Decodable {}
    private struct SignedIn: Decodable {
        var accountID: String
        var deviceID: String
        var deviceKey: String
        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case deviceID = "device_id"
            case deviceKey = "device_key"
        }
    }
    private struct RegistrationOptions: Decodable {
        struct User: Decodable { var id: String; var name: String }
        struct Options: Decodable { var challenge: String; var user: User }
        var challengeID: String
        var options: Options
        enum CodingKeys: String, CodingKey { case challengeID = "challenge_id", options }
    }
    private struct AssertionOptions: Decodable {
        struct Options: Decodable { var challenge: String }
        var challengeID: String
        var options: Options
        enum CodingKeys: String, CodingKey { case challengeID = "challenge_id", options }
    }
    private struct ServerError: Decodable { var error: String }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func send<Reply: Decodable>(_ method: String, _ path: String, key: String? = nil, body: Data? = nil) async throws -> Reply {
        guard let url = URL(string: endpoint + path) else { throw AccountError("Bad account address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError("No reply from the account server") }
        guard (200..<300).contains(http.statusCode) else {
            if let server = try? JSONDecoder().decode(ServerError.self, from: data) { throw AccountError(server.error) }
            throw AccountError("The account server answered \(http.statusCode)")
        }
        if Reply.self == Empty.self { return Empty() as! Reply }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}

/// Shows the system passkey sheet and waits for its answer.
@MainActor
private final class PasskeyPrompt: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?
    private static var current: PasskeyPrompt?

    static func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        let prompt = PasskeyPrompt()
        current = prompt
        defer { current = nil }
        return try await withCheckedThrowingContinuation { continuation in
            prompt.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = prompt
            controller.presentationContextProvider = prompt
            prompt.controller = controller
            controller.performRequests()
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: authorization)
            continuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? NSWindow()
        }
    }
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecode(_ text: String) throws -> Data {
    var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded += "=" }
    guard let data = Data(base64Encoded: padded) else { throw AccountError("Bad data from the account server") }
    return data
}
