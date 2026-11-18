import AppKit
import Foundation
import MTPKit
import Synchronization
import UniformTypeIdentifiers

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    static let date: DateFormatter = {
        let f = DateFormatter()
        // The vi_VN medium style ("18:40 ngày 17 thg 11, 2026") is too wide for a column.
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f
    }()
}

// MARK: - Remote items (identified by path, not MTP object ID)

/// A file or folder on the phone. The path is the stable identity: MTP object
/// IDs can change after a reconnect, so every operation re-resolves the path.
struct RemoteItem: Identifiable, Hashable, Sendable, Codable {
    let entry: MTPEntry
    /// Full path from the storage root, including this item's name.
    let path: [String]

    var id: String { "\(entry.name)#\(entry.id)" }
    var name: String { entry.name }
    var isFolder: Bool { entry.isFolder }
    var size: UInt64 { entry.isFolder ? 0 : entry.size }
    var modified: Date { entry.modified ?? .distantPast }

    var utType: UTType {
        if entry.isFolder { return .folder }
        return UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
    }

    var kindDescription: String {
        entry.isFolder ? "Thư mục" : (utType.localizedDescription ?? "Tệp")
    }

    /// Photos and videos usually have a phone-generated thumbnail.
    var mayHaveThumbnail: Bool {
        !entry.isFolder && (utType.conforms(to: .image) || utType.conforms(to: .movie))
    }
}

@MainActor
func systemIcon(for item: RemoteItem) -> NSImage {
    NSWorkspace.shared.icon(for: item.utType)
}

func pathString(_ path: [String]) -> String {
    "/" + path.joined(separator: "/")
}

/// "photo.jpg" -> "photo (1).jpg" if taken, and so on.
func uniqueName(_ name: String, taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let ext = (name as NSString).pathExtension
    let base = (name as NSString).deletingPathExtension
    var i = 1
    while true {
        let candidate = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
        if !taken.contains(candidate) { return candidate }
        i += 1
    }
}

// MARK: - Concurrency helpers

/// A cancel flag that the transfer thread can read while the UI sets it.
final class CancelFlag: Sendable {
    private let value = Atomic<Bool>(false)
    func set() { value.store(true, ordering: .relaxed) }
    var isSet: Bool { value.load(ordering: .relaxed) }
}

/// Runs blocking work on a global queue so it never ties up the main thread
/// or Swift's cooperative thread pool.
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: body))
        }
    }
}

/// Human-readable Vietnamese message for an error.
func describe(_ error: Error) -> String {
    switch error {
    case MTPError.noDevice:
        return "Không thấy điện thoại. Hãy mở khoá máy và chọn chế độ \"Chuyển file\"."
    case MTPError.connectionFailed:
        return "Thấy điện thoại nhưng không mở được kết nối. Có thể một app khác (OpenMTP, Android File Transfer, Android Studio) đang dùng nó."
    case MTPError.deviceGone:
        return "Điện thoại đã ngắt kết nối."
    case MTPError.notFound(let p):
        return "Không tìm thấy: \(p)"
    case MTPError.notAFolder(let p):
        return "Không phải thư mục: \(p)"
    case MTPError.alreadyExists(let p):
        return "Đã tồn tại: \(p)"
    case MTPError.cancelled:
        return "Đã huỷ."
    case MTPError.operationFailed(let op, let msgs):
        return msgs.isEmpty ? "\(op) thất bại." : "\(op) thất bại: " + msgs.joined(separator: "; ")
    default:
        return error.localizedDescription
    }
}
