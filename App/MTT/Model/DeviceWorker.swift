import Foundation
import MTPKit

/// Runs every MTP call for one phone on its own serial queue.
///
/// MTP allows one operation at a time per session, so calls are naturally
/// serialized: a folder listing requested during a big transfer waits for it.
final class DeviceWorker: Sendable {
    let device: MTPDevice
    let resolver = PathResolver()
    private let queue: DispatchQueue

    init(device: MTPDevice) {
        self.device = device
        queue = DispatchQueue(label: "mtt.device.\(device.raw.usbKey)", qos: .userInitiated)
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (MTPDevice, PathResolver) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [device, resolver] in
                continuation.resume(with: Result { try body(device, resolver) })
            }
        }
    }
}

/// Turns paths into current MTP object IDs, caching folder IDs per session
/// generation. Only used on the worker queue, but guarded by a lock anyway.
final class PathResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = -1
    private var folderIDs: [String: UInt32] = [:]  // "storageID:/a/b" -> object ID

    private func key(_ storageID: UInt32, _ path: [String]) -> String {
        "\(storageID):" + pathString(path)
    }

    private func cached(_ dev: MTPDevice, _ storageID: UInt32, _ path: [String]) -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        if generation != dev.sessionGeneration {
            generation = dev.sessionGeneration
            folderIDs.removeAll()
        }
        return folderIDs[key(storageID, path)]
    }

    private func remember(_ dev: MTPDevice, _ storageID: UInt32, parent: [String], children: [MTPEntry]) {
        lock.lock(); defer { lock.unlock() }
        guard generation == dev.sessionGeneration else { return }
        for c in children where c.isFolder {
            folderIDs[key(storageID, parent + [c.name])] = c.id
        }
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        folderIDs.removeAll()
    }

    /// Object ID of the folder at `path` (root for []).
    func folderID(_ dev: MTPDevice, storageID: UInt32, path: [String]) throws -> UInt32 {
        if path.isEmpty { return MTPRootFolderID }
        if let id = cached(dev, storageID, path) { return id }
        let parentID = try folderID(dev, storageID: storageID, path: Array(path.dropLast()))
        let children = try dev.list(storageID: storageID, folderID: parentID)
        remember(dev, storageID, parent: Array(path.dropLast()), children: children)
        guard let folder = children.first(where: { $0.isFolder && $0.name == path.last }) else {
            throw MTPError.notFound(pathString(path))
        }
        return folder.id
    }

    /// Children of the folder at `path`. Retries once from scratch if a cached ID went stale.
    func list(_ dev: MTPDevice, storageID: UInt32, path: [String]) throws -> [MTPEntry] {
        do {
            let id = try folderID(dev, storageID: storageID, path: path)
            let children = try dev.list(storageID: storageID, folderID: id)
            remember(dev, storageID, parent: path, children: children)
            return children
        } catch MTPError.deviceGone {
            throw MTPError.deviceGone
        } catch {
            invalidate()
            let id = try folderID(dev, storageID: storageID, path: path)
            let children = try dev.list(storageID: storageID, folderID: id)
            remember(dev, storageID, parent: path, children: children)
            return children
        }
    }

    /// The current entry for the item at `path` (looked up fresh in its parent).
    func entry(_ dev: MTPDevice, storageID: UInt32, path: [String]) throws -> MTPEntry {
        guard let name = path.last else { return .root(storageID: storageID) }
        let siblings = try list(dev, storageID: storageID, path: Array(path.dropLast()))
        guard let e = siblings.first(where: { $0.name == name }) else {
            throw MTPError.notFound(pathString(path))
        }
        return e
    }
}
