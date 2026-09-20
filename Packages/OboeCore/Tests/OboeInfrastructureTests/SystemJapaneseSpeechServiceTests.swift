import AVFoundation
import OboeDomain
import XCTest
@testable import OboeInfrastructure

final class SystemJapaneseSpeechServiceTests: XCTestCase {
    @MainActor
    func testRepeatedAvailabilityReadsResolveMissingVoiceOnlyOnce() {
        var lookupCount = 0
        let service = SystemJapaneseSpeechService(voiceProvider: {
            lookupCount += 1
            return nil
        })

        for _ in 0..<20 {
            XCTAssertEqual(service.availability, .unavailable)
        }
        XCTAssertEqual(lookupCount, 1)
    }

    @MainActor
    func testVoiceChangesInvalidateCachedAvailability() throws {
        guard let installedVoice = AVSpeechSynthesisVoice(language: "ja-JP") else {
            throw XCTSkip("当前测试设备未安装日语语音")
        }
        var voice: AVSpeechSynthesisVoice?
        var lookupCount = 0
        let service = SystemJapaneseSpeechService(voiceProvider: {
            lookupCount += 1
            return voice
        })
        XCTAssertEqual(service.availability, .unavailable)
        voice = installedVoice
        NotificationCenter.default.post(
            name: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil
        )
        for _ in 0..<20 {
            XCTAssertEqual(service.availability, .available(voiceName: installedVoice.name))
        }
        XCTAssertEqual(lookupCount, 2)

        voice = nil
        NotificationCenter.default.post(
            name: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
            object: nil
        )
        XCTAssertEqual(service.availability, .unavailable)
        XCTAssertEqual(lookupCount, 3)
        var speechError: JapaneseSpeechError?
        service.speak(["日本語"]) { speechError = $0 }
        XCTAssertEqual(speechError, .voiceUnavailable)
        XCTAssertEqual(lookupCount, 3)
    }

    @MainActor
    func testPlaybackAndStopDoNotBlockMainThread() async throws {
        let started = expectation(description: "Playback started")
        let stopped = expectation(description: "Playback stopped")
        let backend = SpeechPlaybackProbe(
            delay: 0.2,
            onStart: { _ in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
            },
            onStop: {
                XCTAssertFalse(Thread.isMainThread)
                stopped.fulfill()
            }
        )
        let voice = try japaneseVoice()
        let service = SystemJapaneseSpeechService(
            voiceProvider: { voice },
            playbackFactory: { _ in
                XCTAssertFalse(Thread.isMainThread)
                return backend
            }
        )
        let start = Date()
        service.speak(["日本語"]) { error in XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.08)
        await fulfillment(of: [started], timeout: 3)

        let stop = Date()
        service.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stop), 0.08)
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testStopCancelsSpeechWhileAudioIsPreparing() async throws {
        let preparing = expectation(description: "Preparing audio")
        let stopped = expectation(description: "Stop processed")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let backend = SpeechPlaybackProbe(
            onStart: { _ in
                preparing.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            },
            onStop: { stopped.fulfill() }
        )
        let service = try makeService(backend: backend)
        service.speak(["old card"]) { error in XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [preparing], timeout: 3)
        service.stop()
        gate.signal()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(backend.spokenTexts, [])
    }

    @MainActor
    func testNewSpeechReplacesPendingRequestAndSkipsQueuedStaleRequest() async throws {
        let preparing = expectation(description: "Preparing first request")
        let finished = expectation(description: "Latest request started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let backend = SpeechPlaybackProbe(
            onStart: { texts in
                if texts == ["first"] {
                    preparing.fulfill()
                    XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
                }
            },
            onFinish: { texts in
                if texts == ["latest"] { finished.fulfill() }
            }
        )
        let service = try makeService(backend: backend)
        service.speak(["first"]) { error in XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [preparing], timeout: 3)
        service.speak(["stale"]) { error in XCTFail("Unexpected error: \(error)") }
        service.speak(["latest"]) { error in XCTFail("Unexpected error: \(error)") }
        gate.signal()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(backend.startedTexts, [["first"], ["latest"]])
        XCTAssertEqual(backend.spokenTexts, [["latest"]])
    }

    @MainActor
    func testAudioFailureIsDeliveredOnMainActor() async throws {
        let failed = expectation(description: "Audio error delivered")
        let backend = SpeechPlaybackProbe(error: .audioSessionUnavailable)
        let service = try makeService(backend: backend)
        service.speak(["日本語"]) { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(error, .audioSessionUnavailable)
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 3)
    }

    @MainActor
    func testCancelledRequestDoesNotReportLateAudioFailure() async throws {
        let preparing = expectation(description: "Preparing audio")
        let failed = expectation(description: "No stale error")
        failed.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let backend = SpeechPlaybackProbe(
            error: .audioSessionUnavailable,
            onStart: { _ in
                preparing.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            }
        )
        let service = try makeService(backend: backend)
        service.speak(["old card"]) { _ in failed.fulfill() }
        await fulfillment(of: [preparing], timeout: 3)
        service.stop()
        gate.signal()
        await fulfillment(of: [failed], timeout: 0.2)
    }

    @MainActor
    func testEmptySpeechDoesNotCreatePlaybackBackend() {
        let service = SystemJapaneseSpeechService(
            voiceProvider: {
                XCTFail("Empty speech should not resolve a voice")
                return nil
            },
            playbackFactory: { _ in
                XCTFail("Empty speech should not create a playback backend")
                return SpeechPlaybackProbe()
            }
        )
        var error: JapaneseSpeechError?
        service.speak(["", " \n "]) { error = $0 }
        XCTAssertEqual(error, .noSpeakableText)
    }

    func testLateUtteranceCallbacksCannotEndReplacementPlayback() throws {
        let tracker = SpeechUtteranceTracker()
        let utterance = NSObject()
        let identifier = ObjectIdentifier(utterance)
        tracker.insert(identifier)
        let oldCompletion = try XCTUnwrap(tracker.completion(for: identifier))
        XCTAssertTrue(tracker.clear())
        tracker.insert(identifier)
        let newCompletion = try XCTUnwrap(tracker.completion(for: identifier))

        XCTAssertFalse(tracker.finish(oldCompletion))
        XCTAssertNotNil(tracker.completion(for: identifier))
        XCTAssertTrue(tracker.finish(newCompletion))
        XCTAssertFalse(tracker.finish(newCompletion))
    }

    func testWordAndExampleOnlyEndAudioAfterBothFinish() throws {
        let tracker = SpeechUtteranceTracker()
        let word = NSObject()
        let example = NSObject()
        tracker.insert(ObjectIdentifier(word))
        tracker.insert(ObjectIdentifier(example))
        let wordCompletion = try XCTUnwrap(tracker.completion(for: ObjectIdentifier(word)))
        let exampleCompletion = try XCTUnwrap(tracker.completion(for: ObjectIdentifier(example)))
        XCTAssertFalse(tracker.finish(wordCompletion))
        XCTAssertFalse(tracker.finish(wordCompletion))
        XCTAssertTrue(tracker.finish(exampleCompletion))
        XCTAssertFalse(tracker.clear())
    }

    // MARK: - T18 playback events (设计 §8.3)

    @MainActor
    func testPlaybackEventsCarryRequestIDAndComplete() async throws {
        let completed = expectation(description: "Playback completed")
        let backend = SpeechPlaybackProbe()
        let service = try makeService(backend: backend)
        var events: [SpeechPlaybackEvent] = []
        var requestID: UUID?
        requestID = service.speakWithEvents(["日本語"]) { event in
            events.append(event)
            XCTAssertEqual(event.requestID, requestID)
            if case .completed = event { completed.fulfill() }
        }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(events, [.started(requestID: requestID!), .completed(requestID: requestID!)])
    }

    @MainActor
    func testFailureEventCarriesRequestID() async throws {
        let failed = expectation(description: "Playback failed")
        let service = try makeService(backend: SpeechPlaybackProbe(error: .audioSessionUnavailable))
        var requestID: UUID?
        requestID = service.speakWithEvents(["日本語"]) { event in
            XCTAssertEqual(event.requestID, requestID)
            if case .failed = event { failed.fulfill() }
        }
        await fulfillment(of: [failed], timeout: 3)
    }

    @MainActor
    func testPreFlightFailuresEmitFailedWithRequestID() async throws {
        // Pre-flight failures fire synchronously — the requestID carried by
        // the event must equal the returned ID.
        let noVoice = SystemJapaneseSpeechService(voiceProvider: { nil })
        var emptyEvent: SpeechPlaybackEvent?
        let emptyID = noVoice.speakWithEvents(["  "]) { emptyEvent = $0 }
        XCTAssertEqual(emptyEvent, .failed(requestID: emptyID, error: .noSpeakableText))
        var voiceEvent: SpeechPlaybackEvent?
        let voiceID = noVoice.speakWithEvents(["日本語"]) { voiceEvent = $0 }
        XCTAssertEqual(voiceEvent, .failed(requestID: voiceID, error: .voiceUnavailable))
    }

    @MainActor
    func testStopEmitsCancelledForInFlightRequest() async throws {
        let started = expectation(description: "Playback started")
        let cancelled = expectation(description: "Playback cancelled")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let backend = SpeechPlaybackProbe(
            onStart: { _ in
                started.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            }
        )
        let service = try makeService(backend: backend)
        var events: [SpeechPlaybackEvent] = []
        var requestID: UUID?
        requestID = service.speakWithEvents(["日本語"]) { event in
            events.append(event)
            if case .cancelled = event { cancelled.fulfill() }
        }
        await fulfillment(of: [started], timeout: 3)
        service.stop()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(events.last, .cancelled(requestID: requestID!))
    }

    @MainActor
    func testNewRequestCancelsInFlightRequestWithItsOwnID() async throws {
        let firstStarted = expectation(description: "First started")
        let secondDone = expectation(description: "Second completed")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let backend = SpeechPlaybackProbe(
            onStart: { texts in
                if texts == ["first"] {
                    firstStarted.fulfill()
                    XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
                }
            }
        )
        let service = try makeService(backend: backend)
        var firstEvents: [SpeechPlaybackEvent] = []
        let firstID = service.speakWithEvents(["first"]) { event in
            firstEvents.append(event)
        }
        await fulfillment(of: [firstStarted], timeout: 3)
        var secondID: UUID?
        secondID = service.speakWithEvents(["second"]) { event in
            XCTAssertEqual(event.requestID, secondID)
            if case .completed = event { secondDone.fulfill() }
        }
        gate.signal()
        await fulfillment(of: [secondDone], timeout: 3)
        // The superseded request was cancelled while still in flight and
        // must never reach a terminal event.
        XCTAssertEqual(firstEvents, [.cancelled(requestID: firstID)])
    }

    @MainActor
    func testCompletedRequestEmitsNoCancelledOnStop() async throws {
        let completed = expectation(description: "Playback completed")
        let service = try makeService(backend: SpeechPlaybackProbe())
        let lateEvent = expectation(description: "No post-completion event")
        lateEvent.isInverted = true
        service.speakWithEvents(["日本語"]) { event in
            switch event {
            case .completed: completed.fulfill()
            case .cancelled, .failed: lateEvent.fulfill()
            case .started: break
            }
        }
        await fulfillment(of: [completed], timeout: 3)
        service.stop()
        await fulfillment(of: [lateEvent], timeout: 0.2)
    }

    @MainActor
    func testCancelledRequestReportsNoLateCompletion() async throws {
        let started = expectation(description: "Playback started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let backend = SpeechPlaybackProbe(
            onStart: { _ in
                started.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            }
        )
        let service = try makeService(backend: backend)
        let lateEvent = expectation(description: "No late event")
        lateEvent.isInverted = true
        var sawCancelled = false
        service.speakWithEvents(["日本語"]) { event in
            switch event {
            case .cancelled:
                sawCancelled = true
            case .completed, .failed:
                lateEvent.fulfill()
            case .started:
                break
            }
        }
        await fulfillment(of: [started], timeout: 3)
        service.stop()
        gate.signal()
        await fulfillment(of: [lateEvent], timeout: 0.5)
        XCTAssertTrue(sawCancelled)
    }

    @MainActor
    private func japaneseVoice() throws -> AVSpeechSynthesisVoice {
        guard let voice = AVSpeechSynthesisVoice(language: "ja-JP") else {
            throw XCTSkip("当前测试设备未安装日语语音")
        }
        return voice
    }

    @MainActor
    private func makeService(backend: SpeechPlaybackProbe) throws -> SystemJapaneseSpeechService {
        let voice = try japaneseVoice()
        return SystemJapaneseSpeechService(
            voiceProvider: { voice },
            playbackFactory: { _ in backend }
        )
    }

    @MainActor
    func testAvailabilityLookupPerformance() {
        let service = SystemJapaneseSpeechService()
        _ = service.availability
        measure {
            for _ in 0..<20 {
                _ = service.availability
            }
        }
    }
}

private final class SpeechPlaybackProbe: JapaneseSpeechPlaybackBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let error: JapaneseSpeechError?
    private let onStart: @Sendable ([String]) -> Void
    private let onFinish: @Sendable ([String]) -> Void
    private let onStop: @Sendable () -> Void
    private var started: [[String]] = []
    private var spoken: [[String]] = []
    private var didNotifyStop = false

    var startedTexts: [[String]] { lock.withLock { started } }
    var spokenTexts: [[String]] { lock.withLock { spoken } }

    init(
        delay: TimeInterval = 0,
        error: JapaneseSpeechError? = nil,
        onStart: @escaping @Sendable ([String]) -> Void = { _ in },
        onFinish: @escaping @Sendable ([String]) -> Void = { _ in },
        onStop: @escaping @Sendable () -> Void = {}
    ) {
        self.delay = delay
        self.error = error
        self.onStart = onStart
        self.onFinish = onFinish
        self.onStop = onStop
    }

    func speak(
        _ texts: [String],
        voiceIdentifier: String,
        request: SpeechPlaybackRequest,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        lock.withLock { started.append(texts) }
        onStart(texts)
        defer { self.onFinish(texts) }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let error { throw error }
        if !request.isCancelled {
            lock.withLock { spoken.append(texts) }
            onFinish()
        }
    }

    func stop() {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let shouldNotify = lock.withLock {
            let shouldNotify = !didNotifyStop
            didNotifyStop = true
            return shouldNotify
        }
        if shouldNotify { onStop() }
    }
}
