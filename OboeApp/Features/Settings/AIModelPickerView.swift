import OboeDomain
import SwiftUI

/// 设置页「模型」二级页：获取 → 搜索 → 选择。
///
/// 视图本身无状态——已拉取的模型列表、在途请求与错误都由
/// `SettingsView` 持有（供应商/Key/地址变化时统一失效），本页只负责
/// 渲染与回调。模型列表只存在于内存，绝不写入资料库或备份。
struct AIModelPickerView: View {
    /// 面向用户的服务名（预设显示名或自定义名称），用于鉴权提示文案。
    let serviceName: String
    /// 已拉取的模型列表；空数组表示尚未成功获取（或被失效清空）。
    let models: [AIModelDescriptor]
    let isFetching: Bool
    /// 上一次获取失败的本地化文案；nil 表示无错误。
    let errorMessage: String?
    /// 不满足获取前置条件时的说明（缺 Key/配置无效等）；nil 表示可获取。
    let prerequisiteMessage: String?
    let selectedModelID: String?
    let onFetch: () -> Void
    let onCancel: () -> Void
    let onSelect: (AIModelDescriptor) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredModels: [AIModelDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("当前模型") {
                    Text(selectedModelID ?? "未选择")
                        .foregroundStyle(
                            selectedModelID == nil ? Color.secondary : Color.primary
                        )
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier("ai-model-current")
            }

            Section {
                if let prerequisiteMessage {
                    Text(prerequisiteMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ai-model-fetch-prerequisite")
                } else if isFetching {
                    // 行级 identifier 挂在文本上——挂在 HStack 会把整行合并成
                    // 单个无障碍元素并吞掉取消按钮自身的 identifier。
                    HStack(spacing: 12) {
                        ProgressView()
                            .accessibilityLabel("正在获取模型列表")
                        Text("正在获取模型列表…")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ai-model-fetch-in-progress")
                        Spacer()
                        Button("取消", role: .cancel, action: onCancel)
                            .accessibilityIdentifier("ai-model-fetch-cancel-button")
                    }
                } else {
                    Button(action: onFetch) {
                        Label(
                            models.isEmpty ? "获取模型" : "重新获取模型列表",
                            systemImage: "arrow.down.circle"
                        )
                    }
                    .accessibilityIdentifier("ai-model-fetch-button")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("ai-model-fetch-error")
                    if !isFetching {
                        Button("重试", action: onFetch)
                            .accessibilityIdentifier("ai-model-fetch-retry-button")
                    }
                }

                Text("获取模型会把 API Key 发送给 \(serviceName) 做鉴权，用于列出可选模型；不会发送学习内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai-model-fetch-privacy-note")
            }

            if !models.isEmpty {
                Section("可选模型") {
                    ForEach(filteredModels, id: \.self) { model in
                        Button {
                            onSelect(model)
                            dismiss()
                        } label: {
                            modelRow(model)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("ai-model-option-\(model.id)")
                        .accessibilityAddTraits(
                            model.id == selectedModelID ? .isSelected : []
                        )
                        .accessibilityHint(
                            model.id == selectedModelID ? "当前已选" : "双击选择该模型"
                        )
                    }
                    if filteredModels.isEmpty {
                        Text("没有匹配「\(searchText)」的模型。")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("ai-model-search-empty")
                    }
                }
            }
        }
        .navigationTitle("选择模型")
        .secondaryPage()
        .searchable(text: $searchText, prompt: "搜索模型 ID 或名称")
    }

    /// 模型 ID 可能很长（自定义端点可达 200 字符）：显示名与 ID 分行，
    /// 全部折行展示，不做截断，最大辅助字号下同样完整可读。
    private func modelRow(_ model: AIModelDescriptor) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if model.displayName != model.id {
                    Text(model.displayName)
                    Text(model.id)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.id)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.id == selectedModelID {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
