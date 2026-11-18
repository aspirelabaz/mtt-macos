import AppKit
import Foundation
import MTPKit
import Observation

/// State of the browser window: which phone/storage, which folder, what's in it.
@MainActor @Observable
final class BrowserModel {
    enum ViewMode: String { case list, grid }

    var deviceID: String?
    var storageID: UInt32?
    private(set) var path: [String] = []
    private(set) var items: [RemoteItem] = []
    private(set) var isLoading = false
    var errorMessage: String?
    var selection = Set<RemoteItem.ID>()
    var search = ""
    var viewMode: ViewMode = .list

    /// Items marked with Cut (⌘X), waiting for Paste. Only valid while the
    /// clipboard hasn't changed since (copying something else cancels it).
    struct CutState {
        let deviceID: String
        let storageID: UInt32
        let items: [RemoteItem]
        let pasteboardChange: Int
    }
    var cut: CutState?

    /// The pending cut, if it still applies to this phone/storage and the clipboard.
    var activeCut: CutState? {
        guard let cut, cut.deviceID == deviceID, cut.storageID == storageID,
              cut.pasteboardChange == NSPasteboard.general.changeCount else { return nil }
        return cut
    }

    func isCut(_ item: RemoteItem) -> Bool {
        activeCut?.items.contains { $0.path == item.path } == true
    }
    var sortOrder = [KeyPathComparator(\RemoteItem.name, comparator: .localizedStandard)]

    private var back: [[String]] = []
    private var forward: [[String]] = []
    private var loadTask: Task<Void, Never>?

    var device: ConnectedDevice? { DeviceManager.shared.device(id: deviceID) }
    var storage: MTPStorage? { device?.storages.first { $0.id == storageID } }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { !path.isEmpty }

    /// Folders first, then the chosen sort, filtered by the search text.
    var visibleItems: [RemoteItem] {
        let filtered = search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) }
        let sorted = filtered.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    var selectedItems: [RemoteItem] {
        items.filter { selection.contains($0.id) }
    }

    // MARK: - Choosing a phone / storage

    func select(device: ConnectedDevice, storage: MTPStorage) {
        guard device.id != deviceID || storage.id != storageID else { return }
        deviceID = device.id
        storageID = storage.id
        path = []
        back = []
        forward = []
        reload()
    }

    /// Picks the first ready phone's first storage if nothing valid is selected.
    func autoSelect() {
        if let d = device, d.isReady, storage != nil { return }
        guard let d = DeviceManager.shared.devices.first(where: \.isReady), let s = d.storages.first else {
            if device == nil { deviceID = nil; storageID = nil; items = []; path = [] }
            return
        }
        select(device: d, storage: s)
    }

    // MARK: - Navigation

    func open(folder item: RemoteItem) {
        guard item.isFolder else { return }
        navigate(to: item.path)
    }

    func navigate(to newPath: [String]) {
        guard newPath != path else { return }
        back.append(path)
        forward.removeAll()
        path = newPath
        reload()
    }

    func goBack() {
        guard let p = back.popLast() else { return }
        forward.append(path)
        path = p
        reload()
    }

    func goForward() {
        guard let p = forward.popLast() else { return }
        back.append(path)
        path = p
        reload()
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: Array(path.dropLast()))
    }

    // MARK: - Loading

    func reload() {
        loadTask?.cancel()
        selection.removeAll()
        guard let device, device.isReady, let storageID else {
            items = []
            return
        }
        let requested = path
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let result = try await device.list(storageID: storageID, path: requested)
                guard !Task.isCancelled, requested == path else { return }
                items = result
            } catch {
                guard !Task.isCancelled, requested == path else { return }
                items = []
                errorMessage = describe(error)
            }
            isLoading = false
        }
    }
}

/// Loads and caches phone-made thumbnails.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 600 }

    func image(for item: RemoteItem, storageID: UInt32, on device: ConnectedDevice) async -> NSImage? {
        let key = "\(device.id):\(storageID):\(pathString(item.path)):\(item.entry.size)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let flag = CancelFlag()
        let data = await withTaskCancellationHandler {
            await device.thumbnail(for: item, cancel: flag)
        } onCancel: {
            flag.set()
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
