//
//  VASTBeaconDeliveryTests.swift
//  VASTKitTests
//

import XCTest
@testable import VASTCore
@testable import VASTKit

/// A tracking request is the only record that an ad was shown. These check that
/// one is not lost when it fails — the case that used to happen most, and
/// silently.
final class VASTBeaconDeliveryTests: XCTestCase {

    private var queue: VASTBeaconQueue!

    override func setUp() async throws {
        try await super.setUp()
        // A file of this test's own: the shared queue belongs to the app, and a
        // test must not inherit or destroy what the last run left there.
        queue = VASTBeaconQueue(fileName: "vast-test-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        await queue.removeAll()
        queue = nil
        try await super.tearDown()
    }

    // MARK: - The queue

    func testAnUndeliveredBeaconIsKept() async {
        await queue.enqueue([Self.url("impression")])
        let count = await queue.count()
        XCTAssertEqual(count, 1)
    }

    /// Taken rather than copied. Draining and keeping would send every beacon
    /// again on every flush for as long as one of them kept failing.
    func testDrainingEmptiesTheQueue() async {
        await queue.enqueue([Self.url("a"), Self.url("b")])

        let drained = await queue.drain()
        XCTAssertEqual(drained.count, 2)

        let remaining = await queue.count()
        XCTAssertEqual(remaining, 0, "a drained beacon would be sent twice")
    }

    /// The whole point: a beacon queued by one launch is still there for the next.
    func testTheQueueSurvivesTheProcessThatWroteIt() async {
        let name = "vast-test-\(UUID().uuidString).json"
        let first = VASTBeaconQueue(fileName: name)
        await first.enqueue([Self.url("impression")])

        // A different instance reading the same file is as close as a test gets
        // to a relaunch.
        let second = VASTBeaconQueue(fileName: name)
        let drained = await second.drain()
        XCTAssertEqual(drained.map(\.lastPathComponent), ["impression"])

        await second.removeAll()
    }

    func testTheQueueIsCappedOldestOutFirst() async {
        let urls = (0..<(VASTBeaconQueue.capacity + 20)).map { Self.url("beacon\($0)") }
        await queue.enqueue(urls)

        let drained = await queue.drain()
        XCTAssertEqual(drained.count, VASTBeaconQueue.capacity)
        XCTAssertEqual(
            drained.last?.lastPathComponent, "beacon\(VASTBeaconQueue.capacity + 19)",
            "the newest beacons are the ones worth keeping"
        )
    }

    // MARK: - The transport

    func testABeaconThatFailsIsQueuedRatherThanLost() async {
        FailingProtocol.reset(failing: true)
        let transport = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )

        await transport.fire([Self.beacon("impression")])

        let held = await queue.count()
        XCTAssertEqual(held, 1, "the impression that paid for the break was dropped")
    }

    func testABeaconThatLandsIsNotQueued() async {
        FailingProtocol.reset(failing: false)
        let transport = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )

        await transport.fire([Self.beacon("impression")])

        let held = await queue.count()
        XCTAssertEqual(held, 0)
    }

    /// Retries ride along with the next flush rather than on a timer of their own,
    /// so they happen when the network is known to be working.
    func testTheNextFlushCarriesTheEarlierFailure() async {
        FailingProtocol.reset(failing: true)
        let failing = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )
        await failing.fire([Self.beacon("impression")])
        let heldBefore = await queue.count()
        XCTAssertEqual(heldBefore, 1)

        FailingProtocol.reset(failing: false)
        let working = VASTURLSessionTransport(
            session: Self.stubbedSession(), maxAttempts: 1, queue: queue
        )
        await working.fire([Self.beacon("start")])

        XCTAssertEqual(
            Set(FailingProtocol.requested), ["impression", "start"],
            "the earlier failure did not ride along"
        )
        let heldAfter = await queue.count()
        XCTAssertEqual(heldAfter, 0)
    }

    // MARK: - The retry ration

    /// Found by hand in a browser, in the web port, and the same here: with a
    /// tracker that never answers, every new beacon sent the whole backlog again,
    /// twice, so one ad produced dozens of requests per tracker. An ad blocker or
    /// a DNS filter makes a tracker like that of every tracker it knows.
    func testTheBacklogIsResentAtMostOncePerIntervalHoweverManyBeaconsFire() async {
        FailingProtocol.reset(failing: true)
        let transport = VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 2, queue: queue)

        for event in ["impression", "start", "firstQuartile", "midpoint", "thirdQuartile", "complete"] {
            await transport.fire([Self.beacon(event)])
        }

        XCTAssertEqual(
            FailingProtocol.requested.filter { $0 == "impression" }.count, 3,
            "its own two attempts, then one retry within the interval"
        )
        XCTAssertEqual(FailingProtocol.requested.count, 13, "six beacons, two attempts each, and one retry batch")
        let held = await queue.count()
        XCTAssertEqual(held, 6)
    }

    func testAQueuedBeaconGetsOneAttemptPerBatchWhereAFirstSendGetsTwo() async {
        await queue.enqueue([Self.url("old")])
        FailingProtocol.reset(failing: true)

        await VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 2, queue: queue)
            .fire([Self.beacon("new")])

        XCTAssertEqual(FailingProtocol.requested.sorted(), ["new", "new", "old"])
    }

    /// A host builds a session per break, and the session a transport: the
    /// ration has to be the process's, not theirs.
    func testEveryTransportInTheProcessSharesOneRation() async {
        await queue.enqueue([Self.url("old")])
        FailingProtocol.reset(failing: true)

        for _ in 0..<5 {
            await VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 2, queue: queue)
                .fire([Self.beacon("new")])
        }

        XCTAssertEqual(FailingProtocol.requested.filter { $0 == "old" }.count, 1)
    }

    func testARetryWaitsForTheIntervalToPass() async {
        let clock = TestClock()
        let rationed = VASTBeaconQueue(fileName: "vast-test-\(UUID().uuidString).json", now: clock.now)
        await rationed.enqueue([Self.url("impression")])
        FailingProtocol.reset(failing: true)
        let transport = VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 2, queue: rationed)

        await transport.fire([Self.beacon("a")])
        await transport.fire([Self.beacon("b")])
        XCTAssertEqual(FailingProtocol.requested.filter { $0 == "impression" }.count, 1, "once per interval")

        clock.advance(VASTBeaconQueue.retryInterval)
        await transport.fire([Self.beacon("c")])
        XCTAssertEqual(FailingProtocol.requested.filter { $0 == "impression" }.count, 2)
        await rationed.removeAll()
    }

    /// The ration is measured on the wall clock, which can be set back; that must
    /// not stop retries until it catches up.
    func testAClockSetBackDoesNotHoldRetriesBack() async {
        let clock = TestClock()
        let rationed = VASTBeaconQueue(fileName: "vast-test-\(UUID().uuidString).json", now: clock.now)
        await rationed.enqueue([Self.url("impression")])
        FailingProtocol.reset(failing: true)
        let transport = VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 2, queue: rationed)

        await transport.fire([Self.beacon("a")])
        clock.advance(-60 * 60)
        await transport.fire([Self.beacon("b")])

        XCTAssertEqual(FailingProtocol.requested.filter { $0 == "impression" }.count, 2)
        await rationed.removeAll()
    }

    func testARetryBatchIsCappedOldestFirstAndTheRestStaysQueued() async {
        let clock = TestClock()
        let rationed = VASTBeaconQueue(fileName: "vast-test-\(UUID().uuidString).json", now: clock.now)
        for index in 0..<(VASTBeaconQueue.retryBatch + 10) {
            await rationed.enqueue([Self.url("b\(index)")])
            clock.advance(0.001)
        }
        FailingProtocol.reset(failing: false)

        await VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 1, queue: rationed)
            .fire([Self.beacon("new")])

        let retried = Set(FailingProtocol.requested).subtracting(["new"])
        XCTAssertEqual(retried, Set((0..<VASTBeaconQueue.retryBatch).map { "b\($0)" }))
        let held = await rationed.count()
        XCTAssertEqual(held, 10)
        await rationed.removeAll()
    }

    func testABeaconIsLetGoAfterMaxRetriesFailedBatchesWellBeforeItWouldAgeOut() async {
        let clock = TestClock()
        let rationed = VASTBeaconQueue(fileName: "vast-test-\(UUID().uuidString).json", now: clock.now)
        await rationed.enqueue([Self.url("blocked")])
        FailingProtocol.reset(failing: false)
        let transport = VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 2, queue: rationed)

        for _ in 0..<(VASTBeaconQueue.maxRetries + 2) {
            // Everything fails but the beacon that carries the retry, which lands.
            FailingProtocol.reset(failing: true, except: ["carrier"])
            await transport.fire([Self.beacon("carrier")])
            FailingProtocol.tally()
            clock.advance(VASTBeaconQueue.retryInterval)
        }

        XCTAssertEqual(FailingProtocol.total(of: "blocked"), VASTBeaconQueue.maxRetries)
        let held = await rationed.count()
        XCTAssertEqual(held, 0)
        await rationed.removeAll()
    }

    /// A file written before retries were counted has no `retries` key; it has to
    /// read the same, and a beacon that has only failed its first send is still
    /// stored that way.
    func testARetryCountIsStoredOnlyOnceABeaconHasFailedARetryAndOldFilesStillRead() async throws {
        let name = "vast-test-\(UUID().uuidString).json"
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name)
        let clock = TestClock()
        let recorded = clock.date.timeIntervalSinceReferenceDate
        let old = #"[{"url":"https:\/\/ads.test\/a","recorded":\#(recorded)}]"#
        try Data(old.utf8).write(to: file)

        let queue = VASTBeaconQueue(fileName: name, now: clock.now)
        let taken = await queue.takeForRetry()
        XCTAssertEqual(taken, [VASTBeaconQueue.Entry(url: Self.url("a"), recorded: clock.date, retries: nil)])

        await queue.requeue(taken.map { $0.failedAgain() })
        await queue.enqueue([Self.url("b")])
        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        await queue.removeAll()

        XCTAssertEqual(stored?.count, 2)
        XCTAssertEqual(stored?.first?["retries"] as? Int, 1)
        XCTAssertNil(stored?.last?["retries"], "a first failure is stored as it always was")
    }

    /// A retry that failed again used to be queued as new, so a beacon to a
    /// tracker that never answers was never older than its latest failure: it
    /// stayed for as long as the app kept sending beacons, with whatever consent
    /// string its URL carried.
    func testABeaconThatKeepsFailingAgesOutFromWhenItWasFirstRecorded() async {
        let clock = TestClock()
        let aging = VASTBeaconQueue(fileName: "vast-test-\(UUID().uuidString).json", now: clock.now)
        FailingProtocol.reset(failing: true)
        let transport = VASTURLSessionTransport(session: Self.stubbedSession(), maxAttempts: 1, queue: aging)

        await transport.fire([Self.beacon("blocked")])
        clock.advance(VASTBeaconQueue.maxAge - 60)
        await transport.fire([Self.beacon("start")])
        clock.advance(120)

        XCTAssertEqual(FailingProtocol.requested.filter { $0 == "blocked" }.count, 2, "the failure was not retried at all")
        let drained = await aging.drain()
        await aging.removeAll()
        XCTAssertEqual(
            drained.map(\.lastPathComponent), ["start"],
            "a URL that may carry a consent string outlived maxAge"
        )
    }

    /// A host that has its own counting can opt out; the default must not be that.
    func testRetentionIsOnByDefault() {
        let transport = VASTURLSessionTransport()
        XCTAssertNotNil(transport, "the default transport keeps what it cannot deliver")
    }

    // MARK: - Fixtures

    private static func url(_ path: String) -> URL {
        URL(string: "https://ads.test/\(path)")!
    }

    private static func beacon(_ path: String) -> VASTBeacon {
        VASTBeacon(kind: .impression, url: url(path), adID: "a")
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// MARK: - Time on demand

/// A wall clock the test moves, so "six hours later" is a line rather than a wait.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }

    var date: Date { lock.withLock { current } }
}

// MARK: - A network that fails on demand

/// Answers every request without touching a network, so "the beacon failed" is a
/// setting rather than a wait.
private final class FailingProtocol: URLProtocol {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var shouldFail = false
    nonisolated(unsafe) private static var answering: Set<String> = []
    nonisolated(unsafe) private static var seen: [String] = []
    nonisolated(unsafe) private static var tallied: [String] = []

    /// - Parameter except: paths that answer even while everything else fails.
    static func reset(failing: Bool, except: Set<String> = []) {
        lock.lock()
        shouldFail = failing
        answering = except
        seen = []
        lock.unlock()
    }

    /// Adds what was requested since the last reset to a count that survives resets.
    static func tally() {
        lock.lock()
        tallied += seen
        lock.unlock()
    }

    /// Requests for `path` across every tally, then starts the count again.
    static func total(of path: String) -> Int {
        lock.lock()
        defer { tallied = []; lock.unlock() }
        return tallied.filter { $0 == path }.count
    }

    static var requested: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let path = request.url?.lastPathComponent ?? ""
        Self.seen.append(path)
        let failing = Self.shouldFail && !Self.answering.contains(path)
        Self.lock.unlock()

        if failing {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
