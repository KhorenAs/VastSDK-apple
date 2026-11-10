//
//  VASTBeaconQueue.swift
//  VASTSDK
//

import Foundation
import os

/// Beacons that did not land, kept until they do.
///
/// A tracking request is the only record that an ad was shown, and the SDK used
/// to lose one the moment it failed. Worse, it lost them in the case that happens
/// most: a request in flight when the app left the foreground was cancelled, and
/// nothing remembered it. That is not a rounding error in somebody's report — it
/// is the impression that paid for the break.
///
/// Retrying, including across launches, is safe here by design rather than by
/// hope: a VAST tracking URI carries its own event identity, so a repeat is
/// de-duplicated by the ad server instead of double-counted. `<Impression>` is
/// explicit about at-least-once delivery for exactly this reason.
///
/// Limits keep the file from becoming a graveyard and retries from becoming a
/// flood. A beacon older than `maxAge` is dropped, because a report about
/// yesterday is worth less to an ad server than a clean count; the queue holds
/// `capacity` entries, oldest first out, so a device that spends a week offline
/// does not accumulate a megabyte of URLs it will never send. And a retry is
/// rationed: `takeForRetry()` hands out at most `retryBatch` beacons, at most once
/// every `retryInterval`, and a beacon that has failed `maxRetries` of those is
/// let go. Without that ration a tracker that never answers — an ad blocker or a
/// DNS filter makes one of every tracker it knows — had its whole backlog sent
/// again, twice, with every new beacon.
actor VASTBeaconQueue {

    /// Shared, so retries survive the session that queued them — and so a host
    /// that builds a transport per break does not build a queue per break, nor a
    /// retry ration per break.
    static let shared = VASTBeaconQueue()

    /// Older than this and a beacon is dropped rather than sent.
    static let maxAge: TimeInterval = 6 * 60 * 60

    /// Most beacons kept at once.
    static let capacity = 500

    /// The least time between two retry batches from one process.
    static let retryInterval: TimeInterval = 30

    /// The most beacons one retry batch sends.
    static let retryBatch = 50

    /// Retry batches a beacon may fail before it is let go.
    static let maxRetries = 5

    /// One held beacon, with the moment it was first recorded — which is what it
    /// ages from — and the retry batches it has already failed.
    ///
    /// `retries` is absent until a retry fails, so a file written before retries
    /// were counted reads the same, and a beacon that has only failed its first
    /// send is stored as it always was.
    struct Entry: Codable, Sendable, Equatable {
        let url: URL
        let recorded: Date
        var retries: Int?

        /// The same beacon, one failed retry later.
        func failedAgain() -> Entry {
            Entry(url: url, recorded: recorded, retries: (retries ?? 0) + 1)
        }
    }

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var pending: [Entry]?

    /// When this process last handed out a retry batch; `nil` until it has.
    private var lastRetry: Date?
    private let log = Logger(subsystem: "com.kinodaran.vastsdk", category: "delivery")

    init(fileName: String = "vast-pending-beacons.json", now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        // Caches rather than Application Support, for two reasons: the system
        // reclaiming these costs a count rather than anything the viewer would
        // miss, and Caches is excluded from device backups — so a queued
        // identifier does not travel to iCloud or to a desktop archive.
        fileURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    /// Keeps beacons that failed, so the next flush can try again.
    func enqueue(_ urls: [URL]) {
        let recorded = now()
        keep(urls.map { Entry(url: $0, recorded: recorded) })
    }

    /// Puts back beacons that were taken and failed again, keeping when each was
    /// first recorded. Re-stamping them would let a tracker that never answers
    /// live in the file for ever, carrying whatever consent string its URL holds
    /// past the age limit meant to drop it. One that has used up its
    /// `maxRetries` is dropped here instead.
    func requeue(_ entries: [Entry]) {
        let kept = entries.filter { ($0.retries ?? 0) < Self.maxRetries }
        let dropped = entries.count - kept.count
        if dropped > 0 {
            log.notice("gave up on \(dropped, privacy: .public) beacon(s) after \(Self.maxRetries, privacy: .public) retries")
        }
        keep(kept)
    }

    /// The next retry batch — oldest first, at most `retryBatch` — or nothing
    /// when this process took one less than `retryInterval` ago.
    ///
    /// Taken rather than copied: whoever takes a batch owns its delivery from
    /// that point, and requeues what fails again with one more retry counted.
    /// The rest stays queued for a later batch.
    func takeForRetry() -> [Entry] {
        let now = now()
        // A clock set back is no reason to stop retrying until it catches up.
        if let lastRetry {
            let since = now.timeIntervalSince(lastRetry)
            if since >= 0, since < Self.retryInterval { return [] }
        }
        let entries = trimmed(load())
        guard !entries.isEmpty else { return [] }
        lastRetry = now
        let batch = Array(entries.prefix(Self.retryBatch))
        let rest = Array(entries.dropFirst(batch.count))
        pending = rest
        save(rest)
        return batch
    }

    /// Takes everything worth retrying, and forgets it — unrationed, which is
    /// what the tests and an empty-the-queue tool want; the transport uses
    /// `takeForRetry()`.
    ///
    /// Taken rather than copied: whoever drains the queue owns delivery from that
    /// point, and re-queues what fails again. Holding on as well would send every
    /// beacon twice on every flush for as long as one of them kept failing.
    func drain() -> [URL] {
        let entries = trimmed(load())
        guard !entries.isEmpty else { return [] }
        pending = []
        save([])
        return entries.map(\.url)
    }

    func count() -> Int { trimmed(load()).count }

    private func keep(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        let kept = trimmed(load() + entries)
        pending = kept
        save(kept)
        log.notice("holding \(kept.count, privacy: .public) beacon(s) for retry")
    }

    /// Only for tests, which must not inherit the last run's file.
    func removeAll() {
        pending = []
        save([])
    }

    // MARK: - Storage

    private func load() -> [Entry] {
        if let pending { return pending }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            pending = []
            return []
        }
        let entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        pending = entries
        return entries
    }

    private func save(_ entries: [Entry]) {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        // Encrypted at rest, because of what these URLs contain. Macros are
        // expanded before a beacon reaches a transport, so a queued URL carries
        // whatever the host supplied — an advertising identifier and a TCF consent
        // string among them. Holding that in plaintext for hours is not what
        // keeping a beacon was meant to cost.
        //
        // `.completeFileProtection` rather than `.completeUnlessOpen`: a flush
        // only happens while an ad is playing, so the file never needs reading
        // while the device is locked.
        //
        // Not on macOS, where the option is not merely unnecessary but fatal:
        // data protection classes are an iOS mechanism, and `write` refuses the
        // whole write rather than ignoring an option it cannot honour — which
        // meant the queue never survived a relaunch there at all. Whole-disk
        // encryption is the Mac's answer and is not ours to ask for.
        //
        // A failed write is not worth interrupting anything for: the beacons are
        // still in memory, and this run will still try to send them.
        #if os(macOS)
        let options: Data.WritingOptions = [.atomic]
        #else
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #endif
        do {
            try data.write(to: fileURL, options: options)
        } catch {
            log.notice("could not hold beacons for retry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimmed(_ entries: [Entry]) -> [Entry] {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        let fresh = entries.filter { $0.recorded > cutoff }
        guard fresh.count > Self.capacity else { return fresh }
        return Array(fresh.suffix(Self.capacity))
    }
}
