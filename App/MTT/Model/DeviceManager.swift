import Foundation
import MTPKit
import Observation

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
        let raw = self.raw
        var lastError: Error = MTPError.connectionFailed
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            guard state == .connecting else { return }  // unplugged meanwhile
            do {
                let device = try await runBlocking { try MTPDevice(raw: raw) }
                let worker = DeviceWorker(device: device)
                let storages = try await worker.run { dev, _ in try dev.storages() }
                guard state == .connecting else { device.close(); return }
                self.worker = worker
                self.info = device.info
                self.storages = storages
                self.name = device.info.displayName
                self.state = .ready
                return
            } catch {
                lastError = error
            }
        }
        state = .failed(describe(lastError))
    }

    /// Runs `body` on this phone's worker queue.
    func run<T: Sendable>(_ body: @escaping @Sendable (MTPDevice, PathResolver) throws -> T) async throws -> T {
        guard let worker, state == .ready else { throw MTPError.deviceGone }
        pendingOps += 1
        defer { pendingOps -= 1 }
        do {
            return try await worker.run(body)
        } catch MTPError.deviceGone {
            if state == .ready { state = .disconnected }
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

    /// Called when the phone leaves USB.
    func markDisconnected() {
        state = .disconnected
        let worker = self.worker
        self.worker = nil
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
}
