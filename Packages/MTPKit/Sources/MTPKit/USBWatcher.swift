import Foundation
import IOKit
import IOKit.usb

/// Calls `onChange` (on the main run loop) whenever any USB device is attached
/// or removed. IOKit can't tell us cheaply whether a device speaks MTP, so the
/// caller re-runs `MTP.detectRawDevices()` and diffs. Changes are debounced
/// because Android re-enumerates on USB several times when switching modes.
public final class USBWatcher {
    private let onChange: () -> Void
    private let debounce: TimeInterval
    private var port: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var pending: DispatchWorkItem?

    public init(debounce: TimeInterval = 1.0, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        let source = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let me = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
            USBWatcher.drain(iterator)
            me.scheduleChange()
        }

        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification,
                                         IOServiceMatching("IOUSBHostDevice"), callback, ctx, &addedIter)
        USBWatcher.drain(addedIter)  // must drain once to arm the notification
        IOServiceAddMatchingNotification(p, kIOTerminatedNotification,
                                         IOServiceMatching("IOUSBHostDevice"), callback, ctx, &removedIter)
        USBWatcher.drain(removedIter)
    }

    public func stop() {
        pending?.cancel()
        if addedIter != 0 { IOObjectRelease(addedIter); addedIter = 0 }
        if removedIter != 0 { IOObjectRelease(removedIter); removedIter = 0 }
        if let p = port { IONotificationPortDestroy(p); port = nil }
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }
    }
}
