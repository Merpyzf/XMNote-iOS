/**
 * [INPUT]: 依赖 AIPromptEditorViewModel、提示词预览/样例模型与 SwiftUI 系统 Form/导航呈现
 * [OUTPUT]: 对外提供提示词请求预览、试运行和字段优化三个业务 Sheet
 * [POS]: Views/Personal/Sheets 的提示词编辑次级任务集合，由 AIPromptEditorView 的 item-driven Sheet 路由消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 离线真实请求预览；固定规则只在用户展开完整请求时出现。
struct AIPromptPreviewSheet: View {
    let editableRoleRules: String
    let preview: AIPromptRequestPreview

    @Environment(\.dismiss) private var dismiss
    @State private var showsFullRequest = false

    var body: some View {
        NavigationStack {
            Form {
                Section("系统提示词") {
                    Text(editableRoleRules)
                        .textSelection(.enabled)
                }

                Section("用户提示词（变量已替换）") {
                    Text(preview.userPrompt)
                        .textSelection(.enabled)
                }

                DisclosureGroup("完整请求", isExpanded: $showsFullRequest) {
                    LabeledContent("System") {
                        Text(editableRoleRules)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LabeledContent("User") {
                        Text(preview.userPrompt)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text("应用自动附加内容")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.textSecondary)
                        Text(preview.applicationRules)
                            .textSelection(.enabled)
                    }
                    if preview.expectsJSON {
                        LabeledContent("响应格式", value: "JSON")
                    }
                }
            }
            .navigationTitle("实际发送内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private enum AIPromptTrialSource: Hashable {
    case builtIn
    case recent
}

/// P1 运行确认页；网络请求次数在按钮与对照开关处同时明确，不自动触发调用。
struct AIPromptTrialSheet: View {
    @Bindable var viewModel: AIPromptEditorViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var source: AIPromptTrialSource = .builtIn
    @State private var comparesDefault = false
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("样例") {
                    if viewModel.recentSample != nil {
                        Picker("内容来源", selection: $source) {
                            Text("内置样例").tag(AIPromptTrialSource.builtIn)
                            Text("最近书摘").tag(AIPromptTrialSource.recent)
                        }
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isRunningTrial)
                    } else if viewModel.isLoadingRecentSample {
                        HStack {
                            ProgressView()
                            Text("正在读取最近书摘…")
                        }
                    } else {
                        Text("使用内置样例")
                            .foregroundStyle(Color.textSecondary)
                    }
                }

                Section {
                    Toggle("与默认版本对照", isOn: $comparesDefault)
                        .disabled(viewModel.isRunningTrial)
                    Text(comparesDefault ? "将产生 2 次 AI 请求" : "将产生 1 次 AI 请求")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Section {
                    Button {
                        startTrial()
                    } label: {
                        HStack {
                            Text(viewModel.isRunningTrial ? "运行中…" : "运行")
                            Spacer()
                            if viewModel.isRunningTrial { ProgressView() }
                        }
                    }
                    .disabled(viewModel.isRunningTrial)

                    Text("使用相同模型、参数和上下文；结果可能因模型随机性不同。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                if let error = viewModel.trialErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Color.feedbackError)
                    }
                }

                if let result = viewModel.trialResult {
                    Section("当前版本") {
                        Text(result.current)
                            .textSelection(.enabled)
                    }
                    if let defaultVersion = result.defaultVersion {
                        Section("默认版本") {
                            Text(defaultVersion)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("运行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { close() }
                }
            }
            .task {
                await viewModel.loadRecentSample()
            }
            .onDisappear(perform: cancelTrial)
        }
    }

    private var selectedSample: AIPromptSampleContext {
        if source == .recent, let recentSample = viewModel.recentSample {
            return recentSample
        }
        return AIPromptRequestBuilder.builtInSample(for: viewModel.kind)
    }

    /// Sheet 持有本次运行 Task；关闭或交互式下滑时取消父任务会连带取消当前与默认对照请求。
    private func startTrial() {
        let sample = selectedSample
        let shouldCompareDefault = comparesDefault
        runTask?.cancel()
        runTask = Task { @MainActor in
            await viewModel.runTrial(
                sample: sample,
                comparesDefault: shouldCompareDefault
            )
        }
    }

    private func close() {
        cancelTrial()
        dismiss()
    }

    private func cancelTrial() {
        runTask?.cancel()
        runTask = nil
        viewModel.cancelTrial()
    }
}

/// P1 字段优化页；建议先对照当前文本，只有用户点击应用才修改本地草稿。
struct AIPromptOptimizationSheet: View {
    @Bindable var viewModel: AIPromptEditorViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var optimizationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "例如：更简洁，减少重复要求",
                        text: $viewModel.optimizationInstruction,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .disabled(viewModel.isOptimizing)

                    Text("将发起 1 次 AI 请求，只发送当前字段和调整期望。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Section {
                    Button {
                        startOptimization()
                    } label: {
                        HStack {
                            Text(viewModel.isOptimizing ? "生成中…" : "生成建议")
                            Spacer()
                            if viewModel.isOptimizing { ProgressView() }
                        }
                    }
                    .disabled(
                        viewModel.isOptimizing
                            || viewModel.optimizationInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                if let error = viewModel.optimizationErrorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(Color.feedbackError)
                    }
                }

                if let suggestion = viewModel.optimizationSuggestion {
                    Section("差异") {
                        AIPromptCompactDiffView(
                            current: viewModel.optimizationSourceText ?? viewModel.currentText,
                            suggestion: suggestion
                        )
                    }
                    Section {
                        Button("应用修改") {
                            guard viewModel.applyOptimizationSuggestion() else { return }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("优化\(String(localized: viewModel.activeField.displayTitle))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { close() }
                }
            }
            .onChange(of: viewModel.activeField) { _, _ in
                cancelOptimization()
            }
            .onDisappear(perform: cancelOptimization)
        }
    }

    /// Sheet 持有优化 Task；字段变化、关闭按钮或交互式下滑都会取消网络并使 request ID 失效。
    private func startOptimization() {
        optimizationTask?.cancel()
        optimizationTask = Task { @MainActor in
            await viewModel.optimizeCurrentField()
        }
    }

    private func close() {
        cancelOptimization()
        dismiss()
    }

    private func cancelOptimization() {
        optimizationTask?.cancel()
        optimizationTask = nil
        viewModel.cancelOptimization()
    }
}

/// 只展示最长公共前后文之间的删除与新增片段，避免把两份长提示词并排形成视觉噪音。
private struct AIPromptCompactDiffView: View {
    let current: String
    let suggestion: String

    var body: some View {
        let difference = compactDifference
        VStack(alignment: .leading, spacing: Spacing.base) {
            if difference.removed.isEmpty && difference.added.isEmpty {
                Text("没有文字变化")
                    .foregroundStyle(Color.textSecondary)
            } else {
                if !difference.removed.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Label("删除", systemImage: "minus")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.feedbackError)
                        Text(difference.removed)
                            .strikethrough()
                            .foregroundStyle(Color.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                if !difference.added.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Label("新增", systemImage: "plus")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.feedbackSuccess)
                        Text(difference.added)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var compactDifference: (removed: String, added: String) {
        let oldCharacters = Array(current)
        let newCharacters = Array(suggestion)
        var prefixCount = 0
        while prefixCount < min(oldCharacters.count, newCharacters.count),
              oldCharacters[prefixCount] == newCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < oldCharacters.count - prefixCount,
              suffixCount < newCharacters.count - prefixCount,
              oldCharacters[oldCharacters.count - suffixCount - 1]
                == newCharacters[newCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        let oldEnd = oldCharacters.count - suffixCount
        let newEnd = newCharacters.count - suffixCount
        return (
            String(oldCharacters[prefixCount..<oldEnd]),
            String(newCharacters[prefixCount..<newEnd])
        )
    }
}
