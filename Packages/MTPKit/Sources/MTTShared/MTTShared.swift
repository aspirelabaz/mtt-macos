import Foundation
import os

// Shared between the MTT app (which owns the USB connection) and the Finder
// (File Provider) extension, which talks to the app over XPC. No libmtp here:
// the sandboxed extension must not link it.

public enum MTTShared {
    /// App Group shared by the app and the extension, e.g. "ABCDE12345.local.mtt".
    /// Read from the MTTAppGroup key that both Info.plists get at build time.
    public static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "MTTAppGroup") as? String ?? "local.mtt"
    }

    /// Mach service the app vends. Sandboxed processes may look up services
    /// whose name starts with one of their App Groups.
    public static var machServiceName: String { appGroup + ".service" }

    /// launchd label of the agent that runs the app.
    public static let agentLabel = "local.mtt.agent"
}

// MARK: - Domains (one Finder sidebar entry per phone storage)

public enum MTTDomainID {
    /// "<serial>~<storageID>"; stable across re-plugs of the same phone.
    public static func make(serial: String, storageID: UInt32) -> String {
        "\(serial)~\(storageID)"
    }

    public static func parse(_ id: String) -> (serial: String, storageID: UInt32)? {
        guard let i = id.lastIndex(of: "~"), let sid = UInt32(id[id.index(after: i)...]) else { return nil }
        return (String(id[..<i]), sid)
    }
}

// MARK: - Data sent over XPC (as JSON)

public struct EntryDTO: Codable, Sendable, Hashable {
    public var name: String
    public var size: UInt64
    public var modified: Date?
    public var isFolder: Bool

    public init(name: String, size: UInt64, modified: Date?, isFolder: Bool) {
        self.name = name
        self.size = size
        self.modified = modified
        self.isFolder = isFolder
    }
}

public struct StorageDTO: Codable, Sendable, Hashable {
    public var id: UInt32
    public var description: String
    public var capacity: UInt64
    public var freeBytes: UInt64
    public var isReadOnly: Bool

    public init(id: UInt32, description: String, capacity: UInt64, freeBytes: UInt64, isReadOnly: Bool) {
        self.id = id
        self.description = description
        self.capacity = capacity
        self.freeBytes = freeBytes
        self.isReadOnly = isReadOnly
    }
}

public enum DTOCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Errors

public enum MTTServiceError: Int, Sendable {
    case notFound = 1
    case deviceGone = 2
    case alreadyExists = 3
    case readOnly = 4
    case other = 99

    public static let domain = "local.mtt.service"

    public func error(_ message: String) -> NSError {
        NSError(domain: Self.domain, code: rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - XPC protocol (implemented by the app)

/// Phones are addressed by serial number, folders and files by path from the
/// storage root (MTP object IDs change across sessions). Errors use
/// `MTTServiceError.domain`.
@objc public protocol MTTServiceXPC {
    /// Storages of a connected phone, JSON [StorageDTO].
    func storages(serial: String, reply: @escaping (Data?, NSError?) -> Void)

    /// Children of a folder, JSON [EntryDTO]. `path` [] is the storage root.
    func list(serial: String, storageID: UInt32, path: [String], reply: @escaping (Data?, NSError?) -> Void)

    /// Metadata of one item, JSON EntryDTO.
    func entry(serial: String, storageID: UInt32, path: [String], reply: @escaping (Data?, NSError?) -> Void)

    /// Copies a file off the phone into `file` (opened for writing by the caller).
    /// Files travel as descriptors: on recent macOS the app may not touch the
    /// App Group container or the extension's sandbox.
    func download(serial: String, storageID: UInt32, path: [String], file: FileHandle,
                  reply: @escaping (NSError?) -> Void)

    /// Copies everything in `file` (opened for reading) into the folder `parentPath`
    /// as `name`; returns JSON EntryDTO (the name may differ if it was taken).
    func upload(serial: String, storageID: UInt32, parentPath: [String], name: String, file: FileHandle,
                replaceExisting: Bool, reply: @escaping (Data?, NSError?) -> Void)

    func createFolder(serial: String, storageID: UInt32, parentPath: [String], name: String,
                      reply: @escaping (Data?, NSError?) -> Void)

    func rename(serial: String, storageID: UInt32, path: [String], newName: String,
                reply: @escaping (NSError?) -> Void)

    func delete(serial: String, storageID: UInt32, path: [String], reply: @escaping (NSError?) -> Void)
}

// MARK: - Logging

/// Unified logging for the app and the extension. Read with
/// `/usr/bin/log show --predicate 'subsystem == "local.mtt"' --info --last 1h`
/// or the app's "Xuất log chẩn đoán…" menu item.
public enum MTTLog {
    public static let subsystem = "local.mtt"
    public static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }
}

/// Seconds since `start`, for log lines.
public func elapsed(since start: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }
