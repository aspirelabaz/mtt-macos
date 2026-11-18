import CLibMTP
import CMTPShim
import Foundation
import Synchronization

/// Progress callback: (bytesDone, bytesTotal) -> keep going? Return false to cancel.
public typealias MTPProgress = (UInt64, UInt64) -> Bool

/// An open MTP device.
///
/// libmtp is not thread-safe per device, so every call goes through one lock.
/// After a USB-level error the device is marked dead and every later call
/// throws `MTPError.deviceGone`; open a new `MTPDevice` after re-plugging.
///
/// A cancelled or failed transfer leaves Android's MTP pipe stuck (every later
/// command gets a PTP I/O error), so transfers call `reconnect()` on failure.
/// Object IDs may change across a reconnect: callers should keep paths, not IDs.
public final class MTPDevice: @unchecked Sendable {
    public private(set) var raw: RawDeviceInfo
    public private(set) var info: MTPDeviceInfo
    public private(set) var isAlive = true
    /// False if libmtp's private layout didn't match and the USB reset on close is still on.
    public private(set) var resetOnCloseDisabled = false
    /// Goes up by one on every successful `reconnect()`. Object IDs from an older
    /// generation may no longer be valid.
    public private(set) var sessionGeneration = 0

    private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>? {
        get { handleLock.withLock { _handle } }
        set { handleLock.withLock { _handle = newValue } }
    }
    private var _handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    /// Serializes libmtp calls (held for a whole operation).
    private let lock = NSRecursiveLock()
    /// Guards `_handle` only, so abortPendingIO() can run while an operation
    /// holds `lock` without racing a release of the handle.
    private let handleLock = NSLock()
    /// Called before each attempt to reopen the phone in `reconnect()`, e.g. to
    /// free it from another process that grabbed it while it was released.
    public var beforeReopen: (@Sendable () -> Void)?

    /// Set by abortPendingIO(): the phone is gone, don't try to reconnect.
    private let aborting = Atomic<Bool>(false)

    /// Cancelling a transfer with this much (or less) left just lets it finish
    /// and discards the result: aborting mid-transfer jams Android's USB pipe and
    /// needs a reset + reopen (~4–5 s). At ~28 MB/s, 96 MB takes about as long.
    public static let drainLimit: UInt64 = 96 * 1024 * 1024

    public init(raw: RawDeviceInfo) throws {
        MTP.initialize()
        self.raw = raw
        let (h, resetOff) = try MTPDevice.open(raw)
        info = MTPDevice.readInfo(h)
        _handle = h
        resetOnCloseDisabled = resetOff
    }

    deinit { close() }

    /// Releases the USB connection. Safe to call more than once.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        handleLock.lock()
        if let h = _handle { LIBMTP_Release_Device(h) }
        _handle = nil
        handleLock.unlock()
        isAlive = false
    }

    /// Call when the phone has left USB: makes the operation in progress (if any)
    /// fail within a fraction of a second instead of waiting for libmtp's long
    /// timeouts (~10 s), and stops it from trying to reconnect. Thread-safe and
    /// doesn't wait for the running operation.
    public func abortPendingIO() {
        aborting.store(true, ordering: .relaxed)
        handleLock.lock(); defer { handleLock.unlock() }
        if let h = _handle {
            _ = mtt_set_usb_timeout(h, raw.vendorID, raw.productID, 200)
        }
    }

    /// Drops the session with a USB reset and opens a fresh one on the same phone.
    ///
    /// The reset clears whatever a cancelled transfer left in the USB pipes. The
    /// phone leaves the bus and comes back (~1–2 s), so this blocks until then.
    public func reconnect(timeout: TimeInterval = 10) throws {
        lock.lock(); defer { lock.unlock() }
        let oldSerial = info.serial
        let oldKey = raw.usbKey
        if let h = handle {
            // The pipe is stuck, so the phone won't answer CloseSession or the
            // clear-stall requests; with Android's 60 s timeout closing took ~4 min.
            // Use a short timeout, skip clear-stall/release, and reset the port.
            // (Tried keeping clear-stall: slower, and a later listing failed once.)
            // The next open's first OpenSession still times out (~5 s) and libmtp
            // recovers by itself on its second try; whole recovery is ~12 s.
            _ = mtt_set_usb_timeout(h, raw.vendorID, raw.productID, 300)
            _ = mtt_update_device_flags(h, raw.vendorID, raw.productID,
                                        UInt32(MTT_FLAG_FORCE_RESET_ON_CLOSE | MTT_FLAG_NO_RELEASE_INTERFACE), 0)
            mtpTrace("reconnect: releasing")
            handleLock.withLock {
                LIBMTP_Release_Device(h)
                _handle = nil
            }
            mtpTrace("reconnect: released")
        }
        handle = nil
        isAlive = false

        let deadline = Date().addingTimeInterval(timeout)
        func sameModel(_ d: RawDeviceInfo) -> Bool {
            d.vendorID == raw.vendorID && d.productID == raw.productID
        }

        // The phone needs a moment after the reset before it answers: opening at
        // once got a session that didn't respond and cost another reset (~1.5 s).
        // (It doesn't re-enumerate on macOS, so there's no "left the bus" to wait for.)
        _ = oldKey
        Thread.sleep(forTimeInterval: 0.4)

        mtpTrace("reconnect: old device gone (or gave up waiting)")
        // 2. Wait for it to come back and open it.
        var lastError: Error = MTPError.deviceGone
        var firstTry = true
        while Date() < deadline {
            if !firstTry { Thread.sleep(forTimeInterval: 0.3) }
            firstTry = false
            guard let candidate = ((try? MTP.detectRawDevices()) ?? []).first(where: sameModel) else {
                mtpTrace("reconnect: not on bus yet")
                continue
            }
            beforeReopen?()
            do {
                mtpTrace("reconnect: opening \(candidate.usbKey)")
                let (h, resetOff) = try MTPDevice.open(candidate)
                let newInfo = MTPDevice.readInfo(h)
                if !oldSerial.isEmpty, newInfo.serial != oldSerial {
                    mtpTrace("reconnect: serial mismatch '\(newInfo.serial)'")
                    LIBMTP_Release_Device(h)  // a different phone of the same model
                    continue
                }
                // Only count it as reopened if the phone really answers: a session can
                // open (and even list storages) yet fail every folder listing, e.g.
                // after ptpcamerad was killed in the middle of its own session.
                guard MTPDevice.sessionWorks(h) else {
                    mtpTrace("reconnect: new session doesn't answer, resetting again")
                    LIBMTP_Clear_Errorstack(h)
                    _ = mtt_set_usb_timeout(h, candidate.vendorID, candidate.productID, 300)
                    _ = mtt_update_device_flags(h, candidate.vendorID, candidate.productID,
                                                UInt32(MTT_FLAG_FORCE_RESET_ON_CLOSE | MTT_FLAG_NO_RELEASE_INTERFACE), 0)
                    LIBMTP_Release_Device(h)
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                mtpTrace("reconnect: reopened")
                raw = candidate
                handle = h
                resetOnCloseDisabled = resetOff
                info = newInfo
                isAlive = true
                sessionGeneration += 1
                return
            } catch {
                mtpTrace("reconnect: open failed: \(error)")
                lastError = error
            }
        }
        throw lastError
    }

    /// True if storages can be read and the first storage's root can be listed.
    private static func sessionWorks(_ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> Bool {
        guard LIBMTP_Get_Storage(h, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED)) == 0,
              let storage = h.pointee.storage else { return false }
        let head = LIBMTP_Get_Files_And_Folders(h, storage.pointee.id, MTPRootFolderID)
        var cur = head
        while let f = cur {
            cur = f.pointee.next
            LIBMTP_destroy_file_t(f)
        }
        // NULL with an empty error stack is just an empty storage.
        return head != nil || LIBMTP_Get_Errorstack(h) == nil
    }

    /// Opens a raw device and turns off libmtp's reset-on-close for it.
    private static func open(_ raw: RawDeviceInfo) throws -> (UnsafeMutablePointer<LIBMTP_mtpdevice_t>, Bool) {
        var r = raw.raw
        // Uncached: don't walk the whole file tree on open (slow on big phones).
        guard let h = LIBMTP_Open_Raw_Device_Uncached(&r) else {
            throw MTPError.connectionFailed
        }
        // libmtp's Android profile resets the USB port on close, so the phone drops
        // off the bus ~0.5 s later and reappears ~0.5 s after that. A new session
        // opened in that window gets I/O errors or empty listings. Turn it off.
        // (libmtp sets the flag while opening, so it must be cleared afterwards.)
        let ok = mtt_update_device_flags(h, raw.vendorID, raw.productID,
                                         0, UInt32(MTT_FLAG_FORCE_RESET_ON_CLOSE)) == 0
        return (h, ok)
    }

    // MARK: - Device and storages

    public func refreshInfo() throws -> MTPDeviceInfo {
        try withHandle { h in
            info = MTPDevice.readInfo(h)
            return info
        }
    }

    public func storages() throws -> [MTPStorage] {
        try withHandle { h in
            guard LIBMTP_Get_Storage(h, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED)) == 0 else {
                throw failure("Reading storages", h)
            }
            var out: [MTPStorage] = []
            var s = h.pointee.storage
            while let st = s {
                out.append(MTPStorage(
                    id: st.pointee.id,
                    description: st.pointee.StorageDescription.map { String(cString: $0) } ?? "Storage",
                    capacity: st.pointee.MaxCapacity,
                    freeBytes: st.pointee.FreeSpaceInBytes,
                    accessCapability: st.pointee.AccessCapability))
                s = st.pointee.next
            }
            return out
        }
    }

    // MARK: - Browsing

    /// Lists the direct children of a folder (`MTPRootFolderID` for the storage root).
    public func list(storageID: UInt32, folderID: UInt32) throws -> [MTPEntry] {
        try withHandle { h in
            let head = LIBMTP_Get_Files_And_Folders(h, storageID, folderID)
            // NULL means either "empty folder" or "error"; the error stack tells which.
            if head == nil, let err = takeErrors(h) {
                throw classify("Listing folder", err)
            }
            var out: [MTPEntry] = []
            var cur = head
            while let f = cur {
                out.append(MTPDevice.entry(from: f.pointee))
                cur = f.pointee.next
                LIBMTP_destroy_file_t(f)
            }
            return out
        }
    }

    /// Metadata for one object.
    public func entry(id: UInt32) throws -> MTPEntry {
        try withHandle { h in
            guard let f = LIBMTP_Get_Filemetadata(h, id) else {
                throw classify("Reading metadata", takeErrors(h) ?? ([], false))
            }
            defer { LIBMTP_destroy_file_t(f) }
            return MTPDevice.entry(from: f.pointee)
        }
    }

    /// Resolves "/DCIM/Camera/x.jpg" by walking folders from the storage root.
    /// Returns the synthetic root entry for "/" or "".
    public func resolve(path: String, storageID: UInt32) throws -> MTPEntry {
        var current = MTPEntry.root(storageID: storageID)
        var walked = ""
        for name in mtpPathComponents(path) {
            guard current.isFolder else { throw MTPError.notAFolder(walked.isEmpty ? "/" : walked) }
            walked += "/" + name
            let children = try list(storageID: storageID, folderID: current.id)
            guard let next = children.first(where: { $0.name == name }) else {
                throw MTPError.notFound(walked)
            }
            current = next
        }
        return current
    }

    // MARK: - Transfers

    /// Copies a file from the device to `localPath`, keeping its modification date.
    /// A partial file is removed on failure.
    public func download(_ entry: MTPEntry, to localPath: String, progress: MTPProgress? = nil) throws {
        try download(id: entry.id, to: localPath, progress: progress)
        var attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o644]
        if let modified = entry.modified { attrs[.modificationDate] = modified }
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: localPath)
    }

    /// Copies a file from the device to `localPath`. A partial file is removed on failure.
    public func download(id: UInt32, to localPath: String, progress: MTPProgress? = nil) throws {
        let fd = Darwin.open(localPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw MTPError.operationFailed("Download", ["cannot create \(localPath): \(String(cString: strerror(errno)))"])
        }
        do {
            try download(id: id, toFileDescriptor: fd, progress: progress)
            Darwin.close(fd)
        } catch {
            Darwin.close(fd)
            unlink(localPath)
            throw error
        }
    }

    /// Copies a file from the device into an open, writable file descriptor
    /// (e.g. one passed over XPC by a sandboxed process). Does not close it.
    public func download(id: UInt32, toFileDescriptor fd: Int32, progress: MTPProgress? = nil) throws {
        try withHandle { h in
            let box = ProgressBox(progress, onCancel: shortenTimeoutForCancel(h))
            let rc = withExtendedLifetime(box) {
                LIBMTP_Get_File_To_File_Descriptor(h, id, fd, progressTrampoline,
                                                   UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
            }
            if rc == 0 && box.drained {
                mtpTrace("download cancelled near the end: finished it and discarded the data")
                throw MTPError.cancelled  // callers remove the partial file
            }
            if rc != 0 {
                mtpTrace("libmtp transfer returned \(rc)")
                let err = takeErrors(h) ?? ([], false)
                let error = box.cancelled ? MTPError.cancelled : classify("Download", err)
                try recoverAfterAbortedTransfer(error)
                throw error
            }
        }
    }

    /// Copies a local file into a device folder. Returns the new entry.
    @discardableResult
    public func upload(localPath: String, name: String? = nil, storageID: UInt32, parentID: UInt32,
                       progress: MTPProgress? = nil) throws -> MTPEntry {
        let fd = Darwin.open(localPath, O_RDONLY)
        guard fd >= 0 else {
            throw MTPError.operationFailed("Upload", ["cannot open \(localPath): \(String(cString: strerror(errno)))"])
        }
        defer { Darwin.close(fd) }
        return try upload(fileDescriptor: fd, name: name ?? (localPath as NSString).lastPathComponent,
                          storageID: storageID, parentID: parentID, progress: progress)
    }

    /// Copies everything readable from `fd` into a device folder as `name`.
    /// Size and date come from fstat. Does not close the descriptor.
    @discardableResult
    public func upload(fileDescriptor fd: Int32, name fileName: String, storageID: UInt32, parentID: UInt32,
                       progress: MTPProgress? = nil) throws -> MTPEntry {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            throw MTPError.operationFailed("Upload", ["cannot stat file: \(String(cString: strerror(errno)))"])
        }
        let size = UInt64(st.st_size)
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

        return try withHandle { h in
            guard let f = LIBMTP_new_file_t() else {
                throw MTPError.operationFailed("Upload", ["out of memory"])
            }
            defer { LIBMTP_destroy_file_t(f) }  // also frees filename
            f.pointee.filename = strdup(fileName)
            f.pointee.filesize = size
            f.pointee.parent_id = parentID
            f.pointee.storage_id = storageID
            f.pointee.modificationdate = time_t(mtime.timeIntervalSince1970)
            f.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN  // Android picks the type from the extension

            let box = ProgressBox(progress, onCancel: shortenTimeoutForCancel(h))
            let rc = withExtendedLifetime(box) {
                LIBMTP_Send_File_From_File_Descriptor(h, fd, f, progressTrampoline,
                                                      UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
            }
            if rc == 0 && box.drained {
                mtpTrace("upload cancelled near the end: finished it and deleted the file")
                if f.pointee.item_id != 0 { _ = LIBMTP_Delete_Object(h, f.pointee.item_id) }
                LIBMTP_Clear_Errorstack(h)
                throw MTPError.cancelled
            }
            if rc != 0 {
                mtpTrace("libmtp transfer returned \(rc)")
                let err = takeErrors(h) ?? ([], false)
                let error = box.cancelled ? MTPError.cancelled : classify("Upload", err)
                // Reset the stuck pipe first; then remove the half-written object,
                // looking it up by name because its ID may change on reconnect.
                try recoverAfterAbortedTransfer(error)
                if f.pointee.item_id != 0,
                   let partial = try? list(storageID: storageID, folderID: parentID)
                    .first(where: { $0.name == fileName && !$0.isFolder }) {
                    try? delete(id: partial.id)
                }
                throw error
            }
            return MTPEntry(id: f.pointee.item_id, parentID: parentID, storageID: storageID,
                            name: fileName, size: size, modified: mtime, isFolder: false)
        }
    }

    /// The phone's own small preview (usually JPEG) for photos and videos, or nil.
    public func thumbnail(id: UInt32) throws -> Data? {
        try withHandle { h in
            var data: UnsafeMutablePointer<UInt8>?
            var size: UInt32 = 0
            let rc = LIBMTP_Get_Thumbnail(h, id, &data, &size)
            defer { free(data) }
            guard rc == 0, let data, size > 0 else {
                // "No thumbnail" is normal for most files; only USB failures matter.
                if let err = takeErrors(h), err.1 { throw classify("Thumbnail", err) }
                return nil
            }
            return Data(bytes: data, count: Int(size))
        }
    }

    // MARK: - Changing things

    /// Creates a folder and returns its entry.
    @discardableResult
    public func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> MTPEntry {
        try withHandle { h in
            let cName = strdup(name)
            defer { free(cName) }
            let newID = LIBMTP_Create_Folder(h, cName, parentID, storageID)
            guard newID != 0 else { throw classify("Creating folder", takeErrors(h) ?? ([], false)) }
            return MTPEntry(id: newID, parentID: parentID, storageID: storageID,
                            name: name, size: 0, modified: Date(), isFolder: true)
        }
    }

    /// Deletes a file or folder. Android deletes folders with their contents.
    public func delete(id: UInt32) throws {
        try withHandle { h in
            guard LIBMTP_Delete_Object(h, id) == 0 else {
                throw classify("Delete", takeErrors(h) ?? ([], false))
            }
        }
    }

    /// Moves a file or folder into another folder on the same storage.
    /// (libmtp doesn't update its object cache here, but listings stay right:
    /// a folder's children are always fetched fresh from the phone.)
    public func move(id: UInt32, storageID: UInt32, toFolderID parentID: UInt32) throws {
        try withHandle { h in
            // libmtp wants 0, not 0xFFFFFFFF, for "storage root" here.
            let parent = parentID == MTPRootFolderID ? 0 : parentID
            guard LIBMTP_Move_Object(h, id, storageID, parent) == 0 else {
                throw classify("Move", takeErrors(h) ?? ([], false))
            }
        }
    }

    /// Renames a file or folder in place.
    ///
    /// Uses LIBMTP_Set_File_Name, which also updates libmtp's per-session object
    /// cache. (LIBMTP_Set_Object_String doesn't: listings in the same session
    /// kept showing the old name, so a lookup by the new name failed.)
    public func rename(id: UInt32, to newName: String) throws {
        try withHandle { h in
            guard let f = LIBMTP_Get_Filemetadata(h, id) else {
                throw classify("Rename", takeErrors(h) ?? ([], false))
            }
            defer { LIBMTP_destroy_file_t(f) }
            guard LIBMTP_Set_File_Name(h, f, newName) == 0 else {
                throw classify("Rename", takeErrors(h) ?? ([], false))
            }
        }
    }

    // MARK: - Internals

    /// After a cancel, libmtp waits for the phone's final response with Android's
    /// 60 s timeout, but the phone never sends it (cancelling took ~72 s). The
    /// session is reset right afterwards anyway, so cut the timeout first.
    private func shortenTimeoutForCancel(_ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> () -> Void {
        let vid = raw.vendorID, pid = raw.productID
        return { _ = mtt_set_usb_timeout(h, vid, pid, 300) }
    }

    /// After a transfer stops midway the session is unusable, so start a new one.
    /// Not when the phone was unplugged: there is nothing to reconnect to.
    private func recoverAfterAbortedTransfer(_ error: MTPError) throws {
        if case .deviceGone = error { return }
        if aborting.load(ordering: .relaxed) {
            mtpTrace("transfer aborted because the phone left USB")
            isAlive = false
            throw MTPError.deviceGone
        }
        mtpTrace("transfer aborted: \(error)")
        try reconnect()
    }

    private func withHandle<T>(_ body: (UnsafeMutablePointer<LIBMTP_mtpdevice_t>) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard isAlive, let h = handle else { throw MTPError.deviceGone }
        return try body(h)
    }

    /// Pops libmtp's error stack. Returns nil if it was empty.
    /// The Bool is true when the error came from the USB layer (device unplugged or hung).
    private func takeErrors(_ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> ([String], Bool)? {
        var msgs: [String] = []
        var usb = false
        var e = LIBMTP_Get_Errorstack(h)
        guard e != nil else { return nil }
        while let err = e {
            if let t = err.pointee.error_text { msgs.append(String(cString: t)) }
            if err.pointee.errornumber == LIBMTP_ERROR_USB_LAYER
                || err.pointee.errornumber == LIBMTP_ERROR_NO_DEVICE_ATTACHED { usb = true }
            e = err.pointee.next
        }
        LIBMTP_Clear_Errorstack(h)
        return (msgs, usb)
    }

    private func classify(_ op: String, _ err: ([String], Bool)) -> MTPError {
        if err.1 {
            // USB-level failure: the handle is unusable from here on.
            isAlive = false
            return .deviceGone
        }
        return .operationFailed(op, err.0)
    }

    private func failure(_ op: String, _ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> MTPError {
        classify(op, takeErrors(h) ?? ([], false))
    }

    private static func readInfo(_ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> MTPDeviceInfo {
        func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
            guard let p else { return "" }
            defer { free(p) }
            return String(cString: p)
        }
        var maxLevel: UInt8 = 0, curLevel: UInt8 = 0
        let battery: Int? = LIBMTP_Get_Batterylevel(h, &maxLevel, &curLevel) == 0 && maxLevel > 0
            ? Int(curLevel) * 100 / Int(maxLevel) : nil
        let info = MTPDeviceInfo(
            manufacturer: take(LIBMTP_Get_Manufacturername(h)),
            model: take(LIBMTP_Get_Modelname(h)),
            friendlyName: take(LIBMTP_Get_Friendlyname(h)),
            serial: take(LIBMTP_Get_Serialnumber(h)),
            batteryPercent: battery)
        LIBMTP_Clear_Errorstack(h)  // battery/friendly name are optional and often "fail"
        return info
    }

    private static func entry(from f: LIBMTP_file_t) -> MTPEntry {
        MTPEntry(
            id: f.item_id,
            parentID: f.parent_id,
            storageID: f.storage_id,
            name: f.filename.map { String(cString: $0) } ?? "",
            size: f.filesize,
            modified: f.modificationdate > 0 ? Date(timeIntervalSince1970: TimeInterval(f.modificationdate)) : nil,
            isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER)
    }
}

// MARK: - Progress bridging (C callback -> Swift closure)

private final class ProgressBox {
    let handler: MTPProgress?
    /// Runs inside libmtp just before it starts cancelling.
    let onCancel: () -> Void
    var cancelled = false
    /// Cancelled close to the end: the transfer is allowed to finish (see drainLimit).
    var drained = false
    init(_ handler: MTPProgress?, onCancel: @escaping () -> Void) {
        self.handler = handler
        self.onCancel = onCancel
    }
}

private let progressTrampoline: LIBMTP_progressfunc_t = { sent, total, ctx in
    guard let ctx else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(UnsafeMutableRawPointer(mutating: ctx)).takeUnretainedValue()
    guard let handler = box.handler, !box.drained else { return 0 }
    if handler(sent, total) { return 0 }
    box.cancelled = true
    if total > sent && total - sent <= MTPDevice.drainLimit {
        mtpTrace("cancel requested at \(sent)/\(total): letting the last \(total - sent) bytes finish")
        box.drained = true
        return 0
    }
    mtpTrace("cancel requested at \(sent)/\(total)")
    box.onCancel()
    return 1
}
