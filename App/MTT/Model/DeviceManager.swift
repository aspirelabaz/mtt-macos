import Foundation
import MTPKit
import MTTShared
import Observation
import os

private let log = MTTLog.logger("device")

/// One phone plugged in over USB.
@MainActor @Observable
final class ConnectedDevice: Identifiable {
    enum State: Equatable {
        case connecting
        case ready
        case failed(String)
        case disconnected
    }

    let id: String  // USB attachment key; a re-plug gives a new one
    let raw: RawDeviceInfo
    var name: String
    var state: State = .connecting
    /// The last connect failed because macOS's ptpcamerad holds the phone.
    var blockedByPTPCamera = false
    var info: MTPDeviceInfo?
    var storages: [MTPStorage] = []
    /// Number of operations queued or running on the worker.
    var pendingOps = 0
    /// Bumped whenever this app changes files on the phone, so open folders reload.
    var changeCounter = 0

    private(set) var worker: DeviceWorker?

    init(raw: RawDeviceInfo) {
        id = raw.usbKey
        self.raw = raw
        name = raw.product
    }

    var isReady: Bool { state == .ready }

    /// Opens the phone. Retries for a few seconds: right after plugging in, or
    /// after switching to "File transfer", the phone often isn't ready yet.
    func connect() async {
        state = .connecting
        blockedByPTPCamera = false
        let raw = self.raw
        let started = Date()
        log.notice("connecting \(raw.usbKey, privacy: .public) (\(raw.vendor, privacy: .public) \(raw.product, privacy: .public))")
        var lastError: Error = MTPError.connectionFailed
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            guard state == .connecting else { return }  // unplugged meanwhile
            // Free the phone from Photos/Image Capture first, if the user allowed it.
            // (Done before trying: failed opens leak USB handles inside libmtp.)
            if PTPCameraDaemon.autoRelease, PTPCameraDaemon.holdsMTPInterface() {
                _ = try? await runBlocking { PTPCameraDaemon.stop() }
            }
            do {
                let device = try await runBlocking { try MTPDevice(raw: raw) }
                // A reset after a cancelled transfer releases the phone for a moment,
                // and ptpcamerad grabs it; free it again before each reopen.
                device.beforeReopen = {
                    if PTPCameraDaemon.autoRelease, PTPCameraDaemon.holdsMTPInterface() {
                        PTPCameraDaemon.stop()
                    }
                }
                let worker = DeviceWorker(device: device)
                let storages = try await worker.run { dev, _ in try dev.storages() }
                guard state == .connecting else { device.close(); return }
                self.worker = worker
                self.info = device.info
                self.storages = storages
                self.name = device.info.displayName
                self.state = .ready
                log.notice("ready: \(self.name, privacy: .public), \(storages.count) storage(s), resetOnCloseDisabled=\(device.resetOnCloseDisabled) in \(elapsed(since: started), privacy: .public)")
                return
            } catch {
                lastError = error
                log.error("open attempt \(attempt + 1) failed: \(describe(error), privacy: .public)")
                if PTPCameraDaemon.holdsMTPInterface() && !PTPCameraDaemon.autoRelease {
                    break  // retrying won't help until the user frees it
                }
            }
        }
        log.error("could not connect \(raw.usbKey, privacy: .public) after \(elapsed(since: started), privacy: .public)")
        if PTPCameraDaemon.holdsMTPInterface() {
            log.error("ptpcamerad holds the MTP interface")
            blockedByPTPCamera = true
            state = .failed("macOS (dịch vụ ptpcamerad của Ảnh / Image Capture) đang giữ kết nối với điện thoại.")
        } else {
            state = .failed(describe(lastError))
        }
    }

    /// Runs `body` on this phone's worker queue.
    func run<T: Sendable>(_ body: @escaping @Sendable (MTPDevice, PathResolver) throws -> T) async throws -> T {
        guard let worker, state == .ready else { throw MTPError.deviceGone }
        pendingOps += 1
        defer { pendingOps -= 1 }
        do {
            return try await worker.run(body)
        } catch MTPError.deviceGone {
            if state == .ready {
                state = .disconnected
                scheduleRecovery()
            }
            throw MTPError.deviceGone
        }
    }

    func list(storageID: UInt32, path: [String]) async throws -> [RemoteItem] {
        let entries = try await run { dev, resolver in
            try resolver.list(dev, storageID: storageID, path: path)
        }
        return entries.map { RemoteItem(entry: $0, path: path + [$0.name]) }
    }

    func refreshStorages() async {
        if let s = try? await run({ dev, _ in try dev.storages() }) { storages = s }
        if let i = try? await run({ dev, _ in try dev.refreshInfo() }) { info = i }
    }

    func createFolder(storageID: UInt32, in path: [String], name: String) async throws {
        try await run { dev, resolver in
            let parentID = try resolver.folderID(dev, storageID: storageID, path: path)
            let existing = try dev.list(storageID: storageID, folderID: parentID)
            if existing.contains(where: { $0.name == name }) {
                throw MTPError.alreadyExists(pathString(path + [name]))
            }
            try dev.createFolder(name: name, storageID: storageID, parentID: parentID)
        }
        changeCounter += 1
    }

    func rename(storageID: UInt32, item: RemoteItem, to newName: String) async throws {
        try await run { dev, resolver in
            let siblings = try resolver.list(dev, storageID: storageID, path: Array(item.path.dropLast()))
            if siblings.contains(where: { $0.name == newName }) {
                throw MTPError.alreadyExists(newName)
            }
            guard let current = siblings.first(where: { $0.name == item.name }) else {
                throw MTPError.notFound(pathString(item.path))
            }
            try dev.rename(id: current.id, to: newName)
            resolver.invalidate()
        }
        changeCounter += 1
    }

    func delete(storageID: UInt32, items: [RemoteItem]) async throws {
        try await run { dev, resolver in
            for item in items {
                let current = try resolver.entry(dev, storageID: storageID, path: item.path)
                try dev.delete(id: current.id)
            }
            resolver.invalidate()
        }
        changeCounter += 1
        await refreshStorages()
    }

    func thumbnail(for item: RemoteItem, cancel: CancelFlag) async -> Data? {
        let id = item.entry.id
        return try? await run { dev, _ in
            if cancel.isSet { return nil }  // scrolled away while queued
            return try dev.thumbnail(id: id)
        }
    }

    /// The session died (e.g. a reconnect after a cancel failed) but the phone may
    /// still be plugged in: if USB detection hasn't removed it shortly after,
    /// open it again from scratch.
    private func scheduleRecovery() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard state == .disconnected,
                  DeviceManager.shared.devices.contains(where: { $0 === self }) else { return }
            log.notice("session lost but \(self.name, privacy: .public) is still on USB: reconnecting")
            if let old = worker {
                worker = nil
                Task.detached { _ = try? await old.run { dev, _ in dev.close() } }
            }
            await connect()
        }
    }

    /// Called when the phone leaves USB.
    func markDisconnected() {
        log.notice("disconnected: \(self.name, privacy: .public)")
        state = .disconnected
        let worker = self.worker
        self.worker = nil
        // Make a transfer stuck on the vanished phone fail now, not after libmtp's
        // ~10 s timeouts (also unblocks Finder requests queued behind it).
        worker?.device.abortPendingIO()
        // Closing waits for any running transfer to give up, so do it off the main thread.
        if let worker {
            Task.detached { _ = try? await worker.run { dev, _ in dev.close() } }
        }
    }
}

/// Watches USB and keeps the list of connected phones.
@MainActor @Observable
final class DeviceManager {
    static let shared = DeviceManager()

    private(set) var devices: [ConnectedDevice] = []
    @ObservationIgnored let startedAt = Date()
    /// Called after a phone disappears, with its ID (used to fail its transfers).
    @ObservationIgnored var onDeviceRemoved: ((String) -> Void)?

    @ObservationIgnored private var watcher: USBWatcher?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false

    func start() {
        guard watcher == nil else { return }
        let w = USBWatcher(debounce: 0.7) {
            MainActor.assumeIsolated { DeviceManager.shared.refresh() }
        }
        w.start()
        watcher = w
        refresh()
    }

    func device(id: String?) -> ConnectedDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    /// Re-detects MTP devices and diffs against the current list.
    func refresh() {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        Task {
            defer {
                refreshing = false
                if refreshAgain { refreshAgain = false; refresh() }
            }
            let found = (try? await runBlocking { try MTP.detectRawDevices() }) ?? []
            let foundKeys = Set(found.map(\.usbKey))

            for gone in devices where !foundKeys.contains(gone.id) {
                gone.markDisconnected()
                onDeviceRemoved?(gone.id)
            }
            devices.removeAll { !foundKeys.contains($0.id) }

            for raw in found where !devices.contains(where: { $0.id == raw.usbKey }) {
                let d = ConnectedDevice(raw: raw)
                devices.append(d)
                Task { await d.connect() }
            }
        }
    }

    func retry(_ device: ConnectedDevice) {
        Task { await device.connect() }
    }

    /// User asked to free the phone from ptpcamerad. Failed opens leave USB handles
    /// open inside libmtp, so restart the whole app afterwards to start clean.
    func releaseFromPTPCameraAndRestart() {
        PTPCameraDaemon.stop()
        if Agent.launchedByLaunchd {
            // launchd starts a fresh copy (the Finder extension needs it running).
            UserDefaults.standard.set(true, forKey: "MTTOpenWindowOnLaunch")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(MTTShared.agentLabel)"]
            try? p.run()  // kills this process and starts a new one
        } else {
            Task {
                for d in devices { await d.connect() }
            }
        }
    }
}
