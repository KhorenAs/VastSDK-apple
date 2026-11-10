//
//  VASTAdSession+Play.swift
//  VASTSDK
//

import Foundation
import AVFoundation
import VASTCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension VASTAdSession {

    /// Plays every ad the response yielded, in order, then restores the host's
    /// content.
    ///
    /// A single ad failing does not end the break: §3.3.1 asks the player to
    /// substitute an unplayed stand-alone ad, and to move on to the next pod
    /// member when no substitute is left.
    @discardableResult
    public func play() async -> Outcome {
        // A second caller joins the break in flight instead of starting a rival
        // one. Returning its outcome keeps `play()` honest for both callers.
        if let running = activeBreak { return await running.value }
        // A `play` that was waiting behind a `load` the host has since stopped
        // must not start anything. `stop()` clears the schedule; this is what
        // notices.
        guard scheduler != nil else { return .failed(.undefined) }

        // `[weak self]` is defensive rather than load-bearing: a completed `Task`
        // does not retain its closure's captures, so storing it in `activeBreak`
        // is not a cycle — measured, not assumed. Weak keeps it true even if the
        // task is later made long-lived.
        let task = Task { @MainActor [weak self] () -> Outcome in
            guard let self else { return .failed(.undefined) }
            return await self.runBreak()
        }
        activeBreak = task
        let outcome = await task.value
        if activeBreak == task { activeBreak = nil }
        return outcome
    }

    private func runBreak() async -> Outcome {
        guard var scheduler else { return .failed(.undefined) }

        let playback = VASTPlaybackController(player: player)
        activePlayback = playback
        playback.didObservePlaybackChange = { [weak self] isPlaying in
            self?.noteExternalPlayback(isPlaying: isPlaying)
        }
        transactionID = UUID().uuidString
        // Before anything plays: under `.suspended` the window has to be closed
        // while the content is still the thing in it, not after the creative has
        // already appeared there.
        pictureInPicture?.adBreakDidBegin()

        // And the host's own controls, for the same reason and one step closer:
        // the scrubber in the app is the one the viewer reaches first.
        playbackControls?.adBreakDidBegin(pictureInPicture: configuration.pictureInPicture)

        // Likewise the system transport: the seek controls have to be gone
        // before a creative is what they would be seeking.
        let nowPlaying = VASTNowPlayingController(policy: configuration.nowPlaying)
        self.nowPlaying = nowPlaying
        nowPlaying.adBreakDidBegin()
        defer {
            if configuration.restoresPlayerItem {
                // An abandoned break must not hand the content back *playing*:
                // the host is leaving, and resuming here is what kept the audio
                // going after the screen was dismissed.
                playback.restore(resumingPlayback: !playback.isAborted)
            }
            playback.invalidate()
            if activePlayback === playback { activePlayback = nil }
            pictureInPicture?.adBreakDidEnd()
            playbackControls?.adBreakDidEnd()
            nowPlaying.adBreakDidEnd()
            if self.nowPlaying === nowPlaying { self.nowPlaying = nil }
            self.scheduler = nil
            currentAd = nil
            canSkip = false
            timeUntilSkip = nil
            remainingTime = 0
            lastTick = nil
            currentMediaFile = nil
            delegate?.sessionDidFinishAllAds(self)
        }

        var lastOutcome: Outcome = .failed(.undefined)
        var index = 0

        while let queued = scheduler.next() {
            if Task.isCancelled || playback.isAborted { break }
            index += 1
            adPosition = AdPosition(index: index, total: scheduler.totalCount)

            // While this creative plays, start fetching the one after it. A pod
            // used to show a black gap per ad, because each one's readiness wait
            // began only once the one before it had finished.
            warmNextCreative(after: scheduler, using: playback)

            var outcome = await playOne(queued, using: playback)
            if case .failed = outcome, let substitute = scheduler.substituteForFailure() {
                outcome = await playOne(substitute, using: playback)
            }
            lastOutcome = outcome
        }

        self.scheduler = scheduler
        state = .finished(lastOutcome)
        return lastOutcome
    }

    /// Warms the creative the pod will need next, if the response gave one.
    private func warmNextCreative(
        after scheduler: VASTPodScheduler,
        using playback: VASTPlaybackController
    ) {
        guard let upcoming = scheduler.peek() else { return }
        guard let file = try? VASTMediaFileSelector().select(
            from: upcoming.linear.mediaFiles,
            capabilities: playbackCapabilities()
        ) else { return }
        playback.prepare(mediaFile: file)
    }

    // MARK: - One ad

    private func playOne(_ ad: VASTAd, using playback: VASTPlaybackController) async -> Outcome {
        currentAd = ad
        resetComplianceReports()
        canSkip = false
        timeUntilSkip = ad.linear.resolvedSkipOffset()
        // Seed the countdown from <Duration> so the overlay reads the creative's
        // length while it buffers, instead of showing 0s.
        remainingTime = ad.linear.duration
        state = .loading
        lastTick = nil

        // The engine reports verificationNotExecuted unless told something will
        // run the vendors' code. It cannot see the measurement layer itself, so
        // the answer is passed in.
        var engine = VASTTrackingEngine(ad: ad, measurementWillRun: measurement != nil)

        // §2.3: "nor should the media player play the Skippable Ad as a Linear
        // Ad (without skip controls)". A host that cannot offer the control is
        // told to expect a trafficking error, not handed a compliance breach.
        if ad.isSkippable, effectiveSkipPresentation == .unsupported {
            return fail(.trafficking, ad: ad, engine: &engine)
        }

        let file: VASTAd.MediaFile
        do {
            file = try VASTMediaFileSelector().select(
                from: ad.linear.mediaFiles,
                capabilities: playbackCapabilities()
            )
        } catch {
            return fail(.noSupportedMediaFile, ad: ad, engine: &engine)
        }

        currentMediaFile = file

        let item: AVPlayerItem
        do {
            item = try await playback.begin(mediaFile: file)
        } catch let error as VASTError {
            return fail(error, ad: ad, engine: &engine)
        } catch {
            return fail(.mediaFileDisplayProblem, ad: ad, engine: &engine)
        }

        // The creative became playable, but the break may have been abandoned
        // while it loaded — in which case nothing should go on screen.
        if Task.isCancelled || playback.isAborted {
            return .failed(.mediaFileTimeout)
        }

        // Before the impression: the creative is ready, which is what `loaded`
        // means, and it happens whether or not the ad is ever seen.
        send(engine.creativeDidLoad())

        state = .playing
        verifyClickPath(for: ad)
        // A window that was already open raises no callback of its own, so the
        // policy is re-asked here rather than only on the way in.
        pictureInPicture?.adDidStart()
        // `<Duration>` rather than the player's: the item has only just become
        // playable, and the declared length is what the countdown is using too.
        nowPlaying?.adDidStart(ad, duration: ad.linear.duration)
        // Before the impression: a measurement session has to exist for the
        // impression it is being asked to attest to.
        measurement?.begin(VASTMeasurementContext(ad: ad, adView: attachedSurface))
        delegate?.session(self, didStart: ad, at: adPosition)

        // A host with its own playback-time accounting — or a test with a
        // scripted sequence — supplies the clock; the built-in one is what binds
        // to the item just created, which is why it cannot be built any earlier.
        let clock = configuration.clock ?? VASTPlayerClock(player: player, adItem: item)
        self.activeClock = clock
        self.activeEngine = engine
        defer { activeClock = nil; activeEngine = nil }

        // The item reaching its end is the authoritative signal that the creative
        // is over. Watch time alone cannot be trusted for this: stalls are
        // deliberately excluded from it, so a single buffering hiccup would leave
        // the ad frozen on its last frame with nothing to end it.
        let endOfItem = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, var engine = self.activeEngine else { return }
                let beacons = engine.playbackDidReachEnd()
                self.activeEngine = engine
                self.send(beacons)
                self.activeClock?.stop()
            }
        }
        defer { NotificationCenter.default.removeObserver(endOfItem) }

        /// Wall-clock moment the playhead last moved, so a dead stream is
        /// abandoned instead of hanging the break.
        var lastAdvance = ProcessInfo.processInfo.systemUptime
        var lastPosition: TimeInterval = -1
        /// Why the creative ended, when the session decided it rather than the
        /// engine — a stall.
        var failure: VASTError?

        for await tick in clock.ticks() {
            guard var current = activeEngine else { break }
            lastTick = tick
            let beacons = current.advance(to: tick)
            activeEngine = current
            engine = current

            // Never awaited. A beacon is a request to somebody else's server:
            // awaiting it here means one slow or unreachable tracking host stops
            // the playback loop dead — the countdown freezes, the skip control
            // never unlocks, and the ad can never end. Tracking is best-effort by
            // design, so it is dispatched and forgotten.
            send(beacons)
            update(with: tick, ad: ad)
            // Covers the case where the system stopped playback and the
            // activation notification arrived before this loop was listening.
            playback.resumeIfNeeded()

            if tick.adTime > lastPosition + 0.01 {
                lastPosition = tick.adTime
                lastAdvance = tick.wallClock
            } else if playback.isSuspendedBySystem || playback.isPausedByUser {
                // Backgrounded, audio-interrupted, or paused by the host: the
                // playhead is meant to be still, so the clock for "stuck" does
                // not run. Without the pause case a viewer who paused for longer
                // than `stallTimeout` had the ad written off as unplayable.
                lastAdvance = tick.wallClock
            } else if playback.wantsPlayback,
                      tick.wallClock - lastAdvance > Self.stallTimeout {
                // A creative already watched through counts as complete — the
                // engine says so — and anything else is a 402: the host hears it
                // whether or not the response gave an `<Error>` URI to tell, and
                // it is the outcome. The engine finishes the creative by failing
                // it, so without `failure` the outcome fell through to 405, for an
                // ad everyone had been told was a 402.
                let watchedThrough = current.duration > 0
                    && current.watched >= current.duration * VASTTrackingEngine.completionThreshold
                send(current.playbackDidStall())
                activeEngine = current
                engine = current
                if !watchedThrough {
                    failure = .mediaFileTimeout
                    delegate?.session(self, didFail: .mediaFileTimeout, for: ad)
                }
                break
            }

            if current.isFinished { break }
        }
        clock.stop()

        let outcome: Outcome = outcomeFor(engine, failure: failure)
        skipRequested = false
        // Exactly once per `begin`, whatever the outcome: a measurement session
        // left open counts against the vendor, not against us.
        measurement?.finish()
        delegate?.session(self, didFinish: ad, outcome: outcome)
        return outcome
    }

    /// How long the playhead may sit still, while the player claims to be
    /// playing, before the creative is written off as unplayable (402).
    static let stallTimeout: TimeInterval = 10

    /// A skip beats everything, then a failure the session decided; otherwise
    /// the creative counts as completed only if the engine actually finished
    /// it, not merely because something played.
    private func outcomeFor(_ engine: VASTTrackingEngine, failure: VASTError?) -> Outcome {
        if skipRequested { return .skipped }
        if let failure { return .failed(failure) }
        guard engine.isFinished else { return .failed(.mediaFileTimeout) }
        return engine.watched >= engine.duration * VASTTrackingEngine.completionThreshold
            ? .completed
            : .failed(.mediaFileDisplayProblem)
    }

    private func fail(
        _ error: VASTError,
        ad: VASTAd,
        engine: inout VASTTrackingEngine
    ) -> Outcome {
        send(engine.fail(error))
        delegate?.session(self, didFail: error, for: ad)
        return .failed(error)
    }

    /// Hands beacons to the transport without waiting for them.
    ///
    /// Macros are substituted here rather than where each beacon is created: the
    /// values they need — playhead, muted state, which creative — belong to the
    /// session, and doing it in one place is what stops a `[ERRORCODE]` going out
    /// as the literal text `[ERRORCODE]`.
    func send(_ beacons: [VASTBeacon]) {
        guard !beacons.isEmpty else { return }
        notifyMeasurement(of: beacons)
        notifyDelegate(of: beacons)
        let expanded = beacons.map(expandMacros)
        let transport = transport
        Task.detached { await transport.fire(expanded) }
    }

    /// Measurement is driven from the beacons rather than from separate call
    /// sites, so what a vendor observes is the same sequence, in the same order,
    /// that the ad server is told about. Two sources of truth here would drift,
    /// and the discrepancy would land in someone's viewability report.
    private func notifyMeasurement(of beacons: [VASTBeacon]) {
        guard let measurement else { return }
        var last: VASTMeasurementEvent?
        for beacon in beacons {
            guard let event = Self.measurementEvent(for: beacon.kind, isMuted: lastTick?.isMuted ?? false, duration: activeEngine?.duration ?? 0) else { continue }
            // One `<Impression>` element per vendor is normal; one impression is
            // what happened.
            if event == last { continue }
            last = event
            measurement.record(event)
        }
    }

    /// The delegate hears the same sequence, in the same order, and for the
    /// same reason measurement does: a second set of call sites would drift
    /// from the beacons, and then a host's own analytics would disagree with
    /// the ad server's.
    private func notifyDelegate(of beacons: [VASTBeacon]) {
        guard let delegate else { return }
        var last: VASTBeacon.Kind?
        for beacon in beacons {
            // Three `<Impression>` URLs are three beacons and one impression.
            if beacon.kind == last { continue }
            last = beacon.kind
            delegate.session(self, didReport: beacon.kind, for: currentAd)
        }
    }

    private static func measurementEvent(
        for kind: VASTBeacon.Kind,
        isMuted: Bool,
        duration: TimeInterval
    ) -> VASTMeasurementEvent? {
        switch kind {
        case .impression:
            return .impression
        case .progress(let offset):
            return .progress(offset)
        case .clickTracking:
            return .clicked
        case .error(let error):
            return .failed(error)
        case .customClick:
            return .clicked
        case .verificationNotExecuted, .viewUndetermined:
            // Both are only fired when nothing is measuring, so nobody is
            // listening for them.
            return nil
        case .tracking(let event):
            switch event {
            case .start: return .start(duration: duration, isMuted: isMuted)
            case .firstQuartile, .midpoint, .thirdQuartile, .complete: return .quartile(event)
            case .pause: return .pause
            case .resume: return .resume
            case .skip: return .skipped
            default: return nil
            }
        }
    }

    private func expandMacros(_ beacon: VASTBeacon) -> VASTBeacon {
        var context = VASTMacroExpander.Context(
            adPlayhead: lastTick?.adTime,
            assetURI: currentMediaFile?.url,
            // Everything below used to go out as "unknown" while the session knew
            // the answer perfectly well — which is most of what made a request
            // from this SDK look unattributable to an exchange.
            playerSize: surfacePixelSize,
            isMuted: lastTick?.isMuted,
            appBundle: Bundle.main.bundleIdentifier,
            // Answerable now that <AdVerifications> is parsed: before, this went
            // out as "unknown" even when the response named its vendors.
            verificationVendors: currentAd?.adVerifications.compactMap(\.vendor) ?? [],
            omidPartner: measurement?.omidPartner,
            host: configuration.macroValues,
            mediaMIMEType: currentMediaFile?.mimeType,
            transactionID: transactionID,
            executesOMID: measurement != nil
        )
        // Only an error beacon carries a code, and it is the code for *this*
        // failure — not the last one the session happened to see. `[REASON]`
        // works the same way: it belongs to the beacon, not to the session.
        switch beacon.kind {
        case .error(let error):
            context.errorCode = error
        case .verificationNotExecuted(let reason):
            context.verificationNotExecutedReason = reason
        default:
            break
        }
        return VASTBeacon(
            kind: beacon.kind,
            url: macros.expand(beacon.url, with: context),
            adID: beacon.adID
        )
    }

    /// The player's size in pixels, for `[PLAYERSIZE]`.
    ///
    /// The surface is the player area, so this is the size of the ad as the viewer
    /// sees it — which is the number an exchange is actually asking for. `nil`
    /// where the SDK was never handed a surface, because a guess here is a
    /// viewability signal the SDK has no business inventing.
    private var surfacePixelSize: (width: Int, height: Int)? {
        guard let surface = attachedSurface, surface.bounds.width > 1, surface.bounds.height > 1
        else { return nil }
        let scale = Self.surfaceScale(of: surface)
        return (Int(surface.bounds.width * scale), Int(surface.bounds.height * scale))
    }

    /// Publishes the state SwiftUI and the delegate render from.
    private func update(with tick: VASTTick, ad: VASTAd) {
        let duration = tick.duration ?? ad.linear.duration
        remainingTime = max(0, duration - tick.adTime)
        delegate?.session(self, ad: ad, didProgressTo: tick.adTime, duration: duration)

        guard let unlockAt = ad.linear.resolvedSkipOffset() else {
            timeUntilSkip = nil
            return
        }
        let remainingUntilSkip = max(0, unlockAt - tick.adTime)
        timeUntilSkip = remainingUntilSkip > 0 ? remainingUntilSkip : nil

        if remainingUntilSkip <= 0, !canSkip {
            canSkip = true
            verifySkipSurface(for: ad)
            delegate?.session(self, skipDidBecomeAvailableFor: ad)
        }
    }

    /// The surface the creative will actually be shown on, used to rank media
    /// files.
    ///
    /// The ad surface is the player area, so asking it is asking the right thing.
    /// The whole screen was the wrong question twice over: an inline player a
    /// third of the screen high was handed 4K renditions it could not show and
    /// paid for the bandwidth anyway, and under multi-window or an external
    /// display the screen it named was not the one the ad was on.
    ///
    /// Falls back to the screen, because a SwiftUI host composes the surface
    /// itself and this session may never have been handed one.
    private func playbackCapabilities() -> VASTMediaFileSelector.Capabilities {
        if let surface = attachedSurface, surface.bounds.width > 1, surface.bounds.height > 1 {
            let scale = Self.surfaceScale(of: surface)
            return VASTMediaFileSelector.Capabilities(
                width: Int(surface.bounds.width * scale),
                height: Int(surface.bounds.height * scale)
            )
        }
        return Self.screenCapabilities()
    }

    private static func surfaceScale(of surface: VASTAdSurfaceView) -> CGFloat {
        #if os(macOS)
        surface.window?.backingScaleFactor ?? 2
        #else
        surface.window?.screen.scale ?? surface.traitCollection.displayScale
        #endif
    }

    private static func screenCapabilities() -> VASTMediaFileSelector.Capabilities {
        #if os(macOS)
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1280, height: 720)
        return VASTMediaFileSelector.Capabilities(width: Int(size.width), height: Int(size.height))
        #else
        let screen = UIScreen.main
        return VASTMediaFileSelector.Capabilities(
            width: Int(screen.bounds.width * screen.scale),
            height: Int(screen.bounds.height * screen.scale)
        )
        #endif
    }
}
