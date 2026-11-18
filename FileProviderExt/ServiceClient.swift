import FileProvider
import Foundation
import MTTShared

/// Talks to the MTT app over its Mach service. launchd starts the app if it
/// isn't running.
final class ServiceClient {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    deinit { connection?.invalidate() }

    private func currentConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: MTTShared.machServiceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: MTTServiceXPC.self)
        c.invalidationHandler = { [weak self] in self?.dropConnection() }
        c.interruptionHandler = { [weak self] in self?.dropConnection() }
        c.resume()
        connection = c
        return c
    }

    private func dropConnection() {
        lock.lock(); defer { lock.unlock() }
        connection = nil
    }

    /// Calls the service; `body` gets the proxy and a completion to call once.
    private func call<T>(_ body: @escaping (MTTServiceXPC, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
                once.finish(.failure(error))
            }
            guard let service = proxy as? MTTServiceXPC else {
                once.finish(.failure(NSFileProviderError(.serverUnreachable)))
                return
            }
            body(service) { once.finish($0) }
        }
    }

    // MARK: - Calls

    func storages(serial: String) async throws -> [StorageDTO] {
        try await call { s, done in
            s.storages(serial: serial) { data, error in done(Self.decode([StorageDTO].self, data, error)) }
        }
    }

    func list(serial: String, storageID: UInt32, path: [String]) async throws -> [EntryDTO] {
        try await call { s, done in
            s.list(serial: serial, storageID: storageID, path: path) { data, error in
                done(Self.decode([EntryDTO].self, data, error))
            }
        }
    }

    func entry(serial: String, storageID: UInt32, path: [String]) async throws -> EntryDTO {
        try await call { s, done in
            s.entry(serial: serial, storageID: storageID, path: path) { data, error in
                done(Self.decode(EntryDTO.self, data, error))
            }
        }
    }

    func download(serial: String, storageID: UInt32, path: [String], into file: FileHandle) async throws {
        try await call { (s, done: @escaping (Result<Void, Error>) -> Void) in
            s.download(serial: serial, storageID: storageID, path: path, file: file) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func upload(serial: String, storageID: UInt32, parentPath: [String], name: String,
                from file: FileHandle, replaceExisting: Bool) async throws -> EntryDTO {
        try await call { s, done in
            s.upload(serial: serial, storageID: storageID, parentPath: parentPath, name: name,
                     file: file, replaceExisting: replaceExisting) { data, error in
                done(Self.decode(EntryDTO.self, data, error))
            }
        }
    }

    func createFolder(serial: String, storageID: UInt32, parentPath: [String], name: String) async throws -> EntryDTO {
        try await call { s, done in
            s.createFolder(serial: serial, storageID: storageID, parentPath: parentPath, name: name) { data, error in
                done(Self.decode(EntryDTO.self, data, error))
            }
        }
    }

    func rename(serial: String, storageID: UInt32, path: [String], newName: String) async throws {
        try await call { (s, done: @escaping (Result<Void, Error>) -> Void) in
            s.rename(serial: serial, storageID: storageID, path: path, newName: newName) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func delete(serial: String, storageID: UInt32, path: [String]) async throws {
        try await call { (s, done: @escaping (Result<Void, Error>) -> Void) in
            s.delete(serial: serial, storageID: storageID, path: path) { error in
                done(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?, _ error: NSError?) -> Result<T, Error> {
        if let error { return .failure(error) }
        guard let data else { return .failure(MTTServiceError.other.error("Empty reply")) }
        return Result { try DTOCoding.decode(type, from: data) }
    }
}

/// Resumes a continuation at most once (XPC may call both the reply and the error handler).
private final class Once<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ c: CheckedContinuation<T, Error>) { continuation = c }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// Maps service/XPC errors to errors Finder understands.
func fileProviderError(_ error: Error) -> Error {
    let ns = error as NSError
    if ns.domain == MTTServiceError.domain {
        switch MTTServiceError(rawValue: ns.code) {
        case .notFound: return NSFileProviderError(.noSuchItem)
        case .deviceGone: return NSFileProviderError(.serverUnreachable)
        case .alreadyExists: return NSFileProviderError(.filenameCollision)
        case .readOnly: return CocoaError(.fileWriteNoPermission)
        default: return cocoaError(ns.localizedDescription)
        }
    }
    // NSXPCConnectionInterrupted / Invalid: the app isn't there.
    if ns.domain == NSCocoaErrorDomain && (ns.code == 4097 || ns.code == 4099) {
        return NSFileProviderError(.serverUnreachable)
    }
    // File Provider only accepts Cocoa and NSFileProvider error domains.
    if ns.domain == NSCocoaErrorDomain || ns.domain == NSFileProviderErrorDomain { return ns }
    return cocoaError(ns.localizedDescription)
}

private func cocoaError(_ message: String) -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message])
}
