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

// A coding tool run for Membrae: no Playwright, just the tool, relayed through files. Launch Services put us
// outside the app's sandbox, which is the point.
/// Finishes launching as an app first, so Launch Services answers the caller, then runs the tool and exits.
final class WorkerHelperApp: NSObject, NSApplicationDelegate {
    let ticket: URL
    init(ticket: URL) { self.ticket = ticket }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ticket = ticket
        DispatchQueue.global(qos: .userInitiated).async {
            exit(WorkerRelay.serve(ticketURL: ticket))
        }
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--exec"), CommandLine.arguments.indices.contains(index + 1) {
    let worker = NSApplication.shared
    let workerDelegate = WorkerHelperApp(ticket: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    worker.delegate = workerDelegate
    worker.setActivationPolicy(.prohibited)
    worker.run()
}

BrowserSupport.attachStandardStreamsToLog()
let app = NSApplication.shared
let delegate = BrowserHelperApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
