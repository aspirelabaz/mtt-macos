import Foundation
import MTPKit
import MTTShared
import os

private let serviceLog = MTTLog.logger("service")

/// Vends `MTTServiceXPC` on the app's Mach service so the Finder extension
/// can reach the phone. Only works when launchd started the app (see Agent).
final class ServiceHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let shared = ServiceHost()
    private var listener: NSXPCListener?

    func start() {
        guard listener == nil else { return }
        let l = NSXPCListener(machServiceName: MTTShared.machServiceName)
        l.delegate = self
        l.resume()
        listener = l
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only accept processes signed by the same team (i.e. our extension).
        let group = MTTShared.appGroup
        if let dot = group.firstIndex(of: "."), group[..<dot].count == 10 {
            let team = group[..<dot]
            connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
        connection.exportedInterface = NSXPCInterface(with: MTTServiceXPC.self)
        connection.exportedObject = ServiceExport()
        connection.resume()
        return true
    }
}

/// Lets non-Sendable XPC reply blocks cross into async code. Each is called once.
private struct Reply<T>: @unchecked Sendable {
    let call: T
}

/// The XPC calls, implemented on top of the app's device workers.
final class ServiceExport: NSObject, MTTServiceXPC, @unchecked Sendable {

    func storages(serial: String, reply: @escaping (Data?, NSError?) -> Void) {
        let r = logged("storages", serial, reply)
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                let dtos = device.storages.map {
                    StorageDTO(id: $0.id, description: $0.description, capacity: $0.capacity,
                               freeBytes: $0.freeBytes, isReadOnly: $0.isReadOnly)
                }
                r.call(DTOCoding.encode(dtos), nil)
            } catch {
                r.call(nil, ServiceExport.nsError(error))
            }
        }
    }

    func list(serial: String, storageID: UInt32, path: [String], reply: @escaping (Data?, NSError?) -> Void) {
        let r = logged("list", pathString(path), reply)
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                let entries = try await device.run { dev, resolver in
                    try resolver.list(dev, storageID: storageID, path: path)
                }
                r.call(DTOCoding.encode(entries.map(ServiceExport.dto)), nil)
            } catch {
                r.call(nil, ServiceExport.nsError(error))
            }
        }
    }

    func entry(serial: String, storageID: UInt32, path: [String], reply: @escaping (Data?, NSError?) -> Void) {
        let r = logged("entry", pathString(path), reply)
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                let e = try await device.run { dev, resolver in
                    try resolver.entry(dev, storageID: storageID, path: path)
                }
                r.call(DTOCoding.encode(ServiceExport.dto(e)), nil)
            } catch {
                r.call(nil, ServiceExport.nsError(error))
            }
        }
    }

    func download(serial: String, storageID: UInt32, path: [String], file: FileHandle,
                  reply: @escaping (NSError?) -> Void) {
        let r = logged("download", pathString(path), reply)
        let handle = Reply(call: file)  // keeps the descriptor open until we're done
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                try await device.run { dev, resolver in
                    let e = try resolver.entry(dev, storageID: storageID, path: path)
                    guard !e.isFolder else { throw MTPError.notAFolder(pathString(path)) }
                    try dev.download(id: e.id, toFileDescriptor: handle.call.fileDescriptor)
                }
                r.call(nil)
            } catch {
                r.call(ServiceExport.nsError(error))
            }
            try? handle.call.close()
        }
    }

    func upload(serial: String, storageID: UInt32, parentPath: [String], name: String, file: FileHandle,
                replaceExisting: Bool, reply: @escaping (Data?, NSError?) -> Void) {
        let r = logged("upload", pathString(parentPath + [name]), reply)
        let handle = Reply(call: file)
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                let e = try await device.run { dev, resolver in
                    let parentID = try resolver.folderID(dev, storageID: storageID, path: parentPath)
                    let siblings = try dev.list(storageID: storageID, folderID: parentID)
                    var finalName = name
                    if let existing = siblings.first(where: { $0.name == name }) {
                        if replaceExisting && !existing.isFolder {
                            try dev.delete(id: existing.id)  // MTP can't overwrite in place
                        } else {
                            finalName = uniqueName(name, taken: Set(siblings.map(\.name)))
                        }
                    }
                    let new = try dev.upload(fileDescriptor: handle.call.fileDescriptor, name: finalName,
                                             storageID: storageID, parentID: parentID)
                    resolver.invalidate()
                    return new
                }
                device.changeCounter += 1
                r.call(DTOCoding.encode(ServiceExport.dto(e)), nil)
            } catch {
                r.call(nil, ServiceExport.nsError(error))
            }
            try? handle.call.close()
        }
    }

    func createFolder(serial: String, storageID: UInt32, parentPath: [String], name: String,
                      reply: @escaping (Data?, NSError?) -> Void) {
        let r = logged("createFolder", pathString(parentPath + [name]), reply)
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                let e = try await device.run { dev, resolver in
                    let parentID = try resolver.folderID(dev, storageID: storageID, path: parentPath)
                    let siblings = try dev.list(storageID: storageID, folderID: parentID)
                    if let existing = siblings.first(where: { $0.name == name }) {
                        if existing.isFolder { return existing }  // already there: reuse
                        throw MTPError.alreadyExists(pathString(parentPath + [name]))
                    }
                    return try dev.createFolder(name: name, storageID: storageID, parentID: parentID)
                }
                device.changeCounter += 1
                r.call(DTOCoding.encode(ServiceExport.dto(e)), nil)
            } catch {
                r.call(nil, ServiceExport.nsError(error))
            }
        }
    }

    func rename(serial: String, storageID: UInt32, path: [String], newName: String,
                reply: @escaping (NSError?) -> Void) {
        let r = logged("rename", pathString(path) + " -> " + newName, reply)
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                try await device.run { dev, resolver in
                    let siblings = try resolver.list(dev, storageID: storageID, path: Array(path.dropLast()))
                    guard let current = siblings.first(where: { $0.name == path.last }) else {
                        throw MTPError.notFound(pathString(path))
                    }
                    if siblings.contains(where: { $0.name == newName }) {
                        throw MTPError.alreadyExists(newName)
                    }
                    try dev.rename(id: current.id, to: newName)
                    resolver.invalidate()
                }
                device.changeCounter += 1
                r.call(nil)
            } catch {
                r.call(ServiceExport.nsError(error))
            }
        }
    }

    func delete(serial: String, storageID: UInt32, path: [String], reply: @escaping (NSError?) -> Void) {
        let r = logged("delete", pathString(path), reply)
        Task { @MainActor in
            do {
                let device = try await ServiceExport.device(serial)
                try await device.run { dev, resolver in
                    let e = try resolver.entry(dev, storageID: storageID, path: path)
                    try dev.delete(id: e.id)
                    resolver.invalidate()
                }
                device.changeCounter += 1
                r.call(nil)
            } catch {
                r.call(ServiceExport.nsError(error))
            }
        }
    }

    // MARK: - Logging

    /// Wraps a reply so the call is logged with its duration and outcome.
    private func logged(_ op: String, _ detail: String, _ reply: @escaping (Data?, NSError?) -> Void) -> Reply<(Data?, NSError?) -> Void> {
        let start = Date()
        return Reply(call: { data, error in
            ServiceExport.record(op, detail, start, error)
            reply(data, error)
        })
    }

    private func logged(_ op: String, _ detail: String, _ reply: @escaping (NSError?) -> Void) -> Reply<(NSError?) -> Void> {
        let start = Date()
        return Reply(call: { error in
            ServiceExport.record(op, detail, start, error)
            reply(error)
        })
    }

    private static func record(_ op: String, _ detail: String, _ start: Date, _ error: NSError?) {
        if let error {
            serviceLog.error("\(op, privacy: .public) \(detail, privacy: .public) failed after \(elapsed(since: start), privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else if op == "list" || op == "entry" || op == "storages" {
            serviceLog.info("\(op, privacy: .public) \(detail, privacy: .public) in \(elapsed(since: start), privacy: .public)")
        } else {
            serviceLog.notice("\(op, privacy: .public) \(detail, privacy: .public) in \(elapsed(since: start), privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Finds the phone by serial. If launchd just started the app for this request,
    /// the phone may still be connecting, so wait a little.
    @MainActor
    static func device(_ serial: String) async throws -> ConnectedDevice {
        let manager = DeviceManager.shared
        let deadline = Date().addingTimeInterval(10)
        while true {
            if let d = manager.devices.first(where: { $0.isReady && $0.info?.serial == serial }) { return d }
            // Keep waiting only while something might still turn into this phone:
            // the app just started, or a phone is still connecting.
            let justStarted = Date().timeIntervalSince(manager.startedAt) < 10
            let connecting = manager.devices.contains { $0.state == .connecting }
            if Date() > deadline || !(justStarted || connecting) { throw MTPError.deviceGone }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    static func dto(_ e: MTPEntry) -> EntryDTO {
        EntryDTO(name: e.name, size: e.isFolder ? 0 : e.size, modified: e.modified, isFolder: e.isFolder)
    }

    static func nsError(_ error: Error) -> NSError {
        switch error {
        case MTPError.notFound(let p): return MTTServiceError.notFound.error(describe(MTPError.notFound(p)))
        case MTPError.deviceGone, MTPError.noDevice: return MTTServiceError.deviceGone.error(describe(error))
        case MTPError.alreadyExists: return MTTServiceError.alreadyExists.error(describe(error))
        default: return MTTServiceError.other.error(describe(error))
        }
    }
}
