//
//  VASTPlayerClock.swift
//  VASTSDK
//

import Foundation
import AVFoundation
import VASTCore

/// Default `iVASTClock`: an `AVPlayer` periodic time observer.
///
/// Also stamps `itemIsOurs`, which is how the tracking engine learns that the
/// host replaced the player's item in the middle of the ad — the one situation
/// where nothing after this moment can be attributed to the creative.
public final class VASTPlayerClock: iVASTClock, @unchecked Sendable {

    private let player: AVPlayer
    private let adItem: AVPlayerItem
    private let interval: CMTime

    private let lock = NSLock()
    private var observer: Any?
    private var continuation: AsyncStream<VASTTick>.Continuation?

    /// - Parameter interval: how often to sample. 200 ms keeps quartile timing
    ///   within a frame or two without waking the CPU on every frame.
    public init(player: AVPlayer, adItem: AVPlayerItem, interval: TimeInterval = 0.2) {
        self.player = player
        self.adItem = adItem
        self.interval = CMTime(seconds: interval, preferredTimescale: 600)
    }

    public func ticks() -> AsyncStream<VASTTick> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let observer = player.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                // The observer is registered on the main queue, where AVPlayer
                // playback state is isolated on iOS and tvOS.
                MainActor.assumeIsolated {
                    continuation.yield(self.tick(at: time))
                }
            }

            lock.lock()
            self.observer = observer
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        lock.lock()
        let observer = self.observer
        let continuation = self.continuation
        self.observer = nil
        self.continuation = nil
        lock.unlock()

        if let observer { player.removeTimeObserver(observer) }
        continuation?.finish()
    }

    @MainActor
    private func tick(at time: CMTime) -> VASTTick {
        let current = player.currentItem
        let duration = adItem.duration
        return VASTTick(
            adTime: time.seconds.isFinite ? time.seconds : 0,
            duration: duration.isNumeric ? duration.seconds : nil,
            rate: player.rate,
            // A monotonic reading, so a system clock change cannot be mistaken
            // for playback progress.
            wallClock: ProcessInfo.processInfo.systemUptime,
            itemIsOurs: current === adItem,
            isMuted: player.isMuted
        )
    }
}
