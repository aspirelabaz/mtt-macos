import FileProvider
import Foundation
import MTTShared
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    private let entry: EntryDTO
    private let readOnly: Bool

    init(identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier,
         entry: EntryDTO, readOnly: Bool) {
        itemIdentifier = identifier
        parentItemIdentifier = parent
        filename = entry.name
        self.entry = entry
        self.readOnly = readOnly
    }

    static func root(name: String, readOnly: Bool) -> FileProviderItem {
        FileProviderItem(identifier: .rootContainer, parent: .rootContainer,
                         entry: EntryDTO(name: name, size: 0, modified: nil, isFolder: true),
                         readOnly: readOnly)
    }

    var contentType: UTType {
        if entry.isFolder { return .folder }
        return UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
    }

    var documentSize: NSNumber? { entry.isFolder ? nil : NSNumber(value: entry.size) }
    var contentModificationDate: Date? { entry.modified }
    var creationDate: Date? { entry.modified }

    var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if entry.isFolder { caps.insert(.allowsContentEnumerating) }
        if !readOnly && itemIdentifier != .rootContainer {
            caps.formUnion([.allowsDeleting, .allowsRenaming, .allowsReparenting])
            if !entry.isFolder { caps.insert(.allowsWriting) }
        }
        if !readOnly && entry.isFolder { caps.insert(.allowsAddingSubItems) }
        return caps
    }

    /// Content changes when size or date change; metadata also covers the name.
    var itemVersion: NSFileProviderItemVersion {
        let stamp = "\(entry.size)|\(entry.modified?.timeIntervalSince1970 ?? 0)"
        return NSFileProviderItemVersion(contentVersion: Data(stamp.utf8),
                                         metadataVersion: Data((stamp + "|" + entry.name).utf8))
    }
}
