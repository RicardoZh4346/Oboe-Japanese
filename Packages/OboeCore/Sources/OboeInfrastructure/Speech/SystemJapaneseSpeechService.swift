@preconcurrency import AVFoundation
import Foundation
import OboeDomain

@MainActor
public final class SystemJapaneseSpeechService: NSObject, SpeechService {
    private let synthesizer: AVSpeechSynthesizer
    private var activeUtteranceCount = 0
    private var observers: [NSObjectProtocol] = []

    public override init() {
        synthesizer = AVSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
        observeAudioChanges()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public var availability: JapaneseSpeechAvailability {
        guard let voice = Self.japaneseVoice() else { return .unavailable }
        return .available(voiceName: voice.name)
    }

    public func speak(_ texts: [String]) throws {
        let speakableTexts = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !speakableTexts.isEmpty else {
            throw JapaneseSpeechError.noSpeakableText
        }
        guard let voice = Self.japaneseVoice() else {
            throw JapaneseSpeechError.voiceUnavailable
        }

        stop()
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            throw JapaneseSpeechError.audioSessionUnavailable
        }
        #endif

        activeUtteranceCount = speakableTexts.count
        for text in speakableTexts {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        activeUtteranceCount = 0
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        deactivateAudioSession()
    }

    private static func japaneseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return voices.first { $0.language.caseInsensitiveCompare("ja-JP") == .orderedSame }
            ?? voices.first { $0.language.lowercased().hasPrefix("ja") }
    }

    private func observeAudioChanges() {
        #if os(iOS)
        let center = NotificationCenter.default
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

    private func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}

extension SystemJapaneseSpeechService: @preconcurrency AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        activeUtteranceCount = max(0, activeUtteranceCount - 1)
        if activeUtteranceCount == 0 {
            deactivateAudioSession()
        }
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        activeUtteranceCount = 0
        deactivateAudioSession()
    }
}
