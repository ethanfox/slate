import Foundation

enum HostedAccountService {
    static func connect() {
        _ = URLSession.shared.dataTask(with: URL(string: "https://accounts.harbor.test/session")!)
    }
}

func signIn() {
    HostedAccountService.connect()
}
