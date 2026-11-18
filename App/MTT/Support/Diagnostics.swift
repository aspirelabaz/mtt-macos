import AppKit
import Foundation
import MTTShared

/// "Xuất log chẩn đoán…": saves the last 2 hours of MTT's log (app and Finder
/// extension) to a text file on the Desktop and shows it in Finder.
@MainActor
enum Diagnostics {
    static func exportLog() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = desktop.appendingPathComponent("MTT-log-\(stamp.string(from: Date())).txt")

        Task.detached {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let out = try? FileHandle(forWritingTo: url) else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--last", "2h", "--info", "--style", "compact",
                           "--predicate", "subsystem == \"\(MTTLog.subsystem)\""]
            p.standardOutput = out
            p.standardError = out
            do {
                try p.run()
                p.waitUntilExit()
            } catch {
                out.write("Could not run /usr/bin/log: \(error)\n".data(using: .utf8)!)
            }
            try? out.close()
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
