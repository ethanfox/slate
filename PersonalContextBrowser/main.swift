import AppKit
import Foundation

func forwardedArguments(_ arguments: [String]) throws -> [String] {
    if let index = arguments.firstIndex(of: "--ticket"),
       arguments.indices.contains(index + 1) {
        return try BrowserSupport.readLaunchTicket(at: URL(fileURLWithPath: arguments[index + 1]))
    }
    if arguments.filter({ $0 != "--bootstrap-only" && $0 != "--headed" }).isEmpty {
        return try BrowserSupport.readLaunchTicket()
    }
    return arguments.filter { $0 != "--bootstrap-only" && $0 != "--headed" }
}

final class BrowserHelperApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BrowserSupport.log("helper finished launching")
        Task { await run() }
    }

    private func run() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        BrowserSupport.log("helper argv=\(arguments.joined(separator: " "))")
        do {
            if arguments.contains("--bootstrap-only") {
                try await BrowserSupport.ensureRuntime { label in
                    BrowserSupport.log("bootstrap \(label)")
                }
                exit(0)
            }
            let forwarded = try forwardedArguments(arguments)
            BrowserSupport.log("helper ticket args=\(forwarded.joined(separator: " ")) ready=\(BrowserSupport.isReady)")
            try await BrowserSupport.ensureRuntime { label in
                BrowserSupport.log("runtime \(label)")
            }
            try BrowserSupport.execPlaywright(arguments: forwarded)
        } catch {
            BrowserSupport.log("helper fail \(error.localizedDescription)")
            FileHandle.standardError.write(Data("membrae-browser: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

BrowserSupport.attachStandardStreamsToLog()
let app = NSApplication.shared
let delegate = BrowserHelperApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
