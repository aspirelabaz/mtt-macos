import FileProvider
import Foundation
import MTTShared
import UniformTypeIdentifiers
import os

let fpLog = MTTLog.logger("fileprovider")

func pathString(_ path: [String]) -> String { "/" + path.joined(separator: "/") }

/// Shows one phone storage in Finder. Every operation goes to the MTT app over
/// XPC; file contents travel as file descriptors.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let serial: String
    let storageID: UInt32
    let client = ServiceClient()
    let ids: IDMap
    let snapshots = FolderSnapshots()
    private(set) var readOnly = false

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let parsed = MTTDomainID.parse(domain.identifier.rawValue)
        serial = parsed?.serial ?? ""
        storageID = parsed?.storageID ?? 0
        ids = IDMap(domainID: domain.identifier.rawValue)
        super.init()
        Self.cleanOldTransfers()
        Task { [weak self] in
            guard let self else { return }
            if let s = try? await client.storages(serial: serial).first(where: { $0.id == self.storageID }) {
                readOnly = s.isReadOnly
            }
        }
    }

    func invalidate() {}

    // MARK: - Items

    func makeItem(_ entry: EntryDTO, parentPath: [String]) -> FileProviderItem {
        makeItems([entry], parentPath: parentPath)[0]
    }

    /// Items for a folder's children; all identifiers in one database transaction.
    func makeItems(_ entries: [EntryDTO], parentPath: [String]) -> [FileProviderItem] {
        let idList = ids.identifiers(for: [parentPath] + entries.map { parentPath + [$0.name] })
        let parent = idList[0]
        return zip(entries, idList.dropFirst()).map { entry, id in
            FileProviderItem(identifier: id, parent: parent, entry: entry, readOnly: readOnly)
        }
    }

    private func requirePath(_ identifier: NSFileProviderItemIdentifier) throws -> [String] {
        guard let path = ids.path(for: identifier) else { throw NSFileProviderError(.noSuchItem) }
        return path
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(FileProviderItem.root(name: domain.displayName, readOnly: readOnly), nil)
            return Progress()
        }
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let path = try requirePath(identifier)
                let entry = try await client.entry(serial: serial, storageID: storageID, path: path)
                completionHandler(makeItem(entry, parentPath: Array(path.dropLast())), nil)
            } catch {
                completionHandler(nil, fileProviderError(error))
            }
            progress.completedUnitCount = progress.totalUnitCount
        }
        return progress
    }

    // MARK: - Reading

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        // Units are per mille; the app's byte progress is attached as a child.
        let progress = Progress(totalUnitCount: 1000)
        let started = Date()
        Task {
            do {
                let path = try requirePath(itemIdentifier)
                let entry = try await client.entry(serial: serial, storageID: storageID, path: path)
                // Download into a file in our own temp folder; the app writes to it
                // through the descriptor we pass over XPC.
                let dir = try Self.makeTempDirectory()
                let dest = dir.appendingPathComponent(entry.name)
                guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: dest)
                do {
                    try await client.download(serial: serial, storageID: storageID, path: path, into: handle,
                                              progress: progress)
                    try? handle.close()
                } catch {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: dir)
                    throw error
                }
                fpLog.notice("fetch \(pathString(path), privacy: .public) (\(entry.size) bytes) in \(elapsed(since: started), privacy: .public)")
                completionHandler(dest, makeItem(entry, parentPath: Array(path.dropLast())), nil)
            } catch {
                fpLog.error("fetch \(itemIdentifier.rawValue, privacy: .public) failed after \(elapsed(since: started), privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, fileProviderError(error))
            }
            progress.completedUnitCount = progress.totalUnitCount
        }
        return progress
    }

    // MARK: - Writing

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1000)
        Task {
            do {
                if readOnly { throw CocoaError(.fileWriteNoPermission) }
                let parentPath = try requirePath(itemTemplate.parentItemIdentifier)
                let name = phoneName(itemTemplate.filename)
                let isFolder = itemTemplate.contentType?.conforms(to: .folder) == true
                    || itemTemplate.contentType?.conforms(to: .directory) == true
                let entry: EntryDTO
                if isFolder {
                    entry = try await client.createFolder(serial: serial, storageID: storageID,
                                                          parentPath: parentPath, name: name)
                } else if let url {
                    if itemTemplate.contentType?.conforms(to: .symbolicLink) == true {
                        throw CocoaError(.featureUnsupported)
                    }
                    entry = try await upload(url, parentPath: parentPath, name: name,
                                             replace: options.contains(.mayAlreadyExist), progress: progress)
                } else {
                    throw CocoaError(.featureUnsupported)
                }
                fpLog.notice("create \(pathString(parentPath + [entry.name]), privacy: .public) (\(isFolder ? "folder" : "\(entry.size) bytes", privacy: .public))")
                completionHandler(makeItem(entry, parentPath: parentPath), [], false, nil)
            } catch {
                fpLog.error("create \(itemTemplate.filename, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, fileProviderError(error))
            }
            progress.completedUnitCount = progress.totalUnitCount
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1000)
        Task {
            do {
                if readOnly { throw CocoaError(.fileWriteNoPermission) }
                var path = try requirePath(item.itemIdentifier)
                // Read the current metadata first and build the result from it, rather
                // than looking the item up again right after changing it.
                var entry = try await client.entry(serial: serial, storageID: storageID, path: path)
                // Moved to another folder (MTP MoveObject; same storage = same domain).
                if changedFields.contains(.parentItemIdentifier) {
                    let newParent = try requirePath(item.parentItemIdentifier)
                    if newParent != Array(path.dropLast()) {
                        try await client.move(serial: serial, storageID: storageID, path: path, newParentPath: newParent)
                        let newPath = newParent + [path.last ?? entry.name]
                        ids.move(from: path, to: newPath)
                        path = newPath
                    }
                }
                let newName = phoneName(item.filename)
                if changedFields.contains(.filename), newName != path.last {
                    try await client.rename(serial: serial, storageID: storageID, path: path, newName: newName)
                    let newPath = Array(path.dropLast()) + [newName]
                    ids.move(from: path, to: newPath)
                    path = newPath
                    entry.name = newName
                }
                if changedFields.contains(.contents), let newContents {
                    let uploaded = try await upload(newContents, parentPath: Array(path.dropLast()),
                                                    name: path.last ?? item.filename, replace: true, progress: progress)
                    entry.size = uploaded.size
                    entry.modified = uploaded.modified
                }
                // Dates, tags etc. can't be stored on the phone: report them as handled.
                fpLog.notice("modify \(pathString(path), privacy: .public) fields=\(changedFields.rawValue)")
                completionHandler(makeItem(entry, parentPath: Array(path.dropLast())), [], false, nil)
            } catch {
                fpLog.error("modify \(item.filename, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, fileProviderError(error))
            }
            progress.completedUnitCount = progress.totalUnitCount
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                if readOnly { throw CocoaError(.fileWriteNoPermission) }
                let path = try requirePath(identifier)
                do {
                    try await client.delete(serial: serial, storageID: storageID, path: path)
                } catch let e as NSError where e.domain == MTTServiceError.domain && e.code == MTTServiceError.notFound.rawValue {
                    // Already gone on the phone: that's what we wanted.
                }
                ids.remove(path)
                fpLog.notice("delete \(pathString(path), privacy: .public)")
                completionHandler(nil)
            } catch {
                fpLog.error("delete \(identifier.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                completionHandler(fileProviderError(error))
            }
            progress.completedUnitCount = progress.totalUnitCount
        }
        return progress
    }

    /// The app can't open the system's staging file by path, so hand it an open descriptor.
    private func upload(_ url: URL, parentPath: [String], name: String, replace: Bool,
                        progress: Progress? = nil) async throws -> EntryDTO {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try await client.upload(serial: serial, storageID: storageID, parentPath: parentPath,
                                       name: name, from: handle, replaceExisting: replace, progress: progress)
    }

    /// Names go to the phone in NFC: Finder may hand over decomposed (NFD) text,
    /// and mixing forms can give two files that look identical.
    private func phoneName(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    private static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Transfers", isDirectory: true)
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet { return WorkingSetEnumerator(ext: self) }
        if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        guard let path = ids.path(for: containerItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
        return FolderEnumerator(ext: self, path: path)
    }

    /// Lists a folder and records what was seen (for later change detection).
    func listFolder(_ path: [String]) async throws -> [EntryDTO] {
        let entries = try await client.list(serial: serial, storageID: storageID, path: path)
        snapshots.store(path, entries)
        return entries
    }

    // MARK: - Housekeeping

    /// Downloads handed to the system are cleaned up after a while.
    private static func cleanOldTransfers() {
        guard let items = try? FileManager.default.contentsOfDirectory(
                at: tempRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for item in items {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }
}
