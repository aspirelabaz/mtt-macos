import CoreTransferable
import Foundation
import MTPKit
import UniformTypeIdentifiers

/// What gets dragged out of the browser. The file is only copied off the phone
/// when the drop target (e.g. Finder) asks for it.
struct DragPayload: Transferable, Sendable {
    let item: RemoteItem
    let storageID: UInt32
    let deviceID: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { payload in
            SentTransferredFile(try await payload.fetch())
        }
        .exportingCondition { $0.item.isFolder }

        FileRepresentation(exportedContentType: .data) { payload in
            SentTransferredFile(try await payload.fetch())
        }
        .exportingCondition { !$0.item.isFolder }
    }

    /// Copies the item into a fresh temp folder (keeping its name) and returns it.
    func fetch() async throws -> URL {
        try await DragExport.fetch(self)
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
