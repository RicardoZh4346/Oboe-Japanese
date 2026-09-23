import Observation
import OboeDomain
import OboeInfrastructure
import SwiftUI

struct InboxView: View {
    @State private var model: InboxViewModel
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var isCapturePresented = false

    @State private var isImageCapturePresented = false

    private let service: InboxService
    private let processingServices: InboxProcessingServices?
    private let inboxImageStore: InboxImageStore?
    /// v0.5.5：图片收集入口从已删除的「添加」Tab 迁入收集箱。
    private let ocrService: (any OCRRecognizing)?
    private let drainSharedCaptures: @Sendable () async -> Void
    private let sharedCapturesAwaitingImport: Int?
    private let importAwaitingSharedCaptures: @Sendable () async -> Void

    init(
        service: InboxService,
        processingServices: InboxProcessingServices? = nil,
        inboxImageStore: InboxImageStore? = nil,
        ocrService: (any OCRRecognizing)? = nil,
        drainSharedCaptures: @escaping @Sendable () async -> Void = {},
        sharedCapturesAwaitingImport: Int? = nil,
        importAwaitingSharedCaptures: @escaping @Sendable () async -> Void = {}
    ) {
        self.service = service
        self.processingServices = processingServices
        self.inboxImageStore = inboxImageStore
        self.ocrService = ocrService
        self.drainSharedCaptures = drainSharedCaptures
        self.sharedCapturesAwaitingImport = sharedCapturesAwaitingImport
        self.importAwaitingSharedCaptures = importAwaitingSharedCaptures
        _model = State(initialValue: InboxViewModel(service: service))
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            Picker("状态筛选", selection: $model.filter) {
                ForEach(InboxStatus.allCases, id: \.self) { status in
                    Text(status.title).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, OboeTheme.pageHorizontalPadding)
            .padding(.vertical, OboeTheme.Spacing.xs)
            .accessibilityIdentifier("inbox-filter-picker")

            if let awaiting = sharedCapturesAwaitingImport, awaiting > 0 {
                awaitingImportNotice(count: awaiting)
            }

            content
        }
        .background(OboeTheme.Colors.pageBackground)
        .navigationTitle("收集箱")
        .secondaryPage()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isSelecting ? "完成" : "选择") {
                    isSelecting.toggle()
                    if !isSelecting {
                        selection.removeAll()
                    }
                }
                .disabled(model.items.isEmpty)
                .accessibilityIdentifier("inbox-edit-button")
            }
            ToolbarItem(placement: .primaryAction) {
                if isSelecting {
                    Button("批量归档") {
                        let ids = Array(selection)
                        Task {
                            await model.archive(ids: ids)
                            selection.removeAll()
                            isSelecting = false
                        }
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("inbox-batch-archive-button")
                } else {
                    HStack(spacing: 16) {
                        if let ocrService, let inboxImageStore {
                            Button {
                                isImageCapturePresented = true
                            } label: {
                                Label("图片收集", systemImage: "photo.badge.plus")
                            }
                            .accessibilityIdentifier("inbox-image-capture-entry")
                            .sheet(isPresented: $isImageCapturePresented) {
                                ImageCaptureView(
                                    imageStore: inboxImageStore,
                                    ocrService: ocrService,
                                    inboxService: service,
                                    processingServices: processingServices
                                )
                            }
                        }
                        Button {
                            isCapturePresented = true
                        } label: {
                            Label("手动添加", systemImage: "plus")
                        }
                        .accessibilityIdentifier("inbox-add-button")
                    }
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "搜索收集内容")
        .task {
            await drainSharedCaptures()
            await model.load()
        }
        .task {
            await model.observeUnprocessedCount()
        }
        .onChange(of: model.filter) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: model.searchText) { _, _ in
            Task { await model.reload() }
        }
        .onChange(of: isSelecting) { _, selecting in
            if !selecting {
                selection.removeAll()
            }
        }
        .sheet(isPresented: $isCapturePresented) {
            NavigationStack {
                InboxCaptureView(service: service) {
                    Task { await model.reload() }
                }
            }
        }
        .alert(
            "删除这条内容？",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { shown in
                    if !shown {
                        model.pendingDeletion = nil
                    }
                }
            )
        ) {
            Button("删除", role: .destructive) {
                if let item = model.pendingDeletion {
                    Task { await model.delete(item) }
                }
            }
            .accessibilityIdentifier("inbox-delete-confirm-button")
            Button("取消", role: .cancel) {}
        } message: {
            Text("已生成的学习内容仍会保留。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil && !model.items.isEmpty },
                set: { shown in
                    if !shown {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    /// Share files left pending at a restore boundary — importing them into
    /// the restored database is the user's explicit choice, not automatic.
    private func awaitingImportNotice(count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .foregroundStyle(OboeTheme.Colors.accent)
                .accessibilityHidden(true)
            Text("检测到 \(count) 个尚未导入的分享内容")
                .font(.subheadline)
            Spacer()
            Button("导入") {
                Task {
                    await importAwaitingSharedCaptures()
                    await model.reload()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("inbox-import-pending-button")
        }
        .padding(.horizontal, OboeTheme.pageHorizontalPadding)
        .padding(.vertical, OboeTheme.Spacing.xs)
        .background(.background.secondary)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.items.isEmpty {
            ProgressView("正在载入收集箱…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("inbox-loading")
        } else if let errorMessage = model.errorMessage, model.items.isEmpty {
            OboeEmptyState(
                systemImage: "exclamationmark.arrow.triangle.2.circlepath",
                title: "无法载入收集箱",
                message: errorMessage,
                actionTitle: "重试",
                action: { Task { await model.reload() } },
                actionIdentifier: "inbox-retry-button",
                stateIdentifier: "inbox-error-state"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.items.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasActiveSearch {
            OboeEmptyState(
                systemImage: "magnifyingglass",
                title: "没有匹配的条目",
                message: "换个关键字试试。",
                stateIdentifier: "inbox-empty-search-state"
            )
        } else {
            switch model.filter {
            case .unprocessed:
                OboeEmptyState(
                    systemImage: "tray",
                    title: "收集箱是空的",
                    message: "通过手动添加、粘贴或分享，把日语文本先收进来。",
                    actionTitle: "手动添加",
                    action: { isCapturePresented = true },
                    actionIdentifier: "inbox-empty-add-button",
                    stateIdentifier: "inbox-empty-state"
                )
            case .processing:
                OboeEmptyState(
                    systemImage: "doc.badge.clock",
                    title: "没有处理中的条目",
                    message: "开始分析或编辑后，未完成的内容会出现在这里。",
                    stateIdentifier: "inbox-empty-state"
                )
            case .processed:
                OboeEmptyState(
                    systemImage: "checkmark.circle",
                    title: "还没有已处理条目",
                    message: "完成制卡或手动加入学习后，会记录在这里。",
                    stateIdentifier: "inbox-empty-state"
                )
            case .archived:
                OboeEmptyState(
                    systemImage: "archivebox",
                    title: "没有已归档条目",
                    message: "左滑条目可以把它收进归档。",
                    stateIdentifier: "inbox-empty-state"
                )
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.items) { item in
                row(for: item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            model.pendingDeletion = item
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .accessibilityIdentifier("inbox-swipe-delete-\(item.id.uuidString)")
                        if item.status == .archived {
                            Button {
                                Task { await model.unarchive(item) }
                            } label: {
                                Label("取消归档", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.orange)
                            .accessibilityIdentifier("inbox-swipe-unarchive-\(item.id.uuidString)")
                        } else {
                            Button {
                                Task { await model.archive(item) }
                            } label: {
                                Label("归档", systemImage: "archivebox")
                            }
                            .tint(.indigo)
                            .accessibilityIdentifier("inbox-swipe-archive-\(item.id.uuidString)")
                        }
                    }
                    .onAppear {
                        Task { await model.loadNextPageIfNeeded(current: item) }
                    }
            }
            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("inbox-loading-more")
            }
        }
        .listStyle(.plain)
        .refreshable {
            await model.reload()
        }
        .accessibilityIdentifier("inbox-list")
    }

    @ViewBuilder
    private func row(for item: InboxItem) -> some View {
        if isSelecting {
            Button {
                if selection.contains(item.id) {
                    selection.remove(item.id)
                } else {
                    selection.insert(item.id)
                }
            } label: {
                HStack(spacing: OboeTheme.Spacing.sm) {
                    Image(
                        systemName: selection.contains(item.id)
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(OboeTheme.Colors.accent)
                    .accessibilityHidden(true)
                    InboxRow(item: item)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("inbox-row-\(item.id.uuidString)")
        } else {
            NavigationLink {
                InboxItemDetailView(
                    item: item,
                    service: service,
                    processingServices: processingServices,
                    inboxImageStore: inboxImageStore,
                    onChanged: {
                        Task { await model.reload() }
                    }
                )
            } label: {
                InboxRow(item: item)
            }
            .accessibilityIdentifier("inbox-row-\(item.id.uuidString)")
        }
    }
}

private struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: OboeTheme.Spacing.xxs + 2) {
            Text(item.text)
                .font(.body)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: OboeTheme.Spacing.xs) {
                Text(InboxTimestampText.string(for: item.createdAt))
                Text("·")
                Text(item.sourceLabel)
                if item.status == .processing {
                    Text("·")
                    Text(item.status.title)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, OboeTheme.Spacing.xxs)
    }
}

@MainActor
@Observable
final class InboxViewModel {
    private let service: InboxService

    private(set) var items: [InboxItem] = []
    private(set) var unprocessedCount = 0
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    var filter = InboxStatus.unprocessed
    var searchText = ""
    var errorMessage: String?
    var pendingDeletion: InboxItem?

    private var nextCursor: InboxPageCursor?
    private var loadGeneration = 0

    init(service: InboxService) {
        self.service = service
    }

    var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        do {
            let page = try await service.fetchPage(
                status: filter,
                query: searchText,
                cursor: nil
            )
            guard generation == loadGeneration else { return }
            items = page.items
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func reload() async {
        await load()
    }

    func loadNextPageIfNeeded(current item: InboxItem) async {
        guard !isLoading, !isLoadingMore,
              let cursor = nextCursor,
              items.last?.id == item.id else {
            return
        }
        isLoadingMore = true
        let generation = loadGeneration
        do {
            let page = try await service.fetchPage(
                status: filter,
                query: searchText,
                cursor: cursor
            )
            guard generation == loadGeneration else { return }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            nextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    func archive(_ item: InboxItem) async {
        await archive(ids: [item.id])
    }

    func archive(ids: [UUID]) async {
        do {
            try await service.archive(ids: ids)
            await load()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unarchive(_ item: InboxItem) async {
        do {
            _ = try await service.unarchive(id: item.id)
            await load()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: InboxItem) async {
        do {
            try await service.delete(id: item.id)
            pendingDeletion = nil
            await load()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func observeUnprocessedCount() async {
        do {
            for try await count in service.observeUnprocessedCount() {
                unprocessedCount = count
            }
        } catch {
            return
        }
    }
}

extension InboxStatus {
    var title: String {
        switch self {
        case .unprocessed: "未处理"
        case .processing: "处理中"
        case .processed: "已处理"
        case .archived: "已归档"
        }
    }
}

extension InboxItem {
    var sourceLabel: String {
        if let sourceApp, !sourceApp.isEmpty {
            return "来自 \(sourceApp)"
        }
        return switch sourceType {
        case .manual: "手动添加"
        case .paste: "粘贴"
        case .share: "系统分享"
        case .ocr: "来自图片"
        }
    }
}

enum InboxTimestampText {
    static func string(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day(.defaultDigits))
    }
}
