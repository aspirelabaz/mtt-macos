import AppKit
import Foundation
import MTTShared
import ServiceManagement
import os

private let log = MTTLog.logger("agent")

/// Runs the app as a launchd agent so the Finder extension can always reach it:
/// it starts at login, and launchd starts it on demand when the extension
/// connects to its Mach service.
@MainActor
enum Agent {
    static let plistName = "local.mtt.agent.plist"
    private static let openWindowKey = "MTTOpenWindowOnLaunch"

    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// True when launchd started this process (then the Mach service is ours).
    static var launchedByLaunchd: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == MTTShared.agentLabel
    }

    /// Set MTT_NO_AGENT=1 (e.g. when running from Xcode) to skip all of this.
    static var disabled: Bool {
        ProcessInfo.processInfo.environment["MTT_NO_AGENT"] == "1"
    }

    /// Call first thing at launch. If the user started the app by hand, register
    /// the agent and hand over to a launchd-started copy (this one then quits).
    static func bootstrap() {
        log.notice("launch: launchedByLaunchd=\(launchedByLaunchd) agentStatus=\(service.status.rawValue)")
        guard !disabled, !launchedByLaunchd else { return }

        // Set before registering: with RunAtLoad, registering starts the launchd
        // copy right away and it reads this flag on launch.
        UserDefaults.standard.set(true, forKey: openWindowKey)
        if service.status != .enabled {
            do {
                try service.register()
            } catch {
                log.error("registering launch agent failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard service.status == .enabled else {
            // Needs approval in System Settings > General > Login Items; until then
            // the app works normally, just without the Finder entry.
            UserDefaults.standard.removeObject(forKey: openWindowKey)
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            return
        }

        // Start the launchd copy (no-op if registering already did) and quit this one.
        if kickstart() { exit(0) }
        // "Enabled" but not loaded in launchd (e.g. after `launchctl bootout`):
        // registering again reloads it.
        try? service.unregister()
        try? service.register()
        if service.status == .enabled, kickstart() { exit(0) }
        log.error("could not start the launch agent; running without Finder integration")
        UserDefaults.standard.removeObject(forKey: openWindowKey)
    }

    private static func kickstart() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(MTTShared.agentLabel)"]
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            log.error("launchctl kickstart failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whether to show the browser window at launch: not when launchd started us
    /// at login (stay in the menu bar), yes when the user asked for the app.
    static func shouldOpenWindowAtLaunch() -> Bool {
        if !launchedByLaunchd { return true }
        let ask = UserDefaults.standard.bool(forKey: openWindowKey)
        UserDefaults.standard.removeObject(forKey: openWindowKey)
        return ask
    }

    /// Finder integration needs both the agent and the Mach service.
    static var finderIntegrationAvailable: Bool { launchedByLaunchd }
}
