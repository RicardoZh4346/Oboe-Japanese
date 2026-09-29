import Foundation
import OboeDomain
import OboeInfrastructure
import Observation

/// 单文档阅读视图模型（S10）。
///
/// 渲染模型：当前章的全部 `ReaderBlock` + 逐块 token 着色数据。
/// 位置持久化用 `ReaderLocation`（章序+块序+块内 UTF-16 偏移+前后文
/// +块 hash）——字号/窗口变化后按块定位，像素偏移不参与恢复；
/// 块 hash 不符时降级到章首并置 `restoreDegraded`（§4.2 歧义处理：
/// 「位置未能精确恢复」显式提示，不静默落错）。
///
/// token 点击：文本组件命中 (blockID, utf16Range) → VM 查回
/// `ReaderToken` → `onTokenTap` 抛给上层（S11 挖词面板挂这里；
/// 本步默认实现为 nil 时只在内部留 hook，UI 静默）。
@MainActor
@Observable
final class ReaderDocumentViewModel {

    /// 词法着色：一个 token 在块内的 UTF-16 范围 + 解析出的知识状态。
    struct TokenHighlight: Equatable, Sendable {
        let blockID: UUID
        /// 块内 UTF-16 范围（面向渲染原文）。
        let utf16Range: Range<Int>
        let surface: String
        let state: VocabularyKnowledgeState
    }

    /// token 点击载荷（S11 面板以它驱动）。
    struct TokenTap: Equatable, Sendable {
        let blockID: UUID
        let utf16Range: Range<Int>
        let surface: String
        /// token 活用读音（lookup 的 reading 提示；OOV 挖词预填用）。
        let reading: String?
        let lexicalKey: LexicalKey?
        let candidates: [MorphologyCandidate]
        /// 解析状态——ambiguous 时 Inspector 必须显式候选选择，
        /// 批量路径不得自动取首候选（§6.2）。
        let resolutionStatus: TokenResolutionStatus
    }

    private(set) var document: ReaderDocumentMetadata?
    private(set) var chapters: [ReaderChapterMetadata] = []
    /// 当前章（`chapters` 下标）。
    private(set) var currentChapterIndex = 0
    private(set) var blocks: [ReaderBlock] = []
    /// blockID → 该块 token 着色数组（morphology 缺席/失败时块
    /// 无条目 → 文本着色降级为纯文本，不阻断阅读）。
    private(set) var highlights: [UUID: [TokenHighlight]] = [:]
    private(set) var bookmarks: [ReaderBookmark] = []
    private(set) var isLoading = false
    /// 正在做形态分析的章序号（着色是渐进增强——先出文本，色随后）。
    private(set) var analyzingChapterOrdinal: Int?
    private(set) var errorMessage: String?
    /// 位置恢复结果：view 据此滚动 + 显示降级提示。
    private(set) var restoredLocation: ReaderLocation?
    private(set) var restoreDegraded = false
    /// 当前可见块（滚动回调更新）——位置保存/进度都用它。
    private(set) var visibleBlockOrdinal = 0
    private(set) var visibleUTF16Offset = 0
    /// 上次已保存的可见定位（避免每帧重写 DB）。
    private var lastSavedBlockOrdinal: Int?
    /// 全章 utf16 累计长度（进度基点计算用）。
    private var chapterStartUTF16: [Int] = []

    /// S11 挂载点：token 点击回调。默认 nil——只留 API。
    var onTokenTap: ((TokenTap) -> Void)?

    private let documentID: UUID
    private let repository: any ReaderDocumentStore
    private let morphology: (any JapaneseMorphologyService)?
    private let tokenStates: (any ReaderTokenStateProvider)?
    private let now: @Sendable () -> Date

    init(
        documentID: UUID,
        repository: any ReaderDocumentStore,
        morphology: (any JapaneseMorphologyService)? = nil,
        tokenStates: (any ReaderTokenStateProvider)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.documentID = documentID
        self.repository = repository
        self.morphology = morphology
        self.tokenStates = tokenStates
        self.now = now
    }

    /// 装配方便捷入口。
    convenience init(
        documentID: UUID,
        dependencies: ReaderFeatureDependencies,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            documentID: documentID,
            repository: dependencies.repository,
            morphology: dependencies.morphology,
            tokenStates: dependencies.tokenStates,
            now: now
        )
    }

    // MARK: - 载入与恢复

    /// 进入文档：取章表 → 恢复位置（无位置则章0）→ 载章 →
    /// touch lastOpened。
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let document = try await repository.fetchDocument(id: documentID)
            guard let document else {
                errorMessage = "文档不存在。"
                return
            }
            self.document = document
            chapters = try await repository.fetchChapters(
                documentID: documentID
            )
            bookmarks = try await repository.fetchBookmarks(
                documentID: documentID
            )
            // 章首 utf16 前缀和：progressBasisPoints = 全局 utf16
            // 占比（分子 = 前序章长度 + 本章已读）。
            var prefix = 0
            chapterStartUTF16 = chapters.map { chapter in
                defer { prefix += chapter.textUTF16Length }
                return prefix
            }
            // 位置恢复：章节序与块 hash 都要符合才算精确命中。
            restoredLocation = nil
            restoreDegraded = false
            var targetChapter = 0
            if let position = try await repository.fetchPosition(
                documentID: documentID
            ) {
                let loc = position.location
                targetChapter = chapters.firstIndex {
                    $0.ordinal == loc.chapterOrdinal
                } ?? 0
                restoredLocation = loc
            }
            try await selectChapter(
                index: targetChapter, keepRestore: true
            )
            try? await repository.touchLastOpened(
                id: documentID, at: now()
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 切换章节：取块 → 形态分析（可缺席/可失败，不阻断文本）。
    /// `keepRestore`：载入流程保留 restoredLocation 供首屏滚动；
    /// 用户手动切章后恢复点失效。
    func selectChapter(index: Int, keepRestore: Bool = false) async throws {
        guard chapters.indices.contains(index) else { return }
        currentChapterIndex = index
        let chapter = chapters[index]
        blocks = try await repository.fetchBlocks(
            documentID: documentID, chapterID: chapter.id
        )
        visibleBlockOrdinal = blocks.first?.ordinal ?? 0
        lastSavedBlockOrdinal = nil
        if !keepRestore { restoreDegraded = false }
        if keepRestore, let loc = restoredLocation {
            // 恢复点先在本章内校验：块序/hash 不符 → 降级提示，
            // view 只滚到章首，不拿失效定位滚动。
            if !restoreTargetIsValid(loc.blockOrdinal) {
                restoredLocation = nil
            }
        } else {
            restoredLocation = nil
        }
        await analyzeHighlights(chapter: chapter)
    }

    /// 当前章标题（回退「第 N 节」）。
    var currentChapterTitle: String {
        guard chapters.indices.contains(currentChapterIndex) else {
            return document?.title ?? ""
        }
        return chapters[currentChapterIndex].title
            ?? "第 \(currentChapterIndex + 1) 节"
    }

    // MARK: - 形态分析与着色

    /// 逐块 tokenize → lexicalKey → lexeme → state → highlights。
    /// morphology/tokenStates 任一缺席 → 纯文本渲染（不视为错误）。
    private func analyzeHighlights(
        chapter: ReaderChapterMetadata
    ) async {
        guard let morphology, let tokenStates, !blocks.isEmpty else {
            highlights = [:]
            return
        }
        analyzingChapterOrdinal = chapter.ordinal
        defer { analyzingChapterOrdinal = nil }
        var collected: [UUID: [ReaderToken]] = [:]
        var keys = Set<LexicalKey>()
        for block in blocks {
            if Task.isCancelled { return }
            do {
                let tokens = try await morphology.tokenize(
                    MorphologyBlock(
                        blockID: block.id,
                        text: block.text,
                        textHash: block.textHash
                    )
                )
                collected[block.id] = tokens
                for token in tokens {
                    if let key = token.lexicalKey { keys.insert(key) }
                }
            } catch {
                // 单块失败只丢该块着色（§5 宽容：正文优先）。
                continue
            }
        }
        tokenCache = collected
        var highlightMap: [UUID: [TokenHighlight]] = [:]
        do {
            let lexemes = try await tokenStates.resolveLexemes(
                keys: Array(keys)
            )
            let states = try await tokenStates.states(
                lexemeIDs: lexemes.values.map(\.id)
            )
            for (blockID, tokens) in collected {
                highlightMap[blockID] = tokens.map { token in
                    let state = token.lexicalKey
                        .flatMap { lexemes[$0] }
                        .flatMap { states[$0.id] }
                        ?? .unknown
                    return TokenHighlight(
                        blockID: blockID,
                        utf16Range: token.sourceRangeUTF16,
                        surface: token.surface,
                        state: state
                    )
                }
            }
            highlights = highlightMap
        } catch {
            // 状态解析失败：仍然按 unknown 着色（有 token 数据可用）。
            var fallback: [UUID: [TokenHighlight]] = [:]
            for (blockID, tokens) in collected {
                fallback[blockID] = tokens.map {
                    TokenHighlight(
                        blockID: blockID,
                        utf16Range: $0.sourceRangeUTF16,
                        surface: $0.surface,
                        state: .unknown
                    )
                }
            }
            highlights = fallback
        }
    }

    /// 点选命中：(blockID, 块内 utf16Range) → TokenTap 载荷。
    /// 命中词典有候选的 token 才回调上层；否则忽略。
    func handleTap(blockID: UUID, utf16Range: Range<Int>) {
        guard let tokens = tokenCache[blockID] else { return }
        guard let token = tokens.first(where: {
            $0.sourceRangeUTF16.overlaps(utf16Range)
                || $0.sourceRangeUTF16 == utf16Range
        }) else { return }
        onTokenTap?(TokenTap(
            blockID: blockID,
            utf16Range: token.sourceRangeUTF16,
            surface: token.surface,
            reading: token.reading,
            lexicalKey: token.lexicalKey,
            candidates: token.candidates,
            resolutionStatus: token.resolutionStatus
        ))
    }

    /// analyzeHighlights 时保留的原始 token（tap 回查候选用）。
    private var tokenCache: [UUID: [ReaderToken]] = [:]

    // MARK: - 位置与进度

    /// 滚动回调：view 报当前顶部可见块 + 块内偏移（UITextView
    /// 命中计算），VM 记内存位；写库走 `persistPosition`（低频）。
    func updateVisiblePosition(blockOrdinal: Int, utf16Offset: Int) {
        visibleBlockOrdinal = blockOrdinal
        visibleUTF16Offset = utf16Offset
    }

    /// 进度条当前值（0…10000），与 `persistPosition` 写库口径一致。
    var visibleProgressBasisPoints: Int {
        progressBasisPoints(
            blockOrdinal: visibleBlockOrdinal,
            utf16Offset: visibleUTF16Offset
        )
    }

    /// 退出/切章/后台时保存：构造 ReaderLocation（前后文各 32
    /// Character），updatedAt 裁决交给仓储（§4.2 旧写不盖新写）。
    func persistPosition() async {
        await persistPosition(utf16Offset: visibleUTF16Offset)
    }

    /// 显式偏移版（测试/特定恢复用）。
    func persistPosition(utf16Offset: Int) async {
        guard let block = blocks.first(where: {
            $0.ordinal == visibleBlockOrdinal
        }) ?? blocks.first,
              chapters.indices.contains(currentChapterIndex)
        else { return }
        let chapter = chapters[currentChapterIndex]
        let text = block.text
        let clamped = min(utf16Offset, text.utf16.count)
        let utf16Index = text.utf16.index(
            text.utf16.startIndex, offsetBy: clamped
        )
        let charIndex = String.Index(utf16Index, within: text)
            ?? text.startIndex
        let location = ReaderLocation(
            chapterOrdinal: chapter.ordinal,
            blockOrdinal: block.ordinal,
            utf16Offset: clamped,
            blockTextHash: block.textHash,
            prefix: String(text[..<charIndex].suffix(
                ReaderLocation.contextCharacterLimit
            )),
            suffix: String(text[charIndex...].prefix(
                ReaderLocation.contextCharacterLimit
            ))
        )
        do {
            try await repository.savePosition(ReaderPosition(
                documentID: documentID,
                chapterID: chapter.id,
                location: location,
                updatedAt: now()
            ))
            lastSavedBlockOrdinal = block.ordinal
            try await repository.updateProgress(
                id: documentID, basisPoints: progressBasisPoints(
                    blockOrdinal: block.ordinal, utf16Offset: clamped
                )
            )
        } catch {
            // 位置写入失败不扰民——下次进入从旧位置继续。
        }
    }

    /// 0…10000 基点：全局 utf16 占比（前缀和 + 块内偏移近似）。
    func progressBasisPoints(
        blockOrdinal: Int, utf16Offset: Int
    ) -> Int {
        let total = max(chapterStartUTF16.last.map {
            $0 + (chapters.last?.textUTF16Length ?? 0)
        } ?? 0, 1)
        var read = chapterStartUTF16.indices.contains(currentChapterIndex)
            ? chapterStartUTF16[currentChapterIndex] : 0
        for block in blocks where block.ordinal < blockOrdinal {
            read += block.text.utf16.count
        }
        read += utf16Offset
        return min(read * 10_000 / total, 10_000)
    }

    /// 位置恢复目标：(blockOrdinal, utf16Offset)？章内校验在 view。
    var pendingRestore: (blockOrdinal: Int, utf16Offset: Int)? {
        guard let loc = restoredLocation else { return nil }
        return (loc.blockOrdinal, loc.utf16Offset)
    }

    /// 恢复滚动已应用：清一次性恢复点——此后重组（字号/译文/
    /// 折叠）锚定「当前可见块」而非开卷位置，字号变化/模式切换
    /// 不再把用户拽回最初落点（S17 位置保持）。
    func consumeRestoredLocation() {
        restoredLocation = nil
    }

    /// 恢复点命中校验：块 hash 不符 → 降级章首 + 提示。
    func restoreTargetIsValid(_ blockOrdinal: Int) -> Bool {
        guard let loc = restoredLocation else { return false }
        guard let block = blocks.first(where: {
            $0.ordinal == loc.blockOrdinal
        }) else {
            restoreDegraded = true
            return false
        }
        if block.textHash != loc.blockTextHash {
            restoreDegraded = true
            return false
        }
        return true
    }

    // MARK: - 书签

    var currentLocationIsBookmarked: Bool {
        bookmarks.contains {
            $0.location.chapterOrdinal
                == chapters[safe: currentChapterIndex]?.ordinal
                && $0.location.blockOrdinal == visibleBlockOrdinal
        }
    }

    func toggleBookmark() async {
        if let existing = bookmarks.first(where: {
            $0.location.chapterOrdinal
                == chapters[safe: currentChapterIndex]?.ordinal
                && $0.location.blockOrdinal == visibleBlockOrdinal
        }) {
            try? await repository.removeBookmark(id: existing.id)
        } else {
            guard let block = blocks.first(where: {
                $0.ordinal == visibleBlockOrdinal
            }), chapters.indices.contains(currentChapterIndex)
            else { return }
            let chapter = chapters[currentChapterIndex]
            let location = ReaderLocation(
                chapterOrdinal: chapter.ordinal,
                blockOrdinal: block.ordinal,
                utf16Offset: 0,
                blockTextHash: block.textHash,
                prefix: String(block.text.suffix(
                    ReaderLocation.contextCharacterLimit
                )),
                suffix: ""
            )
            try? await repository.addBookmark(ReaderBookmark(
                id: UUID(), documentID: documentID,
                chapterID: chapter.id, location: location,
                label: nil, createdAt: now()
            ))
        }
        bookmarks = (try? await repository.fetchBookmarks(
            documentID: documentID
        )) ?? bookmarks
    }

    func removeBookmark(_ bookmark: ReaderBookmark) async {
        try? await repository.removeBookmark(id: bookmark.id)
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    /// 跳书签：解析章序 → 切章 → view 滚到块。
    func jump(to bookmark: ReaderBookmark) async throws {
        if let index = chapters.firstIndex(where: {
            $0.ordinal == bookmark.location.chapterOrdinal
        }) {
            restoredLocation = bookmark.location
            try await selectChapter(index: index, keepRestore: true)
        }
    }

    func clearError() { errorMessage = nil }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
