//
//  VASTPlaybackController.swift
//  VASTSDK
//

import Foundation
import AVFoundation
import VASTCore

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Owns the host's `AVPlayer` for the duration of an ad break.
///
/// Snapshots whatever was playing, swaps in the creative, and puts the original
/// item and position back afterwards. Seeking is not offered while an ad is on
/// screen: VAST defines no attribute that would ever permit it, and the tracking
/// engine treats a jump as unwatched time regardless.
@MainActor
final class VASTPlaybackController {

    /// How long a creative may take to become playable before it is written off.
    /// Generous, because a cold CDN edge on a slow connection is not a failure.
    static let readinessTimeout: TimeInterval = 8

    private let player: AVPlayer

    private var hostItem: AVPlayerItem?
    private var hostTime: CMTime = .zero
    private var hostWasPlaying = false
    private var didSnapshot = false

    /// True from the moment the creative is asked to play until the break ends.
    /// Distinguishes "the ad should be running" from "the player happens to be
    /// stopped", which is the difference between resuming and doing nothing.
    private(set) var wantsPlayback = false
    /// True while the app is not frontmost, or audio is interrupted. The stall
    /// watchdog is suspended for that time: a backgrounded ad is not a broken one.
    private(set) var isSuspendedBySystem = false
    /// True while the ad is held paused on someone's behalf — the host through
    /// `VASTAdSession.pause()`, or a viewer through a control the SDK does not
    /// own, such as the one in the Picture in Picture window.
    ///
    /// `resumeIfNeeded()` re-issues playback on every tick because iOS leaves
    /// `rate` at 0 after backgrounding and never restarts on its own, so without
    /// this flag an ad the viewer paused was resumed within one tick. What tells
    /// the two apart is `timeControlStatus` rather than `rate` — see
    /// `observePlaybackStatus()`.
    private(set) var isPausedByUser = false

    /// Set when the break is being abandoned. Everything in flight has to notice:
    /// a `begin` still waiting for its creative would otherwise finish, call
    /// `play()`, and put an ad back on a player the host has already moved on from.
    private(set) var isAborted = false

    private var observers: [any NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    /// Playback started or stopped without this controller asking for it.
    ///
    /// Only that it happened; what it means is the session's to decide, because
    /// deciding needs what the session knows — whether an ad is on screen, and
    /// whether the Picture in Picture window is open, where a stop can only have
    /// come from the viewer.
    var didObservePlaybackChange: ((Bool) -> Void)?

    /// Assets warmed ahead of time, by URL.
    ///
    /// Held rather than discarded because the warming is only worth anything if
    /// the same asset is the one that plays: a second `AVURLAsset` for the same
    /// URL starts its metadata over.
    private var warmed: [URL: AVURLAsset] = [:]

    init(player: AVPlayer) {
        self.player = player
        observeSystemInterruptions()
        observePlaybackStatus()
    }

    /// Explicit teardown rather than `deinit`: observer tokens are not
    /// `Sendable`, so a nonisolated deinit cannot legally touch them under
    /// Swift 6 strict concurrency. The session calls this when the break ends.
    func invalidate() {
        wantsPlayback = false
        warmed.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        statusObservation?.invalidate()
        statusObservation = nil
        didObservePlaybackChange = nil
    }

    /// Starts fetching what the break will need next, while it plays what it has.
    ///
    /// Not prebuffering, and it would be dishonest to call it that: an
    /// `AVPlayerItem` does not buffer until it belongs to a player, and giving a
    /// second player one would double the bandwidth to hide a gap. What this does
    /// warm is the part the readiness wait actually spends — DNS, the TLS
    /// handshake, and the container's header — so the next creative starts from a
    /// connection that already exists.
    func prepare(mediaFile: VASTAd.MediaFile) {
        guard !isAborted, warmed[mediaFile.url] == nil else { return }
        let asset = AVURLAsset(url: mediaFile.url)
        warmed[mediaFile.url] = asset
        Task { _ = try? await asset.load(.isPlayable, .duration) }
    }

    /// Loads a creative and starts it playing.
    ///
    /// - Returns: the item the ad plays on, so the caller can build a clock bound
    ///   to it.
    func begin(mediaFile: VASTAd.MediaFile) async throws -> AVPlayerItem {
        guard !isAborted else { throw VASTError.mediaFileTimeout }
        snapshotHostIfNeeded()
        wantsPlayback = true

        // The warmed asset if there is one, and taken rather than copied: a pod
        // does not play the same creative twice, and holding every asset for the
        // length of the break would hold every creative's memory with it.
        let asset = warmed.removeValue(forKey: mediaFile.url) ?? AVURLAsset(url: mediaFile.url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        // Ask for playback straight away rather than after readiness: AVPlayer
        // already defers until the item can play, and requesting it up front
        // means a slow first buffer shows as buffering instead of as a stall.
        player.play()

        try await waitUntilPlayable(item)
        return item
    }

    /// Waits for the item to become playable, or gives up.
    ///
    /// Deliberately polls `status` instead of awaiting a KVO publisher. The
    /// publisher form hung indefinitely here: if the item settles before the
    /// async sequence is subscribed, the transition is simply never delivered and
    /// the whole ad break stops with the creative never appearing. Polling cannot
    /// miss an edge, and the deadline means it cannot hang either.
    private func waitUntilPlayable(_ item: AVPlayerItem) async throws {
        var remaining = Self.readinessTimeout

        while true {
            switch item.status {
            case .readyToPlay:
                return
            case .failed:
                throw Self.error(for: item)
            default:
                // Time spent in the background does not count against the
                // deadline; the item simply is not being decoded then.
                guard remaining > 0 else { throw VASTError.mediaFileTimeout }
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !isSuspendedBySystem { remaining -= 0.05 }
            }
            if Task.isCancelled || isAborted { throw VASTError.mediaFileTimeout }
        }
    }

    /// Maps AVFoundation's failure onto the code an ad server understands.
    private static func error(for item: AVPlayerItem) -> VASTError {
        guard let urlError = item.error as? URLError else {
            // A supported container the pipeline still could not render.
            return .mediaFileDisplayProblem
        }
        switch urlError.code {
        case .fileDoesNotExist, .badURL, .unsupportedURL, .resourceUnavailable:
            return .mediaFileNotFound
        case .timedOut:
            return .mediaFileTimeout
        default:
            return .mediaFileNotFound
        }
    }

    // MARK: - System interruptions

    /// Re-issues playback after the system took it away.
    ///
    /// iOS stops decoding video when the app leaves the foreground and does not
    /// resume on return — `rate` is simply left at 0. Without this the creative
    /// sits frozen on screen for the rest of the break, and because the playhead
    /// never moves again the ad can never end on its own either.
    private func observeSystemInterruptions() {
        #if os(macOS)
        let activated = NSApplication.didBecomeActiveNotification
        let deactivated = NSApplication.didResignActiveNotification
        #else
        let activated = UIApplication.didBecomeActiveNotification
        let deactivated = UIApplication.willResignActiveNotification
        #endif

        observers.append(NotificationCenter.default.addObserver(
            forName: deactivated, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isSuspendedBySystem = true }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: activated, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSuspendedBySystem = false
                self?.resumeIfNeeded()
            }
        })

        #if !os(macOS)
        // A phone call or another app taking the audio session stops playback
        // the same way, and likewise never restarts it.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Read the payload here, on the delivery queue: `Notification` is not
            // `Sendable`, so only the extracted value may cross into the actor.
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    self?.isSuspendedBySystem = true
                case .ended:
                    self?.isSuspendedBySystem = false
                    self?.resumeIfNeeded()
                default:
                    break
                }
            }
        })
        #endif
    }

    /// Watches `timeControlStatus`, which is what makes this possible at all.
    ///
    /// A rate of zero is buffering and pausing at the same time, so from `rate`
    /// alone the SDK could not tell a viewer's pause from a slow segment — and
    /// guessing wrong either drops a §3.14.1 `pause` or invents one on every
    /// stall. That is why pausing had to be *stated* through the session. The
    /// status separates the two cases the rate conflates:
    /// `.waitingToPlayAtSpecifiedRate` is the buffer, `.paused` is somebody's
    /// decision — and a decision the session did not make is one worth reporting.
    private func observePlaybackStatus() {
        statusObservation = player.observe(
            \.timeControlStatus, options: [.new]
        ) { [weak self] _, change in
            guard let status = change.newValue else { return }
            // Hopped rather than assumed: KVO is delivered on whichever thread
            // changed the value, and `AVPlayer` does not promise that is the
            // main one.
            Task { @MainActor in self?.noteTimeControl(status) }
        }
    }

    private func noteTimeControl(_ status: AVPlayer.TimeControlStatus) {
        guard wantsPlayback, !isAborted else { return }
        switch status {
        case .playing:
            didObservePlaybackChange?(true)
        case .paused:
            // Ours, and reported when it was made. Reporting it twice would put
            // two `pause` events on one pause.
            guard !isPausedByUser else { return }
            didObservePlaybackChange?(false)
        case .waitingToPlayAtSpecifiedRate:
            break
        @unknown default:
            break
        }
    }

    /// Restarts playback if the ad should be running and nothing else stopped it.
    func resumeIfNeeded() {
        guard wantsPlayback, !isAborted, !isSuspendedBySystem, !isPausedByUser,
              player.rate == 0
        else { return }
        player.play()
    }

    /// Holds the ad where it is until `resumeByUser()`.
    func pauseByUser() {
        isPausedByUser = true
        player.pause()
    }

    func resumeByUser() {
        isPausedByUser = false
        resumeIfNeeded()
    }

    /// Abandons the break immediately: stop asking for playback, stop the sound,
    /// and make anything still waiting give up.
    func abort() {
        isAborted = true
        wantsPlayback = false
        player.pause()
    }

    /// Records what the host was playing, once per ad break rather than per ad,
    /// so a pod restores the content the viewer actually came for.
    private func snapshotHostIfNeeded() {
        guard !didSnapshot else { return }
        didSnapshot = true
        hostItem = player.currentItem
        hostTime = player.currentTime()
        hostWasPlaying = player.rate > 0
        player.pause()
    }

    /// Puts the host's content back exactly where it was interrupted.
    ///
    /// - Parameter resumingPlayback: pass `false` when the host is leaving rather
    ///   than watching on. Restoring the item and then playing it is how an
    ///   abandoned break kept making noise after the screen was dismissed.
    func restore(resumingPlayback: Bool = true) {
        wantsPlayback = false
        defer { didSnapshot = false }
        guard didSnapshot else { return }

        let item = hostItem
        let time = hostTime
        let resume = hostWasPlaying && resumingPlayback

        hostItem = nil
        hostTime = .zero
        hostWasPlaying = false

        player.pause()
        player.replaceCurrentItem(with: item)
        guard item != nil else { return }
        player.seek(to: time) { [weak player] _ in
            guard resume else { return }
            // AVPlayer does not promise a main-actor seek completion.
            Task { @MainActor [weak player] in player?.play() }
        }
    }
    
}
