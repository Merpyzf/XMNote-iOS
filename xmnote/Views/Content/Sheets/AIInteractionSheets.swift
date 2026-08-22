/**
 * [INPUT]: 依赖 AITextResultViewModel/AIAutoTagViewModel、AIRepositoryProtocol 与现有卡片/加载/反馈组件
 * [OUTPUT]: 对外提供 AITextResultSheet 与 AIAutoTagSheet，承接流式结果、追加想法生命周期和标签确认写回
 * [POS]: Views/Content/Sheets 的 AI 业务 Sheet，被通用 viewer 及单页详情入口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 流式 AI 释义 Sheet；整条书摘释义可由用户明确确认后追加到最新想法。
struct AITextResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: AITextResultViewModel
    @State private var loadingGate = LoadingGate()

    private let onIdeaAppendWillBegin: @MainActor () -> Void
    private let onIdeaAppendFailed: @MainActor () -> Void
    private let onIdeaAppended: @MainActor () async -> Void

    /// 用稳定 presentation 建立状态源；网络只在 Sheet 出现后启动。
    init(
        presentation: AITextResultPresentation,
        repository: any AIRepositoryProtocol,
        onIdeaAppendWillBegin: @escaping @MainActor () -> Void = { },
        onIdeaAppendFailed: @escaping @MainActor () -> Void = { },
        onIdeaAppended: @escaping @MainActor () async -> Void = { }
    ) {
        _viewModel = State(
            initialValue: AITextResultViewModel(
                request: presentation.request,
                repository: repository
            )
        )
        self.onIdeaAppendWillBegin = onIdeaAppendWillBegin
        self.onIdeaAppendFailed = onIdeaAppendFailed
        self.onIdeaAppended = onIdeaAppended
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.surfaceSheet.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.section) {
                        resultHeader
                        resultContent
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.vertical, Spacing.section)
                    .safeAreaPadding(.bottom, viewModel.request.noteIDForAppending == nil ? Spacing.none : Spacing.double)
                }
                .scrollIndicators(.hidden)

                if viewModel.isAppending {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView("正在追加到想法…", style: .card)
                        .transition(.opacity)
                }
            }
            .navigationTitle(viewModel.request.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
                if viewModel.request.noteIDForAppending != nil {
                    appendActionBar
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isAppending)
        .onAppear {
            viewModel.startGeneration()
            syncLoadingGate()
        }
        .onChange(of: viewModel.isGenerating) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            viewModel.cancelGeneration()
            loadingGate.hideImmediately()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: viewModel.errorMessage
        )
    }

    private var resultHeader: some View {
        ContentViewerHeroCard(
            title: viewModel.request.contextTitle,
            subtitle: viewModel.modelDescription.isEmpty ? "正在连接模型…" : viewModel.modelDescription
        ) {
            Text(headerHint)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if !viewModel.content.isEmpty {
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text(viewModel.content)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if viewModel.isGenerating {
                        LoadingStateView("正在继续生成…", style: .inline)
                    }
                }
                .padding(Spacing.contentEdge)
            }
            .transition(.opacity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: Spacing.base) {
                viewerMessageCard(text: errorMessage)
                Button("重新生成") {
                    viewModel.startGeneration()
                }
                .buttonStyle(.bordered)
            }
            .transition(.opacity)
        } else if loadingGate.isVisible {
            LoadingStateView("正在生成内容…", style: .card)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else {
            Color.clear.frame(minHeight: Spacing.double)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("关闭") {
                viewModel.cancelGeneration()
                dismiss()
            }
            .disabled(viewModel.isAppending)
        }

        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.content.isEmpty {
                Button {
                    UIPasteboard.general.string = viewModel.content
                    toastCenter.success("AI 结果已复制")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("复制 AI 结果")
            }
        }
    }

    private var appendActionBar: some View {
        VStack(spacing: Spacing.none) {
            Divider()
            Button {
                appendToIdea()
            } label: {
                Label("追加到想法", systemImage: "text.badge.plus")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: Spacing.actionReserved)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .disabled(!viewModel.canAppendToIdea)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.cozy)
        }
        .background(Color.surfaceSheet)
    }

    private var headerHint: String {
        switch viewModel.request {
        case .noteExplanation:
            "结果不会自动修改书摘；确认后才会追加到想法。"
        case .textLookup:
            "释义基于触发时锁定的选中文本与上下文。"
        }
    }

    /// 追加成功后先让来源页强刷详情，再关闭 Sheet，确保返回即看到最新想法。
    private func appendToIdea() {
        Task {
            onIdeaAppendWillBegin()
            guard await viewModel.appendToIdea() else {
                onIdeaAppendFailed()
                return
            }
            await onIdeaAppended()
            toastCenter.success("已追加到想法")
            dismiss()
        }
    }

    private func syncLoadingGate() {
        let shouldShow = viewModel.isGenerating && viewModel.content.isEmpty
        loadingGate.update(intent: shouldShow ? .read : .none)
    }
}

/// 自动标签 Sheet，保留用户对建议的最终选择权并在确认后刷新来源详情。
struct AIAutoTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: AIAutoTagViewModel
    @State private var loadingGate = LoadingGate()

    private let onTagsApplied: @MainActor () async -> Void

    /// 用稳定书摘主键建立状态源；标签建议只在 Sheet 出现后请求。
    init(
        presentation: AIAutoTagPresentation,
        repository: any AIRepositoryProtocol,
        onTagsApplied: @escaping @MainActor () async -> Void = { }
    ) {
        _viewModel = State(
            initialValue: AIAutoTagViewModel(
                noteID: presentation.noteID,
                bookTitle: presentation.bookTitle,
                repository: repository
            )
        )
        self.onTagsApplied = onTagsApplied
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.surfaceSheet.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.section) {
                        ContentViewerHeroCard(
                            title: normalizedBookTitle,
                            subtitle: "自动标签"
                        ) {
                            Text("AI 最多推荐 3 个标签；已有标签会复用，确认前可以自由选择。")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }

                        suggestionContent
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.vertical, Spacing.section)
                    .safeAreaPadding(.bottom, Spacing.double)
                }
                .scrollIndicators(.hidden)

                if viewModel.isApplying {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView("正在应用标签…", style: .card)
                        .transition(.opacity)
                }
            }
            .navigationTitle("自动标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        viewModel.cancelLoading()
                        dismiss()
                    }
                    .disabled(viewModel.isApplying)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
                applyActionBar
            }
        }
        .interactiveDismissDisabled(viewModel.isApplying)
        .onAppear {
            viewModel.startLoading()
            syncLoadingGate()
        }
        .onChange(of: viewModel.isLoading) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            viewModel.cancelLoading()
            loadingGate.hideImmediately()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: viewModel.suggestions
        )
    }

    @ViewBuilder
    private var suggestionContent: some View {
        if !viewModel.suggestions.isEmpty {
            XMSettingsGroupCard {
                VStack(spacing: Spacing.none) {
                    ForEach(viewModel.suggestions) { suggestion in
                        Button {
                            viewModel.toggleSuggestion(id: suggestion.id)
                        } label: {
                            AIAutoTagSuggestionRow(suggestion: suggestion)
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != viewModel.suggestions.last?.id {
                            Divider().padding(.leading, Spacing.double)
                        }
                    }
                }
                .padding(.horizontal, Spacing.contentEdge)
            }
            .transition(.opacity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: Spacing.base) {
                viewerMessageCard(text: errorMessage)
                Button("重新推荐") {
                    viewModel.startLoading()
                }
                .buttonStyle(.bordered)
            }
            .transition(.opacity)
        } else if loadingGate.isVisible {
            LoadingStateView("正在分析书摘…", style: .card)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else if !viewModel.isLoading {
            viewerMessageCard(text: "当前书摘没有适合长期知识管理的标签建议。")
                .transition(.opacity)
        } else {
            Color.clear.frame(minHeight: Spacing.double)
        }
    }

    private var applyActionBar: some View {
        VStack(spacing: Spacing.none) {
            Divider()
            Button {
                applyTags()
            } label: {
                Text(viewModel.isApplying ? "应用中…" : "应用所选标签")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: Spacing.actionReserved)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .disabled(!viewModel.hasSelectedSuggestion || viewModel.isLoading || viewModel.isApplying)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.cozy)
        }
        .background(Color.surfaceSheet)
    }

    private var normalizedBookTitle: String {
        let title = viewModel.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "当前书摘" : title
    }

    /// 写入成功后强刷来源详情，标签 rail 与列表观察流会同步获得数据库真实结果。
    private func applyTags() {
        Task {
            guard await viewModel.applySelectedSuggestions() else { return }
            await onTagsApplied()
            toastCenter.success("标签已更新")
            dismiss()
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.isLoading ? .read : .none)
    }
}

/// 单条自动标签候选，复用设置行密度并明确区分已有与新建标签。
private struct AIAutoTagSuggestionRow: View {
    let suggestion: AIAutoTagSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Image(systemName: suggestion.isSelected ? "checkmark.circle.fill" : "circle")
                .font(AppTypography.title3)
                .foregroundStyle(suggestion.isSelected ? Color.brand : Color.iconSecondary)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.cozy) {
                    Text(suggestion.name)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text(suggestion.isExisting ? "已有" : "新标签")
                        .font(AppTypography.caption2Medium)
                        .foregroundStyle(suggestion.isExisting ? Color.feedbackSuccess : Color.textSecondary)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .background(Color.tagBackground, in: Capsule())
                }

                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Spacing.none)
        }
        .padding(.vertical, Spacing.base)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suggestion.name)，\(suggestion.isExisting ? "已有标签" : "新标签")")
        .accessibilityValue(suggestion.isSelected ? "已选择" : "未选择")
        .accessibilityHint("双击切换选择")
        .accessibilityAddTraits(suggestion.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
