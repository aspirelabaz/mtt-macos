import Darwin
import Foundation
import IOKit
import IOKit.usb

/// macOS's ptpcamerad (used by Photos / Image Capture) often grabs a phone's
/// MTP interface the moment it's plugged in (Samsung phones declare it as a
/// "still image" interface). libmtp then can't claim it and opening fails.
/// Stopping ptpcamerad frees the interface; macOS restarts it on demand later.
enum PTPCameraDaemon {
    private static let name = "ptpcamerad"
    private static let autoReleaseKey = "MTTAutoReleaseFromPTPCamera"

    /// User preference: stop ptpcamerad automatically when it holds a phone.
    static var autoRelease: Bool {
        get { UserDefaults.standard.bool(forKey: autoReleaseKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoReleaseKey) }
    }

    /// True if ptpcamerad has a USB still-image (MTP/PTP) interface open.
    static func holdsMTPInterface() -> Bool {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iter) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iter) }
        while case let intf = IOIteratorNext(iter), intf != 0 {
            defer { IOObjectRelease(intf) }
            let cls = IORegistryEntryCreateCFProperty(intf, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            guard cls == 6 else { continue }  // 6 = still image (what MTP uses)
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(intf, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                // A user client's registry name is the name of the process that opened it.
                var buf = [CChar](repeating: 0, count: 128)
                if IORegistryEntryGetName(child, &buf) == KERN_SUCCESS, cString(buf) == name {
                    return true
                }
            }
        }
        return false
    }

    /// Stops every running ptpcamerad and waits (up to ~2.5 s) for the phone's
    /// interface to be let go. ptpcamerad ignores SIGTERM, so it gets SIGKILL
    /// if still alive after half a second. Returns true if the interface is free.
    @discardableResult
    static func stop() -> Bool {
        let targets = pids()
        for pid in targets {
            let rc = kill(pid, SIGTERM)
            NSLog("MTT: SIGTERM ptpcamerad pid \(pid) -> \(rc == 0 ? "ok" : String(cString: strerror(errno)))")
        }
        usleep(500_000)
        for pid in targets where kill(pid, 0) == 0 {
            let rc = kill(pid, SIGKILL)
            NSLog("MTT: SIGKILL ptpcamerad pid \(pid) -> \(rc == 0 ? "ok" : String(cString: strerror(errno)))")
        }
        for _ in 0..<20 {
            if !holdsMTPInterface() { return true }
            usleep(100_000)
        }
        NSLog("MTT: ptpcamerad still holds the MTP interface")
        return false
    }

    private static func pids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(n) * 2)
        let got = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        return all.prefix(Int(got)).filter { pid in
            guard pid > 0 else { return false }
            var buf = [CChar](repeating: 0, count: 256)
            return proc_name(pid, &buf, UInt32(buf.count)) > 0 && cString(buf) == name
        }
    }

    private static func cString(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
