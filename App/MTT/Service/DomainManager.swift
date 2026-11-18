import FileProvider
import Foundation
import MTTShared
import Observation

/// Keeps one Finder sidebar entry (File Provider domain) per storage of each
/// connected phone: added when the phone is ready, removed when it's unplugged.
@MainActor
final class DomainManager {
    static let shared = DomainManager()

    private var domains: [String: NSFileProviderDomain] = [:]  // by identifier
    private var started = false
    private var lastChangeTotal = 0

    func start() {
        guard !started else { return }
        started = true
        Task {
            // Bump when item identifiers change meaning: old domains are then wiped,
            // since Finder's cached identifiers would no longer match.
            let schema = 5
            if UserDefaults.standard.integer(forKey: "MTTDomainSchema") != schema {
                try? await NSFileProviderManager.removeAllDomains()
                UserDefaults.standard.set(schema, forKey: "MTTDomainSchema")
            }
            // Domains left over from a previous run: keep them for now (a phone that's
            // still plugged in will claim its domain again), drop the rest after a grace period.
            let existing = (try? await NSFileProviderManager.domains()) ?? []
            for d in existing { domains[d.identifier.rawValue] = d }
            track()
            try? await Task.sleep(for: .seconds(10))
            sync(removeStale: true)
        }
        // Pick up changes made on the phone itself now and then.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { DomainManager.shared.signalAll() }
        }
    }

    /// Re-runs `sync` whenever the device list, their states or contents change.
    private func track() {
        withObservationTracking {
            for d in DeviceManager.shared.devices {
                _ = d.state
                _ = d.storages
                _ = d.name
                _ = d.changeCounter
            }
        } onChange: {
            Task { @MainActor in
                DomainManager.shared.sync(removeStale: false)
                DomainManager.shared.track()
            }
        }
        sync(removeStale: false)
    }

    private struct Wanted {
        let id: String
        let name: String
    }

    private func wantedDomains() -> [Wanted] {
        var out: [Wanted] = []
        for d in DeviceManager.shared.devices where d.isReady {
            guard let serial = d.info?.serial, !serial.isEmpty else { continue }
            for s in d.storages {
                let name = d.storages.count > 1 ? "\(d.name) – \(s.description)" : d.name
                out.append(Wanted(id: MTTDomainID.make(serial: serial, storageID: s.id), name: name))
            }
        }
        return out
    }

    /// Adds domains for ready phones; removes domains of phones that left
    /// (`removeStale` also drops leftovers from a previous run).
    func sync(removeStale: Bool) {
        let wanted = wantedDomains()
        let wantedIDs = Set(wanted.map(\.id))

        for w in wanted {
            if let existing = domains[w.id], existing.displayName == w.name { continue }
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(w.id), displayName: w.name)
            domains[w.id] = domain
            NSFileProviderManager.add(domain) { error in
                if let error { NSLog("MTT: adding domain \(w.id) failed: \(error)") }
            }
        }

        // A phone counts as gone when no device with its serial is around at all
        // (not just "still connecting").
        let presentSerials = Set(DeviceManager.shared.devices.compactMap { $0.info?.serial })
        let anyConnecting = DeviceManager.shared.devices.contains { $0.state == .connecting }
        for (id, domain) in domains where !wantedIDs.contains(id) {
            guard let parsed = MTTDomainID.parse(id) else { continue }
            let gone = !presentSerials.contains(parsed.serial) && !anyConnecting
            guard gone && (removeStale || isKnownThisRun(id)) else { continue }
            domains[id] = nil
            seenThisRun.remove(id)
            NSFileProviderManager.remove(domain) { error in
                if let error { NSLog("MTT: removing domain \(id) failed: \(error)") }
            }
        }
        for w in wanted { seenThisRun.insert(w.id) }

        // Something changed through the app UI: tell Finder to look again.
        let total = DeviceManager.shared.devices.reduce(0) { $0 + $1.changeCounter }
        if total != lastChangeTotal {
            lastChangeTotal = total
            signalAll()
        }
    }

    /// Domains that belonged to a phone seen during this run (safe to remove at once).
    private var seenThisRun = Set<String>()
    private func isKnownThisRun(_ id: String) -> Bool { seenThisRun.contains(id) }

    /// Asks every domain to re-check for changes.
    func signalAll() {
        for domain in domains.values {
            NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
        }
    }
}
