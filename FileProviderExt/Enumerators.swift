import FileProvider
import Foundation
import MTTShared

/// Last seen contents of each folder Finder has listed, used to work out what
/// changed on the phone (MTP gives no change feed we use).
final class FolderSnapshots {
    private let lock = NSLock()
    private var byFolder: [String: (path: [String], entries: [String: EntryDTO], seen: Date)] = [:]
    private let maxFolders = 40

    func store(_ path: [String], _ entries: [EntryDTO]) {
        lock.lock(); defer { lock.unlock() }
        byFolder[path.joined(separator: "/")] = (path, Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }), Date())
        if byFolder.count > maxFolders,
           let oldest = byFolder.min(by: { $0.value.seen < $1.value.seen })?.key {
            byFolder[oldest] = nil
        }
    }

    func previous(_ path: [String]) -> [String: EntryDTO]? {
        lock.lock(); defer { lock.unlock() }
        return byFolder[path.joined(separator: "/")]?.entries
    }

    /// Most recently listed folders first.
    var folders: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return byFolder.values.sorted { $0.seen > $1.seen }.map(\.path)
    }

    func forget(_ path: [String]) {
        lock.lock(); defer { lock.unlock() }
        byFolder[path.joined(separator: "/")] = nil
    }
}

/// Sync anchors are just timestamps: changes are found by re-listing.
private func makeAnchor() -> NSFileProviderSyncAnchor {
    NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8))
}

/// Re-lists `path` and reports items added/changed and removed since the last listing.
private func reportChanges(in path: [String], ext: FileProviderExtension,
                           observer: NSFileProviderChangeObserver) async throws {
    let before = ext.snapshots.previous(path)
    let now = try await ext.listFolder(path)
    let changed = now.filter { before?[$0.name] != $0 }
    if !changed.isEmpty {
        observer.didUpdate(ext.makeItems(changed, parentPath: path))
    }
    if let before {
        let nowNames = Set(now.map(\.name))
        let removed = before.keys.filter { !nowNames.contains($0) }
        if !removed.isEmpty {
            observer.didDeleteItems(withIdentifiers: ext.ids.identifiers(for: removed.map { path + [$0] }))
            for name in removed { ext.ids.remove(path + [name]) }
        }
    }
}

final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let ext: FileProviderExtension
    private let path: [String]

    init(ext: FileProviderExtension, path: [String]) {
        self.ext = ext
        self.path = path
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let started = Date()
        Task {
            do {
                let entries = try await ext.listFolder(path)
                observer.didEnumerate(ext.makeItems(entries, parentPath: path))
                observer.finishEnumerating(upTo: nil)
                fpLog.info("enumerate \(pathString(self.path), privacy: .public): \(entries.count) items in \(elapsed(since: started), privacy: .public)")
            } catch {
                fpLog.error("enumerate \(pathString(self.path), privacy: .public) failed after \(elapsed(since: started), privacy: .public): \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                try await reportChanges(in: path, ext: ext, observer: observer)
                observer.finishEnumeratingChanges(upTo: makeAnchor(), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(makeAnchor())
    }
}

/// The system asks the working set for changes after `signalEnumerator`. We
/// re-list the folders Finder has looked at recently and report differences.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let ext: FileProviderExtension

    init(ext: FileProviderExtension) { self.ext = ext }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Folder contents come from the folder enumerators.
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            for folder in ext.snapshots.folders.prefix(20) {
                do {
                    try await reportChanges(in: folder, ext: ext, observer: observer)
                } catch {
                    let e = fileProviderError(error) as NSError
                    if e.domain == NSFileProviderErrorDomain && e.code == NSFileProviderError.serverUnreachable.rawValue {
                        observer.finishEnumeratingWithError(e)
                        return
                    }
                    ext.snapshots.forget(folder)  // folder vanished; its parent will report it
                }
            }
            observer.finishEnumeratingChanges(upTo: makeAnchor(), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(makeAnchor())
    }
}
