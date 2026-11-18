import Foundation

/// MTP object ID of a storage's root, used as `parentID` for top-level items.
public let MTPRootFolderID: UInt32 = 0xFFFF_FFFF

public struct MTPStorage: Sendable, Hashable {
    public let id: UInt32
    public let description: String
    public let capacity: UInt64
    public let freeBytes: UInt64
    /// 0 = read/write, 1 = read-only without delete, 2 = read-only with delete.
    public let accessCapability: UInt16

    public var isReadOnly: Bool { accessCapability != 0 }
}

public struct MTPEntry: Sendable, Hashable {
    public let id: UInt32
    public let parentID: UInt32
    public let storageID: UInt32
    public let name: String
    public let size: UInt64
    public let modified: Date?
    public let isFolder: Bool

    /// A synthetic entry for a storage's root folder.
    public static func root(storageID: UInt32) -> MTPEntry {
        MTPEntry(id: MTPRootFolderID, parentID: MTPRootFolderID, storageID: storageID,
                 name: "/", size: 0, modified: nil, isFolder: true)
    }

    public var isRoot: Bool { id == MTPRootFolderID }
}

public struct MTPDeviceInfo: Sendable {
    public let manufacturer: String
    public let model: String
    public let friendlyName: String
    public let serial: String
    public let batteryPercent: Int?

    /// Best human-readable name: friendly name if set, otherwise "Manufacturer Model".
    public var displayName: String {
        if !friendlyName.isEmpty { return friendlyName }
        return model.hasPrefix(manufacturer) ? model : "\(manufacturer) \(model)"
    }
}

/// Splits "/DCIM/Camera/" into ["DCIM", "Camera"].
public func mtpPathComponents(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

/// Debug tracing: when the MTT_TRACE environment variable names a file,
/// timestamped lines are appended to it. Costs nothing otherwise.
let mtpTraceHandle: FileHandle? = {
    guard let path = ProcessInfo.processInfo.environment["MTT_TRACE"], !path.isEmpty else { return nil }
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

func mtpTrace(_ msg: @autoclosure () -> String) {
    guard let h = mtpTraceHandle else { return }
    let t = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    h.write("[\(t)] \(msg())\n".data(using: .utf8)!)
}
