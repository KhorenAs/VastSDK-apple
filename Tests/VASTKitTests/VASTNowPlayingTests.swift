//
//  VASTNowPlayingTests.swift
//  VASTKitTests
//

import XCTest
import MediaPlayer
@testable import VASTCore
@testable import VASTKit

/// The Now Playing transport is two process-wide singletons, so the SDK cannot
/// be handed one — it borrows them for the break and gives them back. These
/// check the giving back, which is the half that is easy to get wrong and
/// impossible to notice: a `skipForwardCommand` left disabled is a host's own
/// control that quietly stopped working after an ad.
@MainActor
final class VASTNowPlayingTests: XCTestCase {

    private var center: MPRemoteCommandCenter { .shared() }
    private var infoCenter: MPNowPlayingInfoCenter { .default() }

    private func ad(title: String? = "Fresh Socks", advertiser: String? = "Sock Co") -> VASTAd {
        VASTAd(
            id: "a1",
            title: title,
            linear: VASTAd.Linear(
                duration: 30,
                skipOffset: nil,
                mediaFiles: [],
                clickThrough: nil,
                clickTracking: [],
                trackingEvents: [:],
                progressEvents: []
            ),
            advertiser: advertiser
        )
    }

    override func tearDown() async throws {
        await MainActor.run {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        try await super.tearDown()
    }

    // MARK: - The default

    func testTheDefaultDescribesTheAd() {
        XCTAssertEqual(VASTAdSession.Configuration().nowPlaying, .describesAd)
    }

    // MARK: - Commands

    /// Seeking has no meaning inside a linear creative, and the lock screen is
    /// somewhere the host cannot see it being offered.
    func testSeekingIsTakenOffTheLockScreenForTheBreak() {
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true

        let nowPlaying = VASTNowPlayingController(policy: .locksControls)
        nowPlaying.adBreakDidBegin()

        XCTAssertFalse(center.changePlaybackPositionCommand.isEnabled)
        XCTAssertFalse(center.skipForwardCommand.isEnabled)
        XCTAssertFalse(center.nextTrackCommand.isEnabled)

        nowPlaying.adBreakDidEnd()

        XCTAssertTrue(center.changePlaybackPositionCommand.isEnabled)
        XCTAssertTrue(center.skipForwardCommand.isEnabled)
        XCTAssertTrue(center.nextTrackCommand.isEnabled)
    }

    /// Restored, not enabled. A host that had a command switched off gets it
    /// back switched off — the break borrowed the setting, it did not decide it.
    func testACommandTheHostHadDisabledStaysDisabled() {
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = true

        let nowPlaying = VASTNowPlayingController(policy: .locksControls)
        nowPlaying.adBreakDidBegin()
        nowPlaying.adBreakDidEnd()

        XCTAssertFalse(center.skipBackwardCommand.isEnabled, "the SDK enabled what the host had off")
        XCTAssertTrue(center.seekForwardCommand.isEnabled)
    }

    /// Play and pause reach the player like any other pause, and the session
    /// reports them. Disabling them would take a working control away.
    func testPlayAndPauseAreLeftAlone() {
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true

        let nowPlaying = VASTNowPlayingController(policy: .describesAd)
        nowPlaying.adBreakDidBegin()

        XCTAssertTrue(center.playCommand.isEnabled)
        XCTAssertTrue(center.pauseCommand.isEnabled)
        XCTAssertTrue(center.togglePlayPauseCommand.isEnabled)

        nowPlaying.adBreakDidEnd()
    }

    func testUntouchedTouchesNothing() {
        center.changePlaybackPositionCommand.isEnabled = true
        infoCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: "The Film"]

        let nowPlaying = VASTNowPlayingController(policy: .untouched)
        nowPlaying.adBreakDidBegin()
        nowPlaying.adDidStart(ad(), duration: 30)

        XCTAssertTrue(center.changePlaybackPositionCommand.isEnabled)
        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "The Film")

        nowPlaying.adBreakDidEnd()
    }

    // MARK: - What it says

    /// `<AdTitle>` and `<Advertiser>`, so the lock screen stops naming a film
    /// that is not the thing making the sound.
    func testTheAdIsNamedWhileItPlays() {
        infoCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: "The Film"]

        let nowPlaying = VASTNowPlayingController(policy: .describesAd)
        nowPlaying.adBreakDidBegin()
        nowPlaying.adDidStart(ad(), duration: 30)

        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Fresh Socks")
        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String, "Sock Co")
        XCTAssertEqual(
            infoCenter.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 30
        )

        nowPlaying.adBreakDidEnd()

        XCTAssertEqual(
            infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "The Film",
            "the host's content was not put back"
        )
    }

    /// A response with no `<AdTitle>` still has to say something, and it has to
    /// say it in the viewer's language.
    func testAnUntitledAdFallsBackToTheLocalisedWord() {
        let nowPlaying = VASTNowPlayingController(policy: .describesAd)
        nowPlaying.adBreakDidBegin()
        nowPlaying.adDidStart(ad(title: nil, advertiser: nil), duration: 15)

        let title = infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
        XCTAssertEqual(title, VASTStrings.text("nowplaying.title"))
        XCTAssertNotEqual(title, "nowplaying.title", "the key came back unresolved")
        XCTAssertNil(
            infoCenter.nowPlayingInfo?[MPMediaItemPropertyArtist],
            "an unstated advertiser must not be invented"
        )

        nowPlaying.adBreakDidEnd()
    }

    /// A host that published nothing must be given nothing back, rather than
    /// left showing the ad after the break is over.
    func testAHostWithNoNowPlayingInformationGetsNoneBack() {
        infoCenter.nowPlayingInfo = nil

        let nowPlaying = VASTNowPlayingController(policy: .describesAd)
        nowPlaying.adBreakDidBegin()
        nowPlaying.adDidStart(ad(), duration: 30)
        XCTAssertNotNil(infoCenter.nowPlayingInfo)

        nowPlaying.adBreakDidEnd()

        XCTAssertNil(infoCenter.nowPlayingInfo)
    }

    /// The lock screen runs its own clock from the rate it was last given, so a
    /// pause it is not told about goes on counting.
    func testPausingStopsTheLockScreenClock() {
        let nowPlaying = VASTNowPlayingController(policy: .describesAd)
        nowPlaying.adBreakDidBegin()
        nowPlaying.adDidStart(ad(), duration: 30)

        nowPlaying.notePlayback(isPlaying: false, elapsed: 12)
        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(
            infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12
        )

        nowPlaying.notePlayback(isPlaying: true, elapsed: 12)
        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)

        nowPlaying.adBreakDidEnd()
    }

    /// `locksControls` is the half that does not speak.
    func testLocksControlsLeavesTheHostsInformationAlone() {
        infoCenter.nowPlayingInfo = [MPMediaItemPropertyTitle: "The Film"]

        let nowPlaying = VASTNowPlayingController(policy: .locksControls)
        nowPlaying.adBreakDidBegin()
        nowPlaying.adDidStart(ad(), duration: 30)

        XCTAssertEqual(infoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "The Film")
        XCTAssertFalse(center.changePlaybackPositionCommand.isEnabled)

        nowPlaying.adBreakDidEnd()
    }
}
