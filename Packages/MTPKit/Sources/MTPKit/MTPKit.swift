import CLibMTP
import Foundation

/// A raw MTP device seen on the USB bus (not yet opened).
public struct RawDeviceInfo: @unchecked Sendable, Hashable {
    public let vendor: String
    public let product: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let busLocation: UInt32
    public let devNum: UInt8

    /// Kept so the device can be opened later. Its string pointers point into
    /// libmtp's static device table, so copying the struct is safe.
    let raw: LIBMTP_raw_device_t

    /// Identifies a physical USB attachment (changes when re-plugged).
    public var usbKey: String {
        String(format: "%04x:%04x@%u.%u", vendorID, productID, busLocation, devNum)
    }

    public static func == (a: Self, b: Self) -> Bool { a.usbKey == b.usbKey }
    public func hash(into h: inout Hasher) { h.combine(usbKey) }
}

public enum MTPError: Error, CustomStringConvertible {
    case noDevice
    case connectionFailed
    case deviceGone
    case notFound(String)
    case notAFolder(String)
    case alreadyExists(String)
    case cancelled
    case operationFailed(String, [String])

    public var description: String {
        switch self {
        case .noDevice:
            return "No MTP device found. Unlock the phone and choose \"File transfer\"."
        case .connectionFailed:
            return "Found the device but could not open it. Is another app (OpenMTP, Android File Transfer, Android Studio) using it?"
        case .deviceGone:
            return "The device was disconnected."
        case .notFound(let p): return "Not found: \(p)"
        case .notAFolder(let p): return "Not a folder: \(p)"
        case .alreadyExists(let p): return "Already exists: \(p)"
        case .cancelled: return "Cancelled."
        case .operationFailed(let op, let msgs):
            return msgs.isEmpty ? "\(op) failed." : "\(op) failed: " + msgs.joined(separator: "; ")
        }
    }
}

public enum MTP {
    private static let initOnce: Void = { LIBMTP_Init() }()

    /// Runs libmtp's global init. Safe to call more than once.
    public static func initialize() { _ = initOnce }

    /// Turns on libmtp's verbose logging to stderr (0 = off).
    public static func setDebug(_ level: Int32) {
        initialize()
        LIBMTP_Set_Debug(level)
    }

    /// Lists MTP devices on USB without opening them.
    public static func detectRawDevices() throws -> [RawDeviceInfo] {
        initialize()
        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let err = LIBMTP_Detect_Raw_Devices(&raw, &count)
        defer { free(raw) }

        switch err {
        case LIBMTP_ERROR_NONE: break
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED: return []
        case LIBMTP_ERROR_CONNECTING: throw MTPError.connectionFailed
        default: throw MTPError.operationFailed("Detecting devices", ["libmtp error \(err.rawValue)"])
        }

        guard let raw else { return [] }
        return (0..<Int(count)).map { i in
            let d = raw[i]
            return RawDeviceInfo(
                vendor: d.device_entry.vendor.map { String(cString: $0) } ?? "Unknown",
                product: d.device_entry.product.map { String(cString: $0) } ?? "Unknown",
                vendorID: d.device_entry.vendor_id,
                productID: d.device_entry.product_id,
                busLocation: d.bus_location,
                devNum: d.devnum,
                raw: d
            )
        }
    }

    /// Opens the first MTP device found, retrying for up to `wait` seconds.
    ///
    /// Retrying matters because the phone drops off USB for about a second after
    /// any previous session closes (libmtp resets the port). A device only counts
    /// as open once its storages can be read.
    public static func openFirstDevice(wait: TimeInterval = 6) throws -> MTPDevice {
        let deadline = Date().addingTimeInterval(wait)
        var lastError: Error = MTPError.noDevice
        repeat {
            do {
                guard let first = try detectRawDevices().first else { throw MTPError.noDevice }
                let dev = try MTPDevice(raw: first)
                do {
                    _ = try dev.storages()
                    return dev
                } catch {
                    dev.close()
                    throw error
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        throw lastError
    }
}
