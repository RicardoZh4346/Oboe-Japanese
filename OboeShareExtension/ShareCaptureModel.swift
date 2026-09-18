import Foundation
import Observation
import OboeSharedCapture
import UniformTypeIdentifiers

@Observable
@MainActor
final class ShareCaptureModel {
    enum Phase: Equatable {
        case loading
        case ready
        case urlOnly([String])
        case empty
    }

    private(set) var phase: Phase = .loading
    private(set) var candidates: [SharedTextCandidate] = []
    var selectedCandidateIndex = 0 {
        didSet { applySelection() }
    }
    var draftText = ""
    private(set) var sourceURL: String?
    private(set) var isSaving = false
    var saveErrorMessage: String?

    /// One user confirmation produces one captureID; retries of the same
    /// confirmation reuse it — generated once per sheet, not per attempt.
    private let captureID = UUID()
    private let store: (any CaptureQueueStoring)?

    /// When the shared container cannot be resolved, this carries the
    /// signing mismatch (requested group vs profile-allowed groups) so a
    /// self-signed install can be diagnosed on-device.
    private(set) var signingDiagnostics: String?

    init(store: (any CaptureQueueStoring)? = AppGroupCaptureStore()) {
        self.store = store
        if store == nil {
            signingDiagnostics = SigningDiagnostics.appGroupSummary(
                requestedGroup: CaptureQueueLayout.appGroupIdentifier
            )
        }
    }

    var characterCount: Int { draftText.count }
    var isOverLimit: Bool {
        characterCount > CaptureEnvelopeFormat.maximumTextCharacters
    }
    var canSave: Bool {
        !isSaving && characterCount > 0 && !isOverLimit && store != nil
    }

    func load(items: [NSExtensionItem]) {
        guard phase == .loading else { return }
        // NSItemProvider isn't Sendable; the array is produced here and
        // consumed exactly once by the extraction task — box it to cross
        // the actor boundary.
        let box = ProvidersBox(items.flatMap { $0.attachments ?? [] })
        Task {
            let result = await SharedTextExtractor.extract(from: box.providers)
            apply(result)
        }
    }

    private func apply(_ result: ShareExtractionResult) {
        switch result {
        case .candidates(let found):
            candidates = found
            selectedCandidateIndex = 0
            applySelection()
            phase = .ready
        case .urlOnly(let urls):
            phase = .urlOnly(urls)
        case .empty:
            phase = .empty
        }
    }

    private func applySelection() {
        guard candidates.indices.contains(selectedCandidateIndex) else { return }
        let candidate = candidates[selectedCandidateIndex]
        draftText = candidate.text
        sourceURL = candidate.sourceURL
    }

    func save(action: CaptureRequestedAction) {
        guard canSave else { return }
        guard let store else {
            // The shared container must exist to hand the capture off —
            // never report success when it doesn't.
            saveErrorMessage = "共享存储不可用，请确认 App 已正确安装"
            return
        }
        isSaving = true
        saveErrorMessage = nil
        let envelope = CaptureEnvelope(
            captureID: captureID,
            text: draftText,
            createdAt: Date(),
            sourceApp: nil,
            sourceURL: sourceURL,
            requestedAction: action
        )
        do {
            _ = try store.publish(envelope)
            isSaving = false
            phase = .ready
            onPublishSucceeded?()
        } catch {
            isSaving = false
            saveErrorMessage = "保存失败，请重试"
        }
    }

    /// Wired by the view so the model stays free of extension-context details.
    var onPublishSucceeded: (() -> Void)?
}

private struct ProvidersBox: @unchecked Sendable {
    let providers: [NSItemProvider]

    init(_ providers: [NSItemProvider]) {
        self.providers = providers
    }
}
