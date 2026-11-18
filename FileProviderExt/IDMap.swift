import FileProvider
import Foundation
import SQLite3

/// Stable File Provider identifiers for phone paths.
///
/// MTP object IDs change between sessions and paths change on rename, but the
/// system needs an identifier that stays the same for an item's life. So each
/// path gets a UUID; renames done through Finder move the mapping along.
///
/// Stored in SQLite, not in memory: the system may run more than one extension
/// process for a domain, and an in-memory copy per process went stale (one
/// process saved over the other's new IDs, so Finder's items "vanished").
final class IDMap {
    private var db: OpaquePointer?
    private let lock = NSLock()

    init(domainID: String) {
        // The extension's own sandbox container (Application Support).
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MTTFileProvider", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = domainID.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent("ids-\(safe).sqlite")

        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            NSLog("MTTFileProvider: cannot open \(url.path)")
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 5000)  // wait for the other process instead of failing
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE TABLE IF NOT EXISTS ids (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE)")
    }

    deinit { sqlite3_close(db) }

    private static func key(_ path: [String]) -> String { path.joined(separator: "/") }
    private static func components(_ key: String) -> [String] {
        key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Lookups

    /// Identifier for a path ([] is the root), creating one if needed.
    func identifier(for path: [String]) -> NSFileProviderItemIdentifier {
        identifiers(for: [path])[0]
    }

    /// Batch version (one transaction), for listing big folders.
    func identifiers(for paths: [[String]]) -> [NSFileProviderItemIdentifier] {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN IMMEDIATE")
        defer { exec("COMMIT") }
        return paths.map { path in
            if path.isEmpty { return .rootContainer }
            let k = Self.key(path)
            if let id = queryString("SELECT id FROM ids WHERE path = ?", k) {
                return NSFileProviderItemIdentifier(id)
            }
            let id = UUID().uuidString
            run("INSERT OR IGNORE INTO ids (id, path) VALUES (?, ?)", id, k)
            // If another process inserted the same path meanwhile, use its ID.
            return NSFileProviderItemIdentifier(queryString("SELECT id FROM ids WHERE path = ?", k) ?? id)
        }
    }

    func path(for identifier: NSFileProviderItemIdentifier) -> [String]? {
        if identifier == .rootContainer { return [] }
        if identifier == .workingSet || identifier == .trashContainer { return nil }
        lock.lock(); defer { lock.unlock() }
        return queryString("SELECT path FROM ids WHERE id = ?", identifier.rawValue).map(Self.components)
    }

    // MARK: - Changes

    /// After a rename or move: re-points `old` and everything under it to `new`.
    func move(from old: [String], to new: [String]) {
        lock.lock(); defer { lock.unlock() }
        let o = Self.key(old), n = Self.key(new)
        exec("BEGIN IMMEDIATE")
        // Whatever was recorded at the destination is stale now.
        run("DELETE FROM ids WHERE path = ? OR substr(path, 1, ?) = ?", n, Self.sqlLength(n) + 1, n + "/")
        run("UPDATE ids SET path = ? || substr(path, ?) WHERE path = ? OR substr(path, 1, ?) = ?",
            n, Self.sqlLength(o) + 1, o, Self.sqlLength(o) + 1, o + "/")
        exec("COMMIT")
    }

    /// Forgets `path` and everything under it.
    func remove(_ path: [String]) {
        lock.lock(); defer { lock.unlock() }
        let k = Self.key(path)
        run("DELETE FROM ids WHERE path = ? OR substr(path, 1, ?) = ?", k, Self.sqlLength(k) + 1, k + "/")
    }

    /// Length as SQLite's substr() counts it: Unicode code points, not Swift
    /// characters. They differ for decomposed text ("ư" written as "u" + hook),
    /// which broke renaming folders with Vietnamese names.
    private static func sqlLength(_ s: String) -> Int64 { Int64(s.unicodeScalars.count) }

    // MARK: - SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("MTTFileProvider: SQL failed (\(sql)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("MTTFileProvider: SQL prepare failed (\(sql)): \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: Any...) {
        guard let stmt = prepare(sql, args) else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) != SQLITE_DONE, let db {
            NSLog("MTTFileProvider: SQL step failed (\(sql)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func queryString(_ sql: String, _ args: Any...) -> String? {
        guard let stmt = prepare(sql, args) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }
}
