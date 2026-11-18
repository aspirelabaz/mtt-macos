import CoreTransferable
import Foundation
import MTPKit
import UniformTypeIdentifiers

extension UTType {
    /// An item being dragged inside MTT (declared in Info.plist).
    static let mttItem = UTType(exportedAs: "local.mtt.item")
}

/// What gets dragged out of the browser.
///
/// Inside MTT the drop target reads the `local.mtt.item` representation (just
/// the path) and moves the item on the phone. Other apps like Finder only know
/// the file representations; the file is copied off the phone when they ask.
struct DragPayload: Transferable, Sendable, Codable {
    let item: RemoteItem
    let storageID: UInt32
    let deviceID: String

    static var transferRepresentation: some TransferRepresentation {
        // First, so drops inside MTT pick it up without copying anything.
        CodableRepresentation(contentType: .mttItem)

        // Without suggestedFileName, Finder names the dropped file after the
        // content type ("data", no extension).
        FileRepresentation(exportedContentType: .folder) { payload in
            SentTransferredFile(try await payload.fetch())
        }
        .suggestedFileName { $0.item.name }
        .exportingCondition { $0.item.isFolder }

        FileRepresentation(exportedContentType: .data) { payload in
            SentTransferredFile(try await payload.fetch())
        }
        .suggestedFileName { $0.item.name }
        .exportingCondition { !$0.item.isFolder }
    }

    /// Copies the item into a fresh temp folder (keeping its name) and returns it.
    func fetch() async throws -> URL {
        try await DragExport.fetch(self)
    }
}

/// What can be dropped on the browser: an item dragged inside MTT, or a file
/// from Finder (or any app that provides file URLs).
enum DropItem: Transferable, Sendable {
    case remote(DragPayload)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        // Import-only. Order matters: prefer the MTT item when both are offered.
        ProxyRepresentation(importing: { (payload: DragPayload) in DropItem.remote(payload) })
        ProxyRepresentation(importing: { (url: URL) in DropItem.file(url) })
    }
}

@MainActor
enum DragExport {
    static func fetch(_ p: DragPayload) async throws -> URL {
        guard let device = DeviceManager.shared.device(id: p.deviceID), device.isReady else {
            throw MTPError.deviceGone
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MTT-drag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let urls = try await TransferManager.shared.download(
            [p.item], storageID: p.storageID, from: device, to: dir, temporary: true)
        guard let url = urls.first else { throw MTPError.notFound(p.item.name) }
        return url
    }
}
