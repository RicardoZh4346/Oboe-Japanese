@preconcurrency import AVFoundation
import Foundation
import OboeDomain

@MainActor
public final class SystemJapaneseSpeechService: NSObject, SpeechService {
    /// A live playback request together with its public ID and event sink.
    /// Cleared when the request reaches a terminal event so `stop()` never
    /// reports `.cancelled` for an already-finished playback.
    private struct ActiveRequest {
        let request: SpeechPlaybackRequest
        let requestID: UUID
        let onEvent: SpeechEventHandler
    }

    private let voiceProvider: () -> AVSpeechSynthesisVoice?
    private let playback: JapaneseSpeechPlaybackQueue
    private var cachedVoice: AVSpeechSynthesisVoice?
    private var hasResolvedVoice = false
    private var currentRequest: ActiveRequest?
    private var observers: [NSObjectProtocol] = []

    public override convenience init() {
        self.init(voiceProvider: Self.japaneseVoice)
    }

    init(
        voiceProvider: @escaping () -> AVSpeechSynthesisVoice?,
        playbackFactory: @escaping @Sendable (DispatchQueue) -> any JapaneseSpeechPlaybackBackend = {
            SystemSpeechPlaybackBackend(queue: $0)
        }
    ) {
        self.voiceProvider = voiceProvider
        playback = JapaneseSpeechPlaybackQueue(factory: playbackFactory)
        super.init()
        observeAudioChanges()
    }

    deinit {
        currentRequest?.request.cancel()
        playback.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public var availability: JapaneseSpeechAvailability {
        guard let voice = resolvedVoice() else { return .unavailable }
        return .available(voiceName: voice.name)
    }

    @discardableResult
    public func speakWithEvents(
        _ texts: [String],
        onEvent: @escaping SpeechEventHandler
    ) -> UUID {
        let requestID = UUID()
        let speakableTexts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !speakableTexts.isEmpty else {
            onEvent(.failed(requestID: requestID, error: .noSpeakableText))
            return requestID
        }
        guard let voice = resolvedVoice() else {
            onEvent(.failed(requestID: requestID, error: .voiceUnavailable))
            return requestID
        }

        cancelActiveRequest()
        let request = SpeechPlaybackRequest()
        currentRequest = ActiveRequest(request: request, requestID: requestID, onEvent: onEvent)
        playback.speak(
            speakableTexts,
            voiceIdentifier: voice.identifier,
            request: request
        ) { [weak self] queueEvent in
            Task { @MainActor in
                guard let self, let active = self.currentRequest,
                      active.request === request, !request.isCancelled else { return }
                switch queueEvent {
                case .started:
                    onEvent(.started(requestID: requestID))
                case .completed:
                    self.currentRequest = nil
                    onEvent(.completed(requestID: requestID))
                case let .failed(error):
                    self.currentRequest = nil
                    onEvent(.failed(requestID: requestID, error: error))
                }
            }
        }
        return requestID
    }

    public func stop() {
        cancelActiveRequest()
        playback.stop()
    }

    /// Cancels the in-flight request (if any) and reports `.cancelled` on its
    /// own event sink — superseding requests, interruptions and page exits all
    /// funnel through here so a cancelled playback is never mistaken for a
    /// failure or a completion.
    private func cancelActiveRequest() {
        guard let active = currentRequest else { return }
        currentRequest = nil
        active.request.cancel()
        active.onEvent(.cancelled(requestID: active.requestID))
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if !hasResolvedVoice {
            cachedVoice = voiceProvider()
            hasResolvedVoice = true
        }
        return cachedVoice
    }

    private static func japaneseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return voices.first { $0.language.caseInsensitiveCompare("ja-JP") == .orderedSame }
            ?? voices.first { $0.language.lowercased().hasPrefix("ja") }
    }

    private func observeAudioChanges() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cachedVoice = nil
                    self?.hasResolvedVoice = false
                }
            }
        )
        #if os(iOS)
        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
                MainActor.assumeIsolated { self?.stop() }
            }
        )
        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
                else { return }
                MainActor.assumeIsolated { self?.stop() }
            }
        )
        #endif
    }
}

final class SpeechPlaybackRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

final class SpeechUtteranceTracker: @unchecked Sendable {
    struct Completion: Sendable {
        let identifier: ObjectIdentifier
        let token: UUID
    }

    private let lock = NSLock()
    private var tokens: [ObjectIdentifier: UUID] = [:]

    func insert(_ identifier: ObjectIdentifier) {
        lock.withLock { tokens[identifier] = UUID() }
    }

    func completion(for identifier: ObjectIdentifier) -> Completion? {
        lock.withLock {
            tokens[identifier].map { Completion(identifier: identifier, token: $0) }
        }
    }

    func finish(_ completion: Completion) -> Bool {
        lock.withLock {
            guard tokens[completion.identifier] == completion.token else { return false }
            tokens.removeValue(forKey: completion.identifier)
            return tokens.isEmpty
        }
    }

    func clear() -> Bool {
        lock.withLock {
            let hadUtterances = !tokens.isEmpty
            tokens.removeAll()
            return hadUtterances
        }
    }
}

/// Queue-side playback lifecycle forwarded to the service. `started` means
/// the backend accepted the utterances (engine began), `completed` means
/// every utterance of this request finished.
enum SpeechQueueEvent: Sendable {
    case started
    case completed
    case failed(JapaneseSpeechError)
}

protocol JapaneseSpeechPlaybackBackend: AnyObject {
    func speak(
        _ texts: [String],
        voiceIdentifier: String,
        request: SpeechPlaybackRequest,
        onFinish: @escaping @Sendable () -> Void
    ) throws
    func stop()
}

private final class JapaneseSpeechPlaybackQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.example.Oboe.speech", qos: .userInitiated)
    private let factory: @Sendable (DispatchQueue) -> any JapaneseSpeechPlaybackBackend
    private var backend: (any JapaneseSpeechPlaybackBackend)?

    init(factory: @escaping @Sendable (DispatchQueue) -> any JapaneseSpeechPlaybackBackend) {
        self.factory = factory
    }

    func speak(
        _ texts: [String],
        voiceIdentifier: String,
        request: SpeechPlaybackRequest,
        onEvent: @escaping @Sendable (SpeechQueueEvent) -> Void
    ) {
        queue.async {
            guard !request.isCancelled else { return }
            do {
                if self.backend == nil {
                    self.backend = self.factory(self.queue)
                }
                try self.backend?.speak(
                    texts,
                    voiceIdentifier: voiceIdentifier,
                    request: request
                ) {
                    // Always re-hop so `completed` can never precede
                    // `started`, even if a backend finishes synchronously.
                    self.queue.async {
                        guard !request.isCancelled else { return }
                        onEvent(.completed)
                    }
                }
                if !request.isCancelled {
                    onEvent(.started)
                }
            } catch {
                self.backend?.stop()
                if !request.isCancelled {
                    onEvent(.failed(error as? JapaneseSpeechError ?? .audioSessionUnavailable))
                }
            }
        }
    }

    func stop() {
        queue.async { self.backend?.stop() }
    }
}

private final class SystemSpeechPlaybackBackend: NSObject, JapaneseSpeechPlaybackBackend,
    AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private var synthesizer: AVSpeechSynthesizer?
    private var voice: AVSpeechSynthesisVoice?
    private var isAudioSessionActive = false
    private let activeUtterances = SpeechUtteranceTracker()
    /// T18: fires once every utterance of the current request finishes.
    /// Cleared on stop/replacement so a cancelled request never reports
    /// completion.
    private var finishHandler: (@Sendable () -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    func speak(
        _ texts: [String],
        voiceIdentifier: String,
        request: SpeechPlaybackRequest,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !request.isCancelled else { return }
        stopUtterances()
        finishHandler = nil
        if synthesizer == nil {
            synthesizer = AVSpeechSynthesizer()
            synthesizer?.delegate = self
        }
        if voice?.identifier != voiceIdentifier {
            voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        }
        guard let voice else { throw JapaneseSpeechError.voiceUnavailable }
        guard !request.isCancelled else { return }
        #if os(iOS)
        if !isAudioSessionActive {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            guard !request.isCancelled else { return }
            try session.setActive(true)
            isAudioSessionActive = true
        }
        #endif
        finishHandler = onFinish
        guard !texts.isEmpty else {
            onFinish()
            finishHandler = nil
            return
        }
        for text in texts {
            guard !request.isCancelled else {
                stop()
                return
            }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            activeUtterances.insert(ObjectIdentifier(utterance))
            synthesizer?.speak(utterance)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        finishHandler = nil
        stopUtterances()
        deactivateAudioSession()
    }

    private func stopUtterances() {
        let hadUtterances = activeUtterances.clear()
        if let synthesizer, hadUtterances || synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        guard isAudioSessionActive else { return }
        if (try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )) != nil {
            isAudioSessionActive = false
        }
        #endif
    }

    private func didEnd(_ utterance: AVSpeechUtterance) {
        guard let completion = activeUtterances.completion(for: ObjectIdentifier(utterance))
        else { return }
        queue.async { [weak self] in
            guard let self, self.activeUtterances.finish(completion) else { return }
            self.deactivateAudioSession()
            let onFinish = self.finishHandler
            self.finishHandler = nil
            onFinish?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        didEnd(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        didEnd(utterance)
    }
}
