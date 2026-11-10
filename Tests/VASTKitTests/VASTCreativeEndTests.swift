//
//  VASTCreativeEndTests.swift
//  VASTKitTests
//

import XCTest
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import VASTCore
@testable import VASTKit

/// How a creative ends — a stall, a skip while paused — and what the next one
/// inherits from it.
///
/// The web and Android ports' tests found these. Like `VASTPlaybackLoopTests`,
/// these run the whole session against a creative that really decodes, with the
/// tick loop driven by a scripted clock: nothing here waits on real time.
@MainActor
final class VASTCreativeEndTests: XCTestCase {

    private var creative: URL!

    // No `super` calls, for the reason `VASTPlaybackLoopTests` gives.
    override func setUp() async throws {
        creative = try Self.playableFile(seconds: 30)
    }

    override func tearDown() async throws {
        if let creative { try? FileManager.default.removeItem(at: creative) }
        creative = nil
    }

    // MARK: - Stalls

    /// Stuck three seconds in: the stall watchdog writes it off as 402.
    private static let stuckEarly: [VASTTick] = [
        tick(0, wall: 0), tick(2, wall: 2), tick(3, wall: 3),
        tick(3, wall: 5), tick(3, wall: 10), tick(3, wall: 14),
    ]

    /// The ad server and the host were both told 402, and the outcome said 405:
    /// the engine finishes a creative by failing it, so the outcome fell through
    /// to "finished short of the end".
    func testAStalledAdEndsWithTheErrorItReported() async throws {
        let recorder = EndRecorder()
        let session = makeSession(xml: inLine(errorURI: true), clock: PodClock([Self.stuckEarly]), recorder: recorder)

        try await session.load(tag: Self.tag)
        let outcome = await session.play()

        XCTAssertEqual(recorder.events, ["failed a 402", "finished a failed 402"])
        XCTAssertEqual(outcome, .failed(.mediaFileTimeout))
    }

    /// A response with no `<Error>` URI has nobody to send 402 to; the host still
    /// has to hear the ad failed.
    func testAStallIsAnnouncedEvenWhenTheAdHasNoErrorURI() async throws {
        let recorder = EndRecorder()
        let session = makeSession(xml: inLine(errorURI: false), clock: PodClock([Self.stuckEarly]), recorder: recorder)

        try await session.load(tag: Self.tag)
        _ = await session.play()

        XCTAssertEqual(recorder.events, ["failed a 402", "finished a failed 402"])
    }

    /// The last frames of a creative already watched through are its end. The
    /// host used to hear "failed 402" and then "finished completed" for the
    /// same ad.
    func testAStallAfterTheCreativeWasWatchedThroughIsItsEnd() async throws {
        let recorder = EndRecorder()
        let clock = PodClock([[
            Self.tick(0, wall: 0), Self.tick(5, wall: 5), Self.tick(10, wall: 10), Self.tick(15, wall: 15),
            // Past the completion threshold, short of where the engine finishes on its own.
            Self.tick(19.5, wall: 19.5), Self.tick(19.5, wall: 25), Self.tick(19.5, wall: 30),
        ]])
        let session = makeSession(xml: inLine(errorURI: true), clock: clock, recorder: recorder)

        try await session.load(tag: Self.tag)
        let outcome = await session.play()

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(recorder.events, ["finished a completed"])
    }

    // MARK: - A pause and the next creative

    /// A pause belongs to the creative it was made on. Skipped while paused, the
    /// ad handed its pause to the next one: that one played anyway, because
    /// `begin()` starts every creative, but the controller still believed the
    /// viewer had paused it. So once the app left the foreground and came back,
    /// nothing restarted it, and it sat frozen while the session said `.playing`.
    func testAPauseDoesNotOutliveTheCreativeItWasMadeOn() async throws {
        let result = try await skipThenLeaveTheApp(pausingFirst: true)

        XCTAssertEqual(result.pausedByUser, false, "the skipped ad's pause was still on the next one")
        XCTAssertEqual(result.rate, 1, "the next ad was left stopped after the app came back, state \(String(describing: result.state))")
        XCTAssertEqual(result.state, .playing)
    }

    /// The same run without the pause, so the test above fails for the pause and
    /// not for the way the app's departure is staged.
    func testTheNextCreativeResumesWhenTheAppComesBack() async throws {
        let result = try await skipThenLeaveTheApp(pausingFirst: false)

        XCTAssertEqual(result.rate, 1)
    }

    private func skipThenLeaveTheApp(pausingFirst: Bool) async throws -> Observed {
        let player = AVPlayer()
        let probe = BoundaryProbe()
        let clock = PodClock([
            // The first ad unlocks its skip at 2s, and is skipped at 3.5s.
            [Self.tick(0, wall: 0), Self.tick(3, wall: 3), Self.tick(3.5, wall: 3.5), Self.tick(4, wall: 4)],
            // The second plays; the app leaves and comes back in the middle.
            (0..<12).map { Self.tick(Double($0), wall: Double($0)) },
        ]) { ad, index in
            guard let session = probe.session else { return }
            switch (ad, index) {
            case (0, 2):
                if pausingFirst { session.pause() }
                do { try session.skip() } catch { probe.failure = "skip refused: \(error)" }
            case (1, 3):
                NotificationCenter.default.post(name: Self.resignActive, object: nil)
                // What iOS does to the player of an app that leaves the foreground.
                player.pause()
            case (1, 6):
                NotificationCenter.default.post(name: Self.becomeActive, object: nil)
            case (1, 9):
                probe.observed = Observed(
                    rate: player.rate,
                    pausedByUser: session.activePlayback?.isPausedByUser,
                    state: session.state
                )
            default:
                break
            }
        }
        let session = makeSession(player: player, xml: pod(), clock: clock, recorder: EndRecorder())
        probe.session = session

        try await session.load(tag: Self.tag)
        _ = await session.play()

        if let failure = probe.failure { XCTFail(failure) }
        return probe.observed
    }

    // MARK: - Session under test

    static let tag = URL(string: "https://ads.test/tag")!

    #if os(macOS)
    static let resignActive = NSApplication.didResignActiveNotification
    static let becomeActive = NSApplication.didBecomeActiveNotification
    #else
    static let resignActive = UIApplication.willResignActiveNotification
    static let becomeActive = UIApplication.didBecomeActiveNotification
    #endif

    /// The delegate is weak; the test keeps it alive.
    private var recorders: [EndRecorder] = []

    private func makeSession(
        player: AVPlayer = AVPlayer(),
        xml: String,
        clock: any iVASTClock,
        recorder: EndRecorder
    ) -> VASTAdSession {
        let session = VASTAdSession(
            player: player,
            configuration: VASTAdSession.Configuration(
                restoresPlayerItem: false,
                clock: clock,
                transport: DiscardingTransport(),
                loader: InlineLoader(xml: xml)
            )
        )
        session.delegate = recorder
        recorders.append(recorder)
        return session
    }

    private func inLine(errorURI: Bool) -> String {
        "<VAST version=\"4.3\">\(ad(id: "a", sequence: nil, skipOffset: nil, errorURI: errorURI))</VAST>"
    }

    private func pod() -> String {
        let first = ad(id: "a", sequence: 1, skipOffset: "00:00:02", errorURI: true)
        let second = ad(id: "b", sequence: 2, skipOffset: nil, errorURI: true)
        return "<VAST version=\"4.3\">\(first)\(second)</VAST>"
    }

    /// A 20s ad pointing at a creative that really decodes.
    private func ad(id: String, sequence: Int?, skipOffset: String?, errorURI: Bool) -> String {
        let order = sequence.map { " sequence=\"\($0)\"" } ?? ""
        let skip = skipOffset.map { " skipoffset=\"\($0)\"" } ?? ""
        let error = errorURI ? "<Error><![CDATA[https://ads.test/\(id)/error?code=[ERRORCODE]]]></Error>" : ""
        return """
        <Ad id="\(id)"\(order)><InLine>
          <AdSystem>test</AdSystem>
          \(error)
          <Impression><![CDATA[https://ads.test/\(id)/impression]]></Impression>
          <Creatives><Creative><Linear\(skip)>
            <Duration>00:00:20</Duration>
            <TrackingEvents>
              <Tracking event="start"><![CDATA[https://ads.test/\(id)/start]]></Tracking>
              <Tracking event="complete"><![CDATA[https://ads.test/\(id)/complete]]></Tracking>
              <Tracking event="pause"><![CDATA[https://ads.test/\(id)/pause]]></Tracking>
              <Tracking event="resume"><![CDATA[https://ads.test/\(id)/resume]]></Tracking>
              <Tracking event="skip"><![CDATA[https://ads.test/\(id)/skip]]></Tracking>
            </TrackingEvents>
            <MediaFiles>
              <MediaFile delivery="progressive" type="video/mp4"><![CDATA[\(creative.absoluteString)]]></MediaFile>
            </MediaFiles>
          </Linear></Creative></Creatives>
        </InLine></Ad>
        """
    }

    private static func tick(_ time: TimeInterval, wall: TimeInterval) -> VASTTick {
        VASTTick(adTime: time, duration: 20, rate: 1, wallClock: wall)
    }

    /// Silent PCM, which AVFoundation plays with no encoder involved — as in
    /// `VASTPlaybackLoopTests`, and long enough that its own end never arrives
    /// during a scripted run.
    private static func playableFile(seconds: Int) throws -> URL {
        let sampleRate = 8_000, channels = 1, bits = 16
        let blockAlign = channels * bits / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = byteRate * seconds

        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func u16(_ value: Int) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bits)
        ascii("data"); u32(dataSize)
        data.append(Data(count: dataSize))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vast-end-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }
}

// MARK: - Doubles

/// What the host heard: failures and how each ad finished.
@MainActor
private final class EndRecorder: iVASTAdSessionDelegate {
    var events: [String] = []

    func session(_ session: VASTAdSession, didFail error: VASTError, for ad: VASTAd?) {
        events.append("failed \(ad?.id ?? "nil") \(error.rawValue)")
    }

    func session(_ session: VASTAdSession, didFinish ad: VASTAd, outcome: VASTAdSession.Outcome) {
        switch outcome {
        case .completed: events.append("finished \(ad.id) completed")
        case .skipped: events.append("finished \(ad.id) skipped")
        case .failed(let error): events.append("finished \(ad.id) failed \(error.rawValue)")
        }
    }
}

/// What the pod test's clock hands over, and reads back afterwards.
@MainActor
private final class BoundaryProbe {
    var session: VASTAdSession?
    var observed = Observed()
    var failure: String?
}

/// The second creative, read a few ticks after the app came back.
private struct Observed {
    var rate: Float?
    var pausedByUser: Bool?
    var state: VASTAdSession.State?
}

/// One script per creative. The session asks an injected clock for ticks once per
/// ad in a pod, so each `ticks()` starts the next script, and `stop()` ends only
/// the current one.
private final class PodClock: iVASTClock, @unchecked Sendable {

    private let scripts: [[VASTTick]]
    private let beforeTick: (@MainActor (Int, Int) -> Void)?
    private var ad = -1
    private var index = 0
    private var stopped = false

    init(_ scripts: [[VASTTick]], beforeTick: (@MainActor (Int, Int) -> Void)? = nil) {
        self.scripts = scripts
        self.beforeTick = beforeTick
    }

    func ticks() -> AsyncStream<VASTTick> {
        let ad = MainActor.assumeIsolated { begin() }
        return AsyncStream(unfolding: { [weak self] in
            await MainActor.run { self?.next(for: ad) }
        })
    }

    func stop() {
        MainActor.assumeIsolated { stopped = true }
    }

    @MainActor
    private func begin() -> Int {
        ad += 1
        index = 0
        stopped = false
        return ad
    }

    /// Produced on demand, so `beforeTick` for tick *n* runs only after the
    /// session has finished acting on tick *n-1*.
    @MainActor
    private func next(for ad: Int) -> VASTTick? {
        guard ad == self.ad, !stopped, ad < scripts.count, index < scripts[ad].count else { return nil }
        let tick = scripts[ad][index]
        beforeTick?(ad, index)
        index += 1
        return tick
    }
}

private struct InlineLoader: iVASTResourceLoader {
    let xml: String
    func loadVAST(from url: URL, timeout: TimeInterval) async throws -> String { xml }
}

private struct DiscardingTransport: iVASTBeaconTransport {
    func fire(_ beacons: [VASTBeacon]) async {}
}
