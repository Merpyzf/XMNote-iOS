/**
 * [INPUT]: 依赖 RepositoryContainer、AIPromptEditorViewModel、原生 Picker、TextKit 命令桥接、编辑区悬浮 Liquid Glass 工具栏与系统导航/Sheet
 * [OUTPUT]: 对外提供 AIPromptEditorView，以沉浸式单编辑器、原子变量、悬浮撤销/重做工具栏和受控导航生命周期完成提示词编辑
 * [POS]: Views/Personal 的独立 push 编辑页，被 PersonalRoute.aiPromptEditor 消费，页面内子视图保持 feature-private
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 单任务提示词编辑页；主页面只保留字段切换、编辑器、紧凑校验和保存动作。
struct AIPromptEditorView: View {
    let kind: AIPromptKind

    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: AIPromptEditorViewModel?
    @State private var loadingGate = LoadingGate()

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if let viewModel {
                AIPromptEditorContentView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadingGate.isVisible {
                LoadingStateView("正在读取提示词…", style: .inline)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            loadingGate.update(intent: .read)
            let model = AIPromptEditorViewModel(kind: kind, repository: repositories.aiRepository)
            await model.load()
            guard !Task.isCancelled else { return }
            viewModel = model
            loadingGate.update(intent: .none)
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
    }
}

/// 加载后的编辑现场，集中协调焦点镜像、选区、退出保护与次级 Sheet。
private struct AIPromptEditorContentView: View {
    private enum Layout {
        static let maximumEditorWidth: CGFloat = 720
    }

    @Bindable var viewModel: AIPromptEditorViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var editorRawSelection = NSRange(location: 0, length: 0)
    @State private var isEditorFocused = false
    @State private var variableInsertionRequest: AIPromptVariableInsertionRequest?
    @State private var commandController = AIPromptEditorCommandController()
    @State private var insertionFeedbackTrigger = 0
    @State private var activeSheet: AIPromptEditorSheet?
    @State private var showsUnsavedConfirmation = false
    @State private var isExiting = false
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: Spacing.none) {
                fieldSelector
                    .padding(.bottom, Spacing.base)
                editorSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                if showsValidationArea {
                    validationArea
                        .padding(.top, Spacing.base)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.top, Spacing.base)
            .frame(
                width: min(geometry.size.width, Layout.maximumEditorWidth),
                height: geometry.size.height,
                alignment: .top
            )
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationPopGuard(
            canPop: !viewModel.hasUnsavedChanges && !viewModel.isSaving,
            onAllowedPopStart: prepareForExit,
            onDidAppear: handleNavigationDidAppear,
            onBlockedAttempt: handleDismissAttempt
        )
        .toolbar {
            toolbarContent
        }
        .sensoryFeedback(.selection, trigger: insertionFeedbackTrigger)
        .sheet(item: $activeSheet, onDismiss: scheduleEditorFocus) { sheet in
            sheetContent(sheet)
        }
        .xmSystemAlert(
            isPresented: $showsUnsavedConfirmation,
            descriptor: unsavedChangesDescriptor
        )
        .onChange(of: viewModel.activeField) { _, _ in
            viewModel.didChangeField()
            editorRawSelection = NSRange(location: 0, length: 0)
            if !isEditorFocused {
                scheduleEditorFocus()
            }
        }
    }

    private var fieldSelector: some View {
        Picker("提示词字段", selection: $viewModel.activeField) {
            ForEach(AIPromptEditorField.allCases) { field in
                Text(field.displayTitle).tag(field)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("提示词字段")
    }

    private var editorSurface: some View {
        AIPromptTokenTextEditor(
            text: currentTextBinding,
            rawSelection: $editorRawSelection,
            insertionRequest: $variableInsertionRequest,
            isFocused: $isEditorFocused,
            kind: viewModel.kind,
            field: viewModel.activeField,
            issues: viewModel.currentIssues,
            commandController: commandController,
            contentBottomInset: editorContentBottomInset
        )
        .id(viewModel.activeField)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if showsFloatingEditingBar {
                editingBar
                    .padding(.bottom, Spacing.half)
            }
        }
    }

    @ViewBuilder
    private var validationArea: some View {
        if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
            Label(errorMessage, systemImage: "exclamationmark.circle")
                .font(AppTypography.caption)
                .foregroundStyle(Color.feedbackError)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else if let issue = primaryVisibleIssue {
            HStack(spacing: Spacing.cozy) {
                Button {
                    locate(issue)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                        Image(systemName: issueSymbol(issue.severity))
                            .accessibilityHidden(true)
                        Text(issuePrefix(issue) + issue.message)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                        Spacer(minLength: 0)
                    }
                    .font(AppTypography.caption)
                    .foregroundStyle(issueColor(issue.severity))
                    .frame(
                        maxWidth: .infinity,
                        minHeight: InteractionMetrics.minimumTouchTarget,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(issue.range == nil ? "返回对应字段处理" : "选中问题位置")

                if case .missingRequired = issue.kind {
                    Button("插入") {
                        insertMissingVariable(for: issue)
                    }
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.stateActionForeground)
                    .buttonStyle(.plain)
                    .xmMinimumHitTarget(anchor: .trailing)
                    .accessibilityHint("在用户提示词的当前光标处插入必需变量")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            TopBarBackButton(action: handleDismissAttempt, isEnabled: !viewModel.isSaving)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("运行", systemImage: "play.fill") {
                presentSheet(.trial)
            }
            .labelStyle(.iconOnly)
            .xmToolbarNeutralTint()
            .disabled(!viewModel.canPresentTrial || viewModel.isSaving)

            Menu {
                Button {
                    viewModel.preparePreview()
                    guard viewModel.preview != nil else { return }
                    presentSheet(.preview)
                } label: {
                    XMMenuLabel("预览实际发送内容", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(viewModel.hasBlockingIssues)

                Button {
                    presentSheet(.optimize)
                } label: {
                    XMMenuLabel("优化当前提示词", systemImage: "wand.and.sparkles")
                }

                Button {
                    presentSheet(.explanation)
                } label: {
                    XMMenuLabel("提示词说明", systemImage: "info.circle")
                }

                Divider()

                Button("恢复当前字段", systemImage: "arrow.counterclockwise") {
                    viewModel.resetCurrentField()
                }

                Button("全部恢复默认", systemImage: "arrow.trianglehead.2.counterclockwise") {
                    resetAllFieldsWithUndo()
                }
            } label: {
                Label("更多", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .xmMenuNeutralTint()
            .disabled(viewModel.isSaving)
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: saveAndDismiss) {
                ZStack {
                    Image(systemName: "checkmark")
                        .opacity(viewModel.isSaving ? 0 : 1)
                    if viewModel.isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.primaryActionForeground)
                    }
                }
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.primaryActionForeground)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(Color.primaryActionFill)
            .disabled(!viewModel.canSave)
            .accessibilityLabel(viewModel.isSaving ? "保存中" : "保存")
        }
    }

    private var currentTextBinding: Binding<String> {
        Binding(
            get: { viewModel.currentText },
            set: { value in
                viewModel.currentText = value
                viewModel.errorMessage = nil
            }
        )
    }

    private var insertedVariableNames: Set<String> {
        Set(viewModel.variables.filter { viewModel.template.user.contains($0.placeholder) }.map(\.name))
    }

    private var editingBar: some View {
        AIPromptEditingBar(
            commandController: commandController,
            variables: viewModel.activeField == .taskTemplate ? viewModel.variables : [],
            insertedNames: insertedVariableNames,
            onInsert: insertVariable
        )
    }

    private var showsFloatingEditingBar: Bool {
        !isExiting && isEditorFocused && activeSheet == nil
    }

    private var editorContentBottomInset: CGFloat {
        showsFloatingEditingBar
            ? AIPromptEditorAppearance.Metrics.barHeight + Spacing.double
            : Spacing.none
    }

    private var showsValidationArea: Bool {
        !(viewModel.errorMessage?.isEmpty ?? true) || primaryVisibleIssue != nil
    }

    private var unsavedChangesDescriptor: XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "保存修改？",
            actions: [
                XMSystemAlertAction(
                    title: "保存并退出",
                    isEnabled: !viewModel.hasBlockingIssues && !viewModel.isSaving,
                    handler: saveAndDismiss
                ),
                XMSystemAlertAction(title: "放弃修改", role: .destructive) {
                    exitAndDismiss()
                },
                XMSystemAlertAction(title: "继续编辑", role: .cancel) { }
            ]
        )
    }

    private var primaryVisibleIssue: AIPromptValidationIssue? {
        let current = viewModel.currentIssues
        if let blocking = current.first(where: \.blocksSaving) { return blocking }
        if let otherBlocking = viewModel.allIssues.first(where: \.blocksSaving) { return otherBlocking }
        return current.first ?? viewModel.allIssues.first
    }

    private func issuePrefix(_ issue: AIPromptValidationIssue) -> String {
        issue.field == viewModel.activeField
            ? ""
            : "\(String(localized: issue.field.displayTitle))："
    }

    private func issueSymbol(_ severity: AIPromptValidationSeverity) -> String {
        switch severity {
        case .error:
            "exclamationmark.circle"
        case .warning:
            "exclamationmark.triangle"
        case .information:
            "info.circle"
        }
    }

    private func issueColor(_ severity: AIPromptValidationSeverity) -> Color {
        switch severity {
        case .error:
            .feedbackError
        case .warning:
            .feedbackWarning
        case .information:
            .feedbackWarning
        }
    }

    private func locate(_ issue: AIPromptValidationIssue) {
        let targetText = issue.field == .taskTemplate
            ? viewModel.template.user
            : viewModel.template.system
        viewModel.activeField = issue.field
        Task { @MainActor in
            await Task.yield()
            if let range = issue.range,
               let rawRange = AIPromptTokenTextEditor.rawNSRange(for: range, in: targetText) {
                editorRawSelection = rawRange
            }
            isEditorFocused = true
        }
    }

    private func insertMissingVariable(for issue: AIPromptValidationIssue) {
        guard case .missingRequired(let name) = issue.kind,
              let definition = viewModel.variables.first(where: { $0.name == name }) else {
            return
        }
        viewModel.activeField = .taskTemplate
        insertVariable(definition)
    }

    private func insertVariable(_ variable: AIPromptVariableDefinition) {
        guard viewModel.activeField == .taskTemplate else { return }
        variableInsertionRequest = AIPromptVariableInsertionRequest(variable: variable)
        isEditorFocused = true
        insertionFeedbackTrigger += 1
    }

    /// 把双字段恢复作为当前 TextView 的单个撤销事务；弱引用避免历史闭包延长页面状态生命周期。
    private func resetAllFieldsWithUndo() {
        let before = viewModel.template
        let after = viewModel.defaultTemplate
        commandController.performTemplateChange(
            before: before,
            after: after,
            actionName: "全部恢复默认"
        ) { [weak viewModel] template in
            viewModel?.applyDraftTemplate(template)
        }
    }

    private func handleDismissAttempt() {
        guard !viewModel.isSaving, !isExiting else { return }
        if viewModel.hasUnsavedChanges {
            showsUnsavedConfirmation = true
        } else {
            exitAndDismiss()
        }
    }

    /// 次级流程呈现前先结束正文编辑，避免键盘与悬浮工具栏压缩 Sheet 的可用空间。
    private func presentSheet(_ sheet: AIPromptEditorSheet) {
        focusTask?.cancel()
        isEditorFocused = false
        Task { @MainActor in
            await Task.yield()
            guard !isExiting else { return }
            activeSheet = sheet
        }
    }

    /// 保存任务由页面生命周期持有；保存失败不收起键盘或改写选区。
    private func saveAndDismiss() {
        Task { @MainActor in
            guard await viewModel.save() else { return }
            exitAndDismiss()
        }
    }

    /// 导航控制器确认页面已完整出现后再建立焦点；任务可取消，退出或 Sheet 呈现时不会回抢键盘。
    @MainActor
    private func scheduleEditorFocus() {
        focusTask?.cancel()
        guard !isExiting, activeSheet == nil else { return }
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, !isExiting, activeSheet == nil else { return }
            isEditorFocused = true
        }
    }

    /// 初次 push 完成或交互式返回取消后恢复编辑现场；已完成的返回不会再次触发该页面。
    @MainActor
    private func handleNavigationDidAppear() {
        isExiting = false
        scheduleEditorFocus()
    }

    /// 在任何允许返回的路径开始前同步关闭焦点与悬浮底栏；重复调用不会产生额外副作用。
    @MainActor
    private func prepareForExit() {
        guard !isExiting else { return }
        isExiting = true
        focusTask?.cancel()
        focusTask = nil
        isEditorFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// 程序化返回先给 SwiftUI 一个更新周期拆下悬浮栏，再交给系统导航执行 push 的逆转场。
    @MainActor
    private func exitAndDismiss() {
        guard !isExiting else { return }
        prepareForExit()
        Task { @MainActor in
            await Task.yield()
            guard isExiting else { return }
            dismiss()
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AIPromptEditorSheet) -> some View {
        switch sheet {
        case .preview:
            if let preview = viewModel.preview {
                AIPromptPreviewSheet(
                    editableRoleRules: viewModel.template.system,
                    preview: preview
                )
            }
        case .trial:
            AIPromptTrialSheet(
                kind: viewModel.kind,
                template: viewModel.template,
                aiRepository: repositories.aiRepository,
                noteRepository: repositories.noteRepository
            )
        case .optimize:
            AIPromptOptimizationSheet(viewModel: viewModel)
        case .explanation:
            AIPromptExplanationSheet()
                .presentationDetents(explanationDetents)
                .presentationDragIndicator(dynamicTypeSize.isAccessibilitySize ? .visible : .hidden)
        }
    }

    private var explanationDetents: Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.medium]
    }

}

private enum AIPromptEditorSheet: String, Identifiable {
    case preview
    case trial
    case optimize
    case explanation

    var id: String { rawValue }
}

/// 浮在编辑内容上方的单行操作区；撤销组与变量组保持两个独立玻璃轮廓。
private struct AIPromptEditingBar: View {
    let commandController: AIPromptEditorCommandController
    let variables: [AIPromptVariableDefinition]
    let insertedNames: Set<String>
    let onInsert: (AIPromptVariableDefinition) -> Void

    var body: some View {
        HStack(spacing: AIPromptEditorAppearance.Metrics.groupSpacing) {
            AIPromptCommandBar(commandController: commandController)

            if !variables.isEmpty {
                AIPromptVariableBar(
                    variables: variables,
                    insertedNames: insertedNames,
                    onInsert: onInsert
                )
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 撤销与重做共享一个 88×44pt 玻璃 Capsule；可见图标不因命中范围被放大。
private struct AIPromptCommandBar: View {
    let commandController: AIPromptEditorCommandController

    var body: some View {
        HStack(spacing: Spacing.none) {
            commandButton(
                systemImageName: AIPromptEditorAppearance.undoSystemImageName,
                label: "撤销",
                isEnabled: commandController.canUndo,
                action: commandController.undo
            )
            commandButton(
                systemImageName: AIPromptEditorAppearance.redoSystemImageName,
                label: "重做",
                isEnabled: commandController.canRedo,
                action: commandController.redo
            )
        }
        .frame(
            width: AIPromptEditorAppearance.Metrics.commandBarWidth,
            height: AIPromptEditorAppearance.Metrics.barHeight
        )
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// 每个命令占据 44pt 触控列，图标只保持紧凑的 17pt 视觉尺寸。
    private func commandButton(
        systemImageName: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .symbolRenderingMode(.monochrome)
                .font(.system(
                    size: AIPromptEditorAppearance.Metrics.commandIconSize,
                    weight: .semibold
                ))
                .frame(
                    width: AIPromptEditorAppearance.Metrics.commandIconSize,
                    height: AIPromptEditorAppearance.Metrics.commandIconSize
                )
                .foregroundStyle(isEnabled ? Color.iconPrimary : Color.textHint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            width: AIPromptEditorAppearance.Metrics.barHeight,
            height: AIPromptEditorAppearance.Metrics.barHeight
        )
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// 变量栏仅由外层 Capsule 承载 Liquid Glass；内部 Chip 是可重复执行的插入命令。
private struct AIPromptVariableBar: View {
    let variables: [AIPromptVariableDefinition]
    let insertedNames: Set<String>
    let onInsert: (AIPromptVariableDefinition) -> Void

    @ScaledMetric(relativeTo: .caption) private var chipVisualHeight = AIPromptEditorAppearance.Metrics.chipHeight
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.half) {
                chips
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Spacing.cozy, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollBounceBehavior(.always)
        .frame(maxWidth: .infinity)
        .frame(height: AIPromptEditorAppearance.Metrics.barHeight)
        .compositingGroup()
        .clipShape(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(variables) { variable in
            let isInserted = insertedNames.contains(variable.name)
            let presentation = AIPromptEditorAppearance.presentation(for: variable)
            Button {
                onInsert(variable)
            } label: {
                HStack(spacing: AIPromptEditorAppearance.Metrics.chipIconSpacing) {
                    Image(presentation.iconAssetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: AIPromptEditorAppearance.Metrics.chipIconSize,
                            height: AIPromptEditorAppearance.Metrics.chipIconSize
                        )
                        .accessibilityHidden(true)

                    Text(variable.name)
                        .font(AIPromptEditorAppearance.chipFont)
                        .lineLimit(1)
                }
                .foregroundStyle(presentation.foregroundColor)
                .padding(.horizontal, AIPromptEditorAppearance.Metrics.chipHorizontalPadding)
                .frame(height: resolvedChipVisualHeight)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(
                AIPromptVariableChipButtonStyle(
                    presentation: presentation,
                    usesEmphasizedBase: colorSchemeContrast == .increased
                )
            )
            .frame(height: AIPromptEditorAppearance.Metrics.barHeight)
            .accessibilityLabel(
                "\(variable.name)，\(variable.accessibilityRequirement)，\(isInserted ? "已插入" : "未插入")"
            )
            .accessibilityHint("双击在当前光标处插入；有选中文本时替换选区")
        }
    }

    private var resolvedChipVisualHeight: CGFloat {
        min(max(chipVisualHeight, AIPromptEditorAppearance.Metrics.chipHeight), 36)
    }
}

/// Chip 只在按压时切换同色系强调阶，不改变透明度、尺寸或相邻布局。
private struct AIPromptVariableChipButtonStyle: ButtonStyle {
    let presentation: AIPromptVariablePresentation
    let usesEmphasizedBase: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed || usesEmphasizedBase
                    ? presentation.emphasizedBackgroundColor
                    : presentation.backgroundColor,
                in: Capsule()
            )
    }
}

#Preview {
    NavigationStack {
        AIPromptEditorView(kind: .noteExplanation)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
