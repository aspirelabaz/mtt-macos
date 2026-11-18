import AppKit
import Foundation
import MTPKit
import MTTShared
import Observation
import os

private let log = MTTLog.logger("transfer")

@MainActor @Observable
final class TransferJob: Identifiable {
    enum Kind { case download, upload }
    enum State: Equatable {
        case queued, running, cancelling, done, cancelled
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .done, .cancelled, .failed: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let deviceID: String
    /// Temporary jobs (opening a file, dragging to Finder) are hidden once done.
    let isTemporary: Bool

    var state: State = .queued
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64 = 0
    var filesDone = 0
    var filesTotal = 0
    var currentFile = ""
    /// Where a finished download landed (top-level item).
    var resultURL: URL?
    /// Extra line shown when the job is done (e.g. "paste with ⌘V").
    var doneNote: String?

    let cancelFlag = CancelFlag()

    init(kind: Kind, title: String, deviceID: String, isTemporary: Bool) {
        self.kind = kind
        self.title = title
        self.deviceID = deviceID
        self.isTemporary = isTemporary
    }

    var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }

    func cancel() {
        guard !state.isFinished else { return }
        cancelFlag.set()
        state = .cancelling
    }

    fileprivate func finish(_ s: State) {
        if !state.isFinished { state = s }
    }
}

/// Progress reports from the worker thread, throttled to ~10 per second.
private final class ProgressRelay: @unchecked Sendable {
    private let job: TransferJob
    private var last = Date.distantPast
    private var baseBytes: UInt64 = 0  // bytes of files already finished

    init(job: TransferJob) { self.job = job }

    func startFile(_ name: String, index: Int) {
        let job = self.job
        Task { @MainActor in
            job.currentFile = name
            job.filesDone = index
        }
    }

    func fileFinished(size: UInt64) {
        baseBytes += size
        let done = baseBytes
        let job = self.job
        Task { @MainActor in job.bytesDone = done }
    }

    /// Returns false when the user cancelled.
    func progress(_ done: UInt64, cancel: CancelFlag) -> Bool {
        let now = Date()
        if now.timeIntervalSince(last) > 0.1 {
            last = now
            let total = baseBytes + done
            let job = self.job
            Task { @MainActor in job.bytesDone = total }
        }
        return !cancel.isSet
    }
}

@MainActor @Observable
final class TransferManager {
    static let shared = TransferManager()

    private(set) var jobs: [TransferJob] = []

    var visibleJobs: [TransferJob] {
        jobs.filter { !($0.isTemporary && $0.state == .done) }
    }

    var activeCount: Int { jobs.filter { !$0.state.isFinished }.count }

    init() {
        DeviceManager.shared.onDeviceRemoved = { [weak self] id in
            self?.deviceRemoved(id)
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    private func deviceRemoved(_ deviceID: String) {
        for job in jobs where job.deviceID == deviceID && !job.state.isFinished {
            job.cancelFlag.set()
            job.finish(.failed("Điện thoại đã ngắt kết nối."))
        }
    }

    // MARK: - Download

    /// Copies items (files or whole folders) from the phone into `directory`.
    /// Names that already exist get " (1)", " (2)"... Returns the local URLs.
    @discardableResult
    func download(_ items: [RemoteItem], storageID: UInt32, from device: ConnectedDevice,
                  to directory: URL, temporary: Bool = false, titlePrefix: String = "") async throws -> [URL] {
        let title = titlePrefix + (items.count == 1 ? items[0].name : "\(items.count) mục")
        let job = TransferJob(kind: .download, title: title, deviceID: device.id, isTemporary: temporary)
        jobs.insert(job, at: 0)
        let relay = ProgressRelay(job: job)
        let cancel = job.cancelFlag
        let started = Date()
        log.notice("download start: \(title, privacy: .public) -> \(directory.path, privacy: .public)")

        do {
            // 1. Plan: expand folders into a file list so progress has a real total.
            job.state = .running
            job.currentFile = "Đang chuẩn bị…"
            struct PlannedFile: Sendable { let entry: MTPEntry; let local: URL }
            struct Plan: Sendable { var dirs: [URL] = []; var files: [PlannedFile] = []; var tops: [URL] = [] }

            let plan: Plan = try await device.run { dev, resolver in
                var plan = Plan()
                var taken = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])

                func walk(_ entry: MTPEntry, path: [String], local: URL) throws {
                    if cancel.isSet { throw MTPError.cancelled }
                    if entry.isFolder {
                        plan.dirs.append(local)
                        for child in try resolver.list(dev, storageID: storageID, path: path) {
                            try walk(child, path: path + [child.name], local: local.appendingPathComponent(child.name))
                        }
                    } else {
                        plan.files.append(PlannedFile(entry: entry, local: local))
                    }
                }

                for item in items {
                    let current = try resolver.entry(dev, storageID: storageID, path: item.path)
                    let name = uniqueName(item.name, taken: taken)
                    taken.insert(name)
                    let local = directory.appendingPathComponent(name)
                    plan.tops.append(local)
                    try walk(current, path: item.path, local: local)
                }
                return plan
            }
            job.filesTotal = plan.files.count
            job.bytesTotal = plan.files.reduce(0) { $0 + $1.entry.size }

            // 2. Copy.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dir in plan.dirs {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try await device.run { dev, _ in
                for (i, file) in plan.files.enumerated() {
                    if cancel.isSet { throw MTPError.cancelled }
                    relay.startFile(file.entry.name, index: i)
                    try dev.download(file.entry, to: file.local.path) { done, _ in
                        relay.progress(done, cancel: cancel)
                    }
                    relay.fileFinished(size: file.entry.size)
                }
            }
            job.filesDone = plan.files.count
            job.bytesDone = job.bytesTotal
            job.resultURL = plan.tops.first
            job.finish(.done)
            log.notice("download done: \(title, privacy: .public), \(plan.files.count) file(s), \(job.bytesTotal) bytes in \(elapsed(since: started), privacy: .public)")
            return plan.tops
        } catch {
            log.error("download failed: \(title, privacy: .public) after \(elapsed(since: started), privacy: .public): \(describe(error), privacy: .public)")
            if case MTPError.cancelled = error { job.finish(.cancelled) } else { job.finish(.failed(describe(error))) }
            throw error
        }
    }

    // MARK: - Upload

    /// Copies local files or folders into the phone folder at `path`.
    func upload(_ urls: [URL], storageID: UInt32, to path: [String], on device: ConnectedDevice) async throws {
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) mục"
        let job = TransferJob(kind: .upload, title: title, deviceID: device.id, isTemporary: false)
        jobs.insert(job, at: 0)
        let relay = ProgressRelay(job: job)
        let cancel = job.cancelFlag

        // 1. Plan the local side (sizes for the progress total).
        indirect enum Node: Sendable {
            case file(URL, UInt64)
            case folder(URL, [Node])
        }
        func scan(_ url: URL) -> Node? {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            if isDir.boolValue {
                let children = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                    .compactMap { scan(url.appendingPathComponent($0)) }
                return .folder(url, children)
            }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            return .file(url, size)
        }
        func totals(_ n: Node) -> (Int, UInt64) {
            switch n {
            case .file(_, let s): return (1, s)
            case .folder(_, let kids): return kids.map(totals).reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
            }
        }
        let nodes = urls.compactMap(scan)
        let t = nodes.map(totals).reduce((0, UInt64(0))) { ($0.0 + $1.0, $0.1 + $1.1) }
        job.filesTotal = t.0
        job.bytesTotal = t.1
        job.state = .running
        let started = Date()
        log.notice("upload start: \(title, privacy: .public) -> \(pathString(path), privacy: .public), \(t.0) file(s), \(t.1) bytes")

        do {
            try await device.run { dev, resolver in
                var index = 0
                func send(_ node: Node, name: String, parentID: UInt32) throws {
                    if cancel.isSet { throw MTPError.cancelled }
                    switch node {
                    case .file(let url, let size):
                        relay.startFile(name, index: index)
                        try dev.upload(localPath: url.path, name: name, storageID: storageID, parentID: parentID) { done, _ in
                            relay.progress(done, cancel: cancel)
                        }
                        relay.fileFinished(size: size)
                        index += 1
                    case .folder(_, let kids):
                        let folder = try dev.createFolder(name: name, storageID: storageID, parentID: parentID)
                        for kid in kids {
                            let kidName: String
                            switch kid {
                            case .file(let u, _), .folder(let u, _): kidName = u.lastPathComponent
                            }
                            try send(kid, name: kidName, parentID: folder.id)
                        }
                    }
                }

                let parentID = try resolver.folderID(dev, storageID: storageID, path: path)
                var taken = Set(try dev.list(storageID: storageID, folderID: parentID).map(\.name))
                for node in nodes {
                    let base: String
                    switch node {
                    case .file(let u, _), .folder(let u, _): base = u.lastPathComponent
                    }
                    let name = uniqueName(base, taken: taken)
                    taken.insert(name)
                    try send(node, name: name, parentID: parentID)
                }
                resolver.invalidate()
            }
            job.filesDone = job.filesTotal
            job.bytesDone = job.bytesTotal
            job.finish(.done)
            log.notice("upload done: \(title, privacy: .public) in \(elapsed(since: started), privacy: .public)")
        } catch {
            log.error("upload failed: \(title, privacy: .public) after \(elapsed(since: started), privacy: .public): \(describe(error), privacy: .public)")
            if case MTPError.cancelled = error { job.finish(.cancelled) } else { job.finish(.failed(describe(error))) }
            device.changeCounter += 1
            throw error
        }
        device.changeCounter += 1
        await device.refreshStorages()
    }

    // MARK: - Copy / paste

    /// Temp folder holding the files currently on the clipboard.
    private var clipboardDir: URL?

    /// Copies items off the phone into a temp folder and puts those files on the
    /// clipboard, so ⌘V works in Finder (Finder can only paste files that exist).
    func copyToPasteboard(_ items: [RemoteItem], storageID: UInt32, from device: ConnectedDevice) async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MTT-clipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let urls = try? await download(items, storageID: storageID, from: device, to: dir,
                                             titlePrefix: "Sao chép: ") else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        // The previous clipboard copy is no longer reachable from the clipboard.
        if let old = clipboardDir { try? FileManager.default.removeItem(at: old) }
        clipboardDir = dir
        if let job = jobs.first(where: { $0.resultURL == urls.first }) {
            job.doneNote = "Đã vào clipboard, dán vào Finder bằng ⌘V"
        }
    }

    /// File URLs currently on the clipboard (copied in Finder or in this app).
    static func pasteboardFileURLs() -> [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return objects ?? []
    }

    static var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    // MARK: - Open with the default app

    /// Downloads a file to a temp folder and opens it.
    func open(_ item: RemoteItem, storageID: UInt32, from device: ConnectedDevice) async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MTT-open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        if let url = try? await download([item], storageID: storageID, from: device, to: dir, temporary: true).first {
            NSWorkspace.shared.open(url)
        }
    }
}
