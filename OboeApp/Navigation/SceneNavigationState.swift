import OboeDomain
import Observation
import SwiftUI

/// 每个 WindowGroup 实例的导航状态：section、列选择、各 Tab 独立
/// NavigationPath。由 AppSceneRoot 创建持有——selection 是 scene 语义，
/// 不能放回 application 级 runtime。
///
/// 数据库替换后 `databaseGenerationDidChange` 清空一切引用旧实体的
/// route/selection，避免新容器渲染陈旧实体。
@MainActor
@Observable
final class SceneNavigationState {
    var section: AppSection = .today
    var selectedDeck: DeckSidebarSelection?
    var selectedNoteID: UUID?
    /// detail 列解析到具体编辑器需要 kind——与 noteID 一起记录，
    /// 避免 detail 列再查一次库。
    var selectedNoteKind: KnowledgePointKind?
    var selectedInboxItemID: UUID?
    var selectedSettingsRoute: SettingsRoute?
    /// 初始为 `.doubleColumn`：两栏 split（today/settings）下即
    /// sidebar+detail 同显；三栏 split（decks）由 reducer 显式置 `.all`。
    /// 注意三栏语义下 `.doubleColumn` 折叠的是 sidebar 而非 content。
    var splitVisibility: NavigationSplitViewVisibility = .doubleColumn
    var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    /// compact 壳层三 Tab 各自的栈路径；切 Tab 不丢深度。
    var todayPath = NavigationPath()
    var decksPath = NavigationPath()
    var settingsPath = NavigationPath()
    /// v0.7.5 S18：compact 壳层 Reader Tab 的栈路径——
    /// `openReaderDocument` 在切 Tab 的同时把文档 id 压栈。
    var readerPath = NavigationPath()
    /// v0.7.5 S18：Reader 区当前选中/打开的文档——regular 壳层
    /// 列选择 + compact push 共用的「当前文档」语义。
    var selectedReaderDocumentID: UUID?

    /// Review 会话按 scope 缓存：壳层在 compact/regular 间切换或窗口
    /// resize 重建视图树时，页面内 @State model 会随树销毁——缓存保证
    /// 学习进度不丢。`@ObservationIgnored`：创建只发生在页面 body 求值
    /// 期，不需要反向通知；页面刷新由 model 自身 @Observable 驱动。
    /// 世代变更时清空（旧 service 引用随容器失效）。
    /// 底层用 AnyObject 泛型缓存，typed 访问由 `reviewSession` 提供。
    @ObservationIgnored
    private var sessionCache: [StudyScope: AnyObject] = [:]

    /// 当前导航状态对应的数据库世代。
    private(set) var generation = 0

    /// 数据库世代更新：清空绑定旧实体的 selection 与全部栈路径。
    /// 同一世代重复调用是 no-op。
    func databaseGenerationDidChange(to newGeneration: Int) {
        guard newGeneration != generation else { return }
        generation = newGeneration
        selectedDeck = nil
        selectedNoteID = nil
        selectedNoteKind = nil
        selectedInboxItemID = nil
        selectedSettingsRoute = nil
        selectedReaderDocumentID = nil
        todayPath = NavigationPath()
        decksPath = NavigationPath()
        settingsPath = NavigationPath()
        readerPath = NavigationPath()
        sessionCache.removeAll()
    }

    /// 删除当前选中牌组后的 reducer：清空指向该牌组的 sidebar 选择，
    /// 同时清空 detail 选择——不能默认展示已删除实体。
    /// 删除的是别的牌组时，现有选择保持不变。
    func deckWasDeleted(_ deckID: UUID) {
        guard selectedDeck == .deck(deckID) else { return }
        selectedDeck = nil
        selectedNoteID = nil
        selectedNoteKind = nil
    }

    /// compact 壳层的 Tab 选择与 section 的映射。regular 下 also
    /// 归一化列可见性——与 section 变更同批写入，新 split 初始化时
    /// 读到的就是正确值（事后 onChange 会晚一拍，列已按旧值布局）。
    /// today 是两栏 split（sidebar+detail）；decks/inbox/settings 是
    /// 三栏 split，必须 `.all`——三栏语义下 `.doubleColumn` 折叠的是
    /// sidebar 而非 content。
    func selectTab(_ section: AppSection) {
        self.section = section
        switch section {
        case .today, .reader:
            // reader 同样是两栏 split（sidebar+阅读区），与 today 同形态。
            splitVisibility = .doubleColumn
            // 两栏 split 没有 content 列——preferredCompactColumn 只能取
            // sidebar/detail，压扁时直接给 detail（功能页本身）。
            preferredCompactColumn = .detail
        case .decks, .inbox, .settings:
            splitVisibility = .all
            preferredCompactColumn = .sidebar
        }
    }

    /// regular inbox 区 detail 列选择：选中一条收集内容。
    func selectInboxItem(id: UUID) {
        selectedInboxItemID = id
    }

    /// regular sidebar 选中 Decks 区条目：切到 decks section 并清空
    /// detail 选择——detail 不得继续展示上一个上下文的条目。
    func selectDeckSidebar(_ selection: DeckSidebarSelection) {
        section = .decks
        selectedDeck = selection
        selectedNoteID = nil
        selectedNoteKind = nil
        // 三栏 split：sidebar+content+detail 全显。
        splitVisibility = .all
        // 压扁成单列时回到 sidebar（先选目标再看内容）。
        preferredCompactColumn = .sidebar
    }

    /// regular detail 列选择：noteID 与 kind 一起记录，detail 列
    /// 直接解析到具体编辑器，无需再查库。
    func selectNote(id: UUID, kind: KnowledgePointKind) {
        selectedNoteID = id
        selectedNoteKind = kind
    }

    // MARK: - v0.7.5 S18 跨 Feature 路由

    /// Reader → Deck：打开某牌组详情。compact 壳层切到牌组 Tab 并
    /// 把 deckID 压入该 Tab 的栈（DecksView 的
    /// `navigationDestination(for: UUID.self)` 解析为详情页）；
    /// regular 壳层选择 sidebar 条目、三栏全显、清空 detail 选择。
    /// 目标牌组已删除时壳层自然落「牌组已不存在」占位——不做预取
    /// 校验（deck 列表观察流会随后收敛）。
    func openDeck(_ deckID: UUID) {
        section = .decks
        selectedDeck = .deck(deckID)
        selectedNoteID = nil
        selectedNoteKind = nil
        splitVisibility = .all
        preferredCompactColumn = .sidebar
        decksPath = NavigationPath()
        decksPath.append(deckID)
    }

    /// Deck → Reader：打开某文档阅读页。compact 切到阅读 Tab 并压
    /// 栈；regular 切 section + 记录 detail 列选择（Reader 内部两栏
    /// split 的 selection 绑定读它）。
    func openReaderDocument(_ documentID: UUID) {
        section = .reader
        selectedReaderDocumentID = documentID
        splitVisibility = .doubleColumn
        preferredCompactColumn = .detail
        readerPath = NavigationPath()
        readerPath.append(documentID)
    }

    /// Reader 区内部的文档选择（用户在库里点行/regular 列选择）——
    /// 记录当前文档但不改 section、不清栈。
    func selectReaderDocument(id: UUID?) {
        selectedReaderDocumentID = id
    }

    /// 文档被删除后的 reducer：清空指向该文档的选择与栈内引用。
    /// 栈内引用无法定点移除——NavigationPath 不可按下标删除；栈中
    /// 目标由 ReaderView 载入失败自然呈现「文档不存在」。
    func readerDocumentWasDeleted(_ documentID: UUID) {
        if selectedReaderDocumentID == documentID {
            selectedReaderDocumentID = nil
        }
    }

    /// 取 scope 对应的 Review 会话；无缓存时用 make 创建并缓存。
    /// 同一 scope 重复进入会拿到同一实例——页面 `.task` 里的 refresh
    /// 负责刷新过期数据，会话容器只负责生命周期续存。
    func reviewSession(
        for scope: StudyScope,
        make: () -> ReviewViewModel
    ) -> ReviewViewModel {
        cachedSession(for: scope, make: make)
    }

    /// scope 键控的对象缓存：同 scope 重复访问返回同一实例。
    /// 泛型化让缓存语义可以在没有真实 service 的单测里验证。
    func cachedSession<T: AnyObject>(
        for scope: StudyScope,
        make: () -> T
    ) -> T {
        if let existing = sessionCache[scope] as? T { return existing }
        let instance = make()
        sessionCache[scope] = instance
        return instance
    }
}
