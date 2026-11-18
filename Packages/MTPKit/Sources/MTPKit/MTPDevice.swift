import CLibMTP
import CMTPShim
import Foundation

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

    private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?
    private let lock = NSRecursiveLock()

    public init(raw: RawDeviceInfo) throws {
        MTP.initialize()
        self.raw = raw
        let (h, resetOff) = try MTPDevice.open(raw)
        handle = h
        resetOnCloseDisabled = resetOff
        info = MTPDevice.readInfo(h)
    }

    deinit { close() }

    /// Releases the USB connection. Safe to call more than once.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let h = handle { LIBMTP_Release_Device(h) }
        handle = nil
        isAlive = false
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
            _ = mtt_set_usb_timeout(h, raw.vendorID, raw.productID, 1000)
            _ = mtt_update_device_flags(h, raw.vendorID, raw.productID,
                                        UInt32(MTT_FLAG_FORCE_RESET_ON_CLOSE | MTT_FLAG_NO_RELEASE_INTERFACE), 0)
            mtpTrace("reconnect: releasing")
            LIBMTP_Release_Device(h)
            mtpTrace("reconnect: released")
        }
        handle = nil
        isAlive = false

        let deadline = Date().addingTimeInterval(timeout)
        func sameModel(_ d: RawDeviceInfo) -> Bool {
            d.vendorID == raw.vendorID && d.productID == raw.productID
        }

        // 1. Give the reset a moment to take the old attachment off the bus, so we
        //    don't reopen it just before it drops. On macOS the reset usually does
        //    not re-enumerate (same address), so don't wait long.
        let goneBy = Date().addingTimeInterval(0.3)
        while Date() < goneBy {
            let present = ((try? MTP.detectRawDevices()) ?? []).contains { $0.usbKey == oldKey }
            if !present { break }
            Thread.sleep(forTimeInterval: 0.2)
        }

        mtpTrace("reconnect: old device gone (or gave up waiting)")
        // 2. Wait for it to come back and open it.
        var lastError: Error = MTPError.deviceGone
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            guard let candidate = ((try? MTP.detectRawDevices()) ?? []).first(where: sameModel) else {
                mtpTrace("reconnect: not on bus yet")
                continue
            }
            do {
                mtpTrace("reconnect: opening \(candidate.usbKey)")
                let (h, resetOff) = try MTPDevice.open(candidate)
                let newInfo = MTPDevice.readInfo(h)
                if !oldSerial.isEmpty, newInfo.serial != oldSerial {
                    mtpTrace("reconnect: serial mismatch '\(newInfo.serial)'")
                    LIBMTP_Release_Device(h)  // a different phone of the same model
                    continue
                }
                guard LIBMTP_Get_Storage(h, Int32(LIBMTP_STORAGE_SORTBY_NOTSORTED)) == 0 else {
                    mtpTrace("reconnect: storages failed")
                    LIBMTP_Clear_Errorstack(h)
                    LIBMTP_Release_Device(h)
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
        var attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o644]  // libmtp creates files 0750
        if let modified = entry.modified { attrs[.modificationDate] = modified }
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: localPath)
    }

    /// Copies a file from the device to `localPath`. A partial file is removed on failure.
    public func download(id: UInt32, to localPath: String, progress: MTPProgress? = nil) throws {
        try withHandle { h in
            let box = ProgressBox(progress, onCancel: shortenTimeoutForCancel(h))
            let rc = withExtendedLifetime(box) {
                LIBMTP_Get_File_To_File(h, id, localPath, progressTrampoline,
                                        UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
            }
            if rc != 0 {
                mtpTrace("libmtp transfer returned \(rc)")
                let err = takeErrors(h) ?? ([], false)
                try? FileManager.default.removeItem(atPath: localPath)
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
        let attrs = try FileManager.default.attributesOfItem(atPath: localPath)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let fileName = name ?? (localPath as NSString).lastPathComponent

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
                LIBMTP_Send_File_From_File(h, localPath, f, progressTrampoline,
                                           UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
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

    /// Renames a file or folder in place.
    public func rename(id: UInt32, to newName: String) throws {
        try withHandle { h in
            guard LIBMTP_Set_Object_String(h, id, LIBMTP_PROPERTY_ObjectFileName, newName) == 0 else {
                throw classify("Rename", takeErrors(h) ?? ([], false))
            }
        }
    }

    // MARK: - Internals

    /// After a cancel, libmtp waits for the phone's final response with Android's
    /// 60 s timeout, but the phone never sends it (cancelling took ~72 s). The
    /// session is reset right afterwards anyway, so cut the timeout to 1 s first.
    private func shortenTimeoutForCancel(_ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> () -> Void {
        let vid = raw.vendorID, pid = raw.productID
        return { _ = mtt_set_usb_timeout(h, vid, pid, 1000) }
    }

    /// After a transfer stops midway the session is unusable, so start a new one.
    /// Not when the phone was unplugged: there is nothing to reconnect to.
    private func recoverAfterAbortedTransfer(_ error: MTPError) throws {
        if case .deviceGone = error { return }
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
    init(_ handler: MTPProgress?, onCancel: @escaping () -> Void) {
        self.handler = handler
        self.onCancel = onCancel
    }
}

private let progressTrampoline: LIBMTP_progressfunc_t = { sent, total, ctx in
    guard let ctx else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(UnsafeMutableRawPointer(mutating: ctx)).takeUnretainedValue()
    guard let handler = box.handler else { return 0 }
    if handler(sent, total) { return 0 }
    box.cancelled = true
    mtpTrace("cancel requested at \(sent)/\(total)")
    box.onCancel()
    return 1
}
