import Foundation
import MTPKit
import Synchronization

// MARK: - Output: libmtp prints noise to both stdout and stderr, so (unless -v)
// point fds 1 and 2 at /dev/null and write our own output to saved copies.

let verbose = CommandLine.arguments.contains("-v")

/// Duplicates `fd` for our own use and, unless verbose, silences the original.
func takeOver(_ fd: Int32) -> FileHandle {
    let copy = dup(fd)
    if !verbose {
        let devNull = open("/dev/null", O_WRONLY)
        dup2(devNull, fd)
        close(devNull)
    }
    return FileHandle(fileDescriptor: copy, closeOnDealloc: false)
}

let realStdout = takeOver(STDOUT_FILENO)
let realStderr = takeOver(STDERR_FILENO)

/// Shadows Swift.print so all CLI output goes to the real stdout.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let text = items.map { "\($0)" }.joined(separator: separator) + terminator
    realStdout.write(text.data(using: .utf8)!)
}

func eprint(_ msg: String) {
    realStderr.write((msg + "\n").data(using: .utf8)!)
}

// MARK: - Ctrl-C cancels the current transfer; a second Ctrl-C quits.

enum Interrupt {
    static let requested = Atomic<Bool>(false)
}

/// Nonisolated on purpose: the handler runs on a background queue, and a closure
/// written at top level would be inferred @MainActor and trap at runtime.
nonisolated func installInterruptHandler(stderrFD: Int32) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { @Sendable in
        if Interrupt.requested.exchange(true, ordering: .relaxed) { exit(130) }
        let msg = "\nCancelling… (press Ctrl-C again to quit)\n"
        _ = msg.withCString { write(stderrFD, $0, strlen($0)) }
    }
    source.resume()
    return source
}
let sigSource = installInterruptHandler(stderrFD: realStderr.fileDescriptor)

// MARK: - Helpers

func fail(_ msg: String) -> Never {
    eprint("Error: \(msg)")
    exit(1)
}

func human(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

/// Prints a one-line progress bar; returns false if the user pressed Ctrl-C.
func progressPrinter(label: String) -> MTPProgress {
    let start = Date()
    var lastPrint = Date.distantPast
    return { done, total in
        let now = Date()
        if now.timeIntervalSince(lastPrint) > 0.2 || done == total {
            lastPrint = now
            let pct = total > 0 ? Double(done) / Double(total) * 100 : 100
            let secs = max(now.timeIntervalSince(start), 0.001)
            let speed = human(UInt64(Double(done) / secs))
            print(String(format: "\r  %@  %5.1f%%  %@ / %@  %@/s   ", label, pct, human(done), human(total), speed),
                  terminator: "")
        }
        return !Interrupt.requested.load(ordering: .relaxed)
    }
}

func run(_ body: () throws -> Void) {
    do { try body() } catch { fail("\(error)") }
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
let storageIndex: Int = {
    guard let i = args.firstIndex(of: "-s"), i + 1 < args.count, let n = Int(args[i + 1]) else { return 0 }
    args.removeSubrange(i...(i + 1))
    return n
}()
if let i = args.firstIndex(of: "-v") {
    MTP.setDebug(2)
    args.remove(at: i)
}
_ = (realStdout, realStderr)  // apply the redirects before any libmtp call
let command = args.first ?? "help"
let params = Array(args.dropFirst())

func openDevice() -> (MTPDevice, MTPStorage) {
    do {
        let dev = try MTP.openFirstDevice()
        let storages = try dev.storages()
        guard storageIndex < storages.count else {
            fail("Storage \(storageIndex) does not exist (device has \(storages.count)).")
        }
        return (dev, storages[storageIndex])
    } catch {
        fail("\(error)")
    }
}

func parentAndName(_ path: String) -> (String, String) {
    var comps = mtpPathComponents(path)
    guard let name = comps.popLast() else { fail("Path must name a file or folder: \(path)") }
    return ("/" + comps.joined(separator: "/"), name)
}

// MARK: - Commands

func cmdDetect() {
    run {
        let devices = try MTP.detectRawDevices()
        if devices.isEmpty { print(MTPError.noDevice.description) }
        for (i, d) in devices.enumerated() {
            print("[\(i)] \(d.vendor) \(d.product)  \(d.usbKey)")
        }
    }
}

func cmdInfo() {
    let (dev, _) = openDevice()
    run {
        let info = dev.info
        print("Device:   \(info.displayName)")
        print("Model:    \(info.manufacturer) \(info.model)")
        print("Serial:   \(info.serial)")
        if let b = info.batteryPercent { print("Battery:  \(b)%") }
        if !dev.resetOnCloseDisabled { print("Warning:  USB reset on close is still on (libmtp layout mismatch)") }
        print("Storages:")
        for (i, s) in try dev.storages().enumerated() {
            let ro = s.isReadOnly ? " (read-only)" : ""
            print("  [\(i)] \(s.description): \(human(s.freeBytes)) free of \(human(s.capacity))\(ro)")
        }
    }
}

func cmdLs() {
    let (dev, storage) = openDevice()
    let path = params.first ?? "/"
    run {
        let target = try dev.resolve(path: path, storageID: storage.id)
        let entries = target.isFolder ? try dev.list(storageID: storage.id, folderID: target.id) : [target]
        let sorted = entries.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for e in sorted {
            let size = e.isFolder ? "-" : human(e.size)
            let date = e.modified.map(dateFmt.string(from:)) ?? ""
            let name = e.isFolder ? e.name + "/" : e.name
            print("\(e.isFolder ? "d" : "-")  \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(date.padding(toLength: 16, withPad: " ", startingAt: 0))  \(name)")
        }
        print("\(entries.count) item(s)")
    }
}

func pullRecursive(_ dev: MTPDevice, _ entry: MTPEntry, to localPath: String) throws {
    if Interrupt.requested.load(ordering: .relaxed) { throw MTPError.cancelled }
    if entry.isFolder {
        try FileManager.default.createDirectory(atPath: localPath, withIntermediateDirectories: true)
        for child in try dev.list(storageID: entry.storageID, folderID: entry.id) {
            try pullRecursive(dev, child, to: (localPath as NSString).appendingPathComponent(child.name))
        }
    } else {
        try dev.download(entry, to: localPath, progress: progressPrinter(label: entry.name))
        print()
    }
}

func cmdPull() {
    guard let remote = params.first else { fail("Usage: mtt pull <remote-path> [local-path]") }
    let (dev, storage) = openDevice()
    run {
        let entry = try dev.resolve(path: remote, storageID: storage.id)
        guard !entry.isRoot else { fail("Pick a folder or file, not the whole storage.") }
        var local = params.count > 1 ? params[1] : FileManager.default.currentDirectoryPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: local, isDirectory: &isDir), isDir.boolValue {
            local = (local as NSString).appendingPathComponent(entry.name)
        }
        if FileManager.default.fileExists(atPath: local) { throw MTPError.alreadyExists(local) }
        try pullRecursive(dev, entry, to: local)
        print("Saved to \(local)")
    }
}

func pushRecursive(_ dev: MTPDevice, localPath: String, storageID: UInt32, parentID: UInt32) throws {
    if Interrupt.requested.load(ordering: .relaxed) { throw MTPError.cancelled }
    let name = (localPath as NSString).lastPathComponent
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) else {
        throw MTPError.notFound(localPath)
    }
    if isDir.boolValue {
        let folder = try dev.createFolder(name: name, storageID: storageID, parentID: parentID)
        let children = try FileManager.default.contentsOfDirectory(atPath: localPath).filter { !$0.hasPrefix(".") }
        for child in children.sorted() {
            try pushRecursive(dev, localPath: (localPath as NSString).appendingPathComponent(child),
                              storageID: storageID, parentID: folder.id)
        }
    } else {
        try dev.upload(localPath: localPath, storageID: storageID, parentID: parentID,
                       progress: progressPrinter(label: name))
        print()
    }
}

func cmdPush() {
    guard params.count == 2 else { fail("Usage: mtt push <local-path> <remote-folder>") }
    let (dev, storage) = openDevice()
    run {
        let folder = try dev.resolve(path: params[1], storageID: storage.id)
        guard folder.isFolder else { throw MTPError.notAFolder(params[1]) }
        let name = (params[0] as NSString).lastPathComponent
        let existing = try dev.list(storageID: storage.id, folderID: folder.id)
        if existing.contains(where: { $0.name == name }) {
            throw MTPError.alreadyExists(params[1] + "/" + name)
        }
        try pushRecursive(dev, localPath: params[0], storageID: storage.id, parentID: folder.id)
        print("Copied to \(params[1])")
    }
}

func cmdMkdir() {
    guard let path = params.first else { fail("Usage: mtt mkdir <remote-path>") }
    let (dev, storage) = openDevice()
    run {
        let (parentPath, name) = parentAndName(path)
        let parent = try dev.resolve(path: parentPath, storageID: storage.id)
        guard parent.isFolder else { throw MTPError.notAFolder(parentPath) }
        if try dev.list(storageID: storage.id, folderID: parent.id).contains(where: { $0.name == name }) {
            throw MTPError.alreadyExists(path)
        }
        try dev.createFolder(name: name, storageID: storage.id, parentID: parent.id)
        print("Created \(path)")
    }
}

func cmdRm() {
    guard let path = params.first else { fail("Usage: mtt rm <remote-path>") }
    let (dev, storage) = openDevice()
    run {
        let entry = try dev.resolve(path: path, storageID: storage.id)
        guard !entry.isRoot else { fail("Refusing to delete the storage root.") }
        try dev.delete(id: entry.id)
        print("Deleted \(path)")
    }
}

func cmdRename() {
    guard params.count == 2 else { fail("Usage: mtt rename <remote-path> <new-name>") }
    let (dev, storage) = openDevice()
    run {
        let entry = try dev.resolve(path: params[0], storageID: storage.id)
        guard !entry.isRoot else { fail("Cannot rename the storage root.") }
        try dev.rename(id: entry.id, to: params[1])
        print("Renamed to \(params[1])")
    }
}

func cmdWatch() {
    var known = Set((try? MTP.detectRawDevices()) ?? [])
    for d in known { print("Connected:    \(d.vendor) \(d.product)  \(d.usbKey)") }
    print("Watching for MTP devices. Press Ctrl-C to stop.")
    let watcher = USBWatcher {
        let now = Set((try? MTP.detectRawDevices()) ?? [])
        for d in now.subtracting(known) { print("Connected:    \(d.vendor) \(d.product)  \(d.usbKey)") }
        for d in known.subtracting(now) { print("Disconnected: \(d.vendor) \(d.product)  \(d.usbKey)") }
        known = now
    }
    watcher.start()
    // Ctrl-C sets the flag; poll it so watch mode exits on the first press.
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
        if Interrupt.requested.load(ordering: .relaxed) { exit(0) }
    }
    withExtendedLifetime(watcher) { RunLoop.main.run() }
}

func cmdReset() {
    let (dev, _) = openDevice()
    run {
        let t = Date()
        try dev.reconnect()
        print(String(format: "Reconnected in %.1fs", Date().timeIntervalSince(t)))
    }
}

/// Dev check: cancel a download partway, then list the root in the SAME session
/// several times and report whether the listings stay complete.
func cmdCancelTest() {
    guard let remote = params.first else { fail("Usage: mtt _cancel-test <remote-file>") }
    let (dev, storage) = openDevice()
    run {
        let before = try dev.list(storageID: storage.id, folderID: MTPRootFolderID).count
        let entry = try dev.resolve(path: remote, storageID: storage.id)
        let tmp = NSTemporaryDirectory() + "mtt-cancel-test-\(getpid())"
        let t0 = Date()
        var cancelAt: Date?
        do {
            try dev.download(entry, to: tmp) { done, total in
                if Double(done) < Double(total) * (Double(ProcessInfo.processInfo.environment["MTT_CANCEL_AT"] ?? "") ?? 0.25) { return true }
                if cancelAt == nil { cancelAt = Date() }
                return false
            }
            print("Download was not cancelled (file too small?)")
        } catch MTPError.cancelled {
            let c = cancelAt.map { $0.timeIntervalSince(t0) } ?? 0
            print(String(format: "Cancelled at %.1fs; recovered %.1fs later. Partial file removed: %@",
                         c, Date().timeIntervalSince(t0) - c,
                         FileManager.default.fileExists(atPath: tmp) ? "no" : "yes"))
        }
        for i in 1...5 {
            do {
                let n = try dev.list(storageID: storage.id, folderID: MTPRootFolderID).count
                print("  list #\(i): \(n) items (expected \(before))")
            } catch {
                print("  list #\(i): error: \(error)")
            }
        }
    }
}

func cmdHelp() {
    print("""
    mtt — browse an Android phone over MTP

    Usage: mtt [-s <storage-index>] [-v] <command> [args]

      detect                          List MTP devices on USB
      info                            Device name, battery, storages
      ls [path]                       List a folder (default /)
      pull <remote> [local]           Copy a file or folder to the Mac
      push <local> <remote-folder>    Copy a file or folder to the phone
      mkdir <remote-path>             Create a folder
      rm <remote-path>                Delete a file or folder (folders recursively)
      rename <remote-path> <name>     Rename a file or folder
      watch                           Print when phones are plugged in or out
      reset                           Reset the USB connection (if the phone seems stuck)

      -s N   use storage N (see `mtt info`), default 0
      -v     verbose libmtp logging
    """)
}

switch command {
case "detect": cmdDetect()
case "info": cmdInfo()
case "ls": cmdLs()
case "pull": cmdPull()
case "push": cmdPush()
case "mkdir": cmdMkdir()
case "rm": cmdRm()
case "rename", "mv": cmdRename()
case "watch": cmdWatch()
case "reset": cmdReset()
case "_cancel-test": cmdCancelTest()
default: cmdHelp()
}
