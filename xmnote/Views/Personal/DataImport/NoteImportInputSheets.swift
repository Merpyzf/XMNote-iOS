/**
 * [INPUT]: 依赖来源说明、XMSheetScaffold、系统文本编辑器和原文草稿回调
 * [OUTPUT]: 提供离线可读的来源帮助与有退出保护的原文编辑 Sheet
 * [POS]: Views/Personal/DataImport 的功能私有辅助界面，编辑完成不触发导入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 来源说明随应用提供，在线手册仅作为额外帮助，不阻断离线导入。
struct NoteImportGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    let guide: NoteImportSourceGuide

    var body: some View {
        XMSheetScaffold(title: guide.helpTitle, subtitle: guide.title, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                NoteImportInstructionList(steps: guide.steps)
                if !guide.additionalDetails.isEmpty {
                    Text("准备文件")
                        .font(AppTypography.headline)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(guide.additionalDetails, id: \.self) { detail in
                        Text(detail).font(AppTypography.callout).textSelection(.enabled)
                    }
                }
                Text(guide.caution)
                    .font(AppTypography.callout)
                    .foregroundStyle(Color.textSecondary)
                Text("无法识别时")
                    .font(AppTypography.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(guide.input.isFile
                     ? "请确认文件来自当前来源，且导出过程已完成。不要通过修改后缀转换格式。文件仍在云端时，请检查网络后重试。"
                     : "请重新复制完整笔记，不要只复制一段正文。编辑原文时保留书籍信息、换行和来源标记。")
                    .font(AppTypography.callout)
                    .foregroundStyle(Color.textSecondary)
                if let url = guide.manualURL {
                    Link("查看完整图文手册", destination: url)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.linkForeground)
                        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                }
            }
            .frame(maxWidth: NoteImportSourceLayout.readableWidth, alignment: .leading)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.screenEdge)
            .frame(maxWidth: .infinity)
        }
        .presentationDetents([.large])
    }
}

/// 长原文使用独立编辑器作为唯一滚动 owner，不嵌入 scaffold 的第二层滚动容器。
struct NoteImportClipboardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var draft: String
    @State private var showsDiscardConfirmation = false
    private let original: String
    private let onSave: (String) -> Void

    /// 快照隔离编辑，取消不会改变父页面草稿；首次展示保持键盘隐藏以便先阅读。
    init(text: String, onSave: @escaping (String) -> Void) {
        original = text
        self.onSave = onSave
        _draft = State(initialValue: text)
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectStyle(.soft, for: .all)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: NoteImportSourceLayout.readableWidth)
                .padding(.horizontal, Spacing.screenEdge)
                .frame(maxWidth: .infinity)
                .background(Color.surfaceSheet)
                .safeAreaBar(edge: .top, spacing: Spacing.none) {
                    Text("请保留书名、分隔符和来源标记，以免影响识别。")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: NoteImportSourceLayout.readableWidth, alignment: .leading)
                        .padding(Spacing.screenEdge)
                        .frame(maxWidth: .infinity)
                }
                .navigationTitle("查看与编辑原文")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消", action: requestClose).xmToolbarNeutralTint()
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", action: save)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(hasChanges)
        .background {
            NoteImportEditorDismissGuard(hasChanges: hasChanges, onAttempt: requestClose)
        }
        .xmSystemAlert(isPresented: $showsDiscardConfirmation, descriptor: .init(
            title: "放弃原文修改？", message: "本次修改将不会保留。", actions: [
                .init(title: "继续编辑", role: .cancel) { showsDiscardConfirmation = false },
                .init(title: "放弃修改", role: .destructive) { isFocused = false; dismiss() }
            ]
        ))
    }

    /// 结束焦点后确认放弃修改；未编辑时直接退出。
    private func requestClose() {
        isFocused = false
        if hasChanges { showsDiscardConfirmation = true } else { dismiss() }
    }

    /// 完成只回写当前输入草稿，不触碰系统剪贴板或数据库。
    private func save() {
        isFocused = false
        onSave(draft)
        dismiss()
    }
}

/// 仅为本编辑 Sheet 观察系统被阻止的下拉退出，继续把其他 presentation 回调交给原 delegate。
private struct NoteImportEditorDismissGuard: UIViewControllerRepresentable {
    let hasChanges: Bool
    let onAttempt: () -> Void

    /// 创建透明观察宿主，不持有第二个滚动容器或手势。
    func makeUIViewController(context: Context) -> ObserverController { ObserverController() }

    /// MainActor 同步最新草稿状态与回调；不安排延迟任务或跨场景观察。
    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.hasChanges = hasChanges
        controller.onAttempt = onAttempt
        controller.attach()
    }

    /// 仅在仍然拥有 delegate 时恢复原关系，避免覆盖后续系统配置。
    static func dismantleUIViewController(_ controller: ObserverController, coordinator: ()) {
        controller.detach()
    }

    /// 通过公开父控制器链寻找当前 Sheet，保留 SwiftUI 原有的适配和关闭通知。
    final class ObserverController: UIViewController, UIAdaptivePresentationControllerDelegate {
        var hasChanges = false
        var onAttempt: (() -> Void)?
        private weak var observed: UIPresentationController?
        private weak var previous: (any UIAdaptivePresentationControllerDelegate)?

        /// 系统完成挂载后建立观察，避免创建时 presentation 尚不存在。
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        /// 草稿更新导致系统重配 presentation 时重新接入，不改变布局。
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attach()
        }

        /// 仅接管本 Sheet 的适配代理，并保存被替换的系统 delegate。
        func attach() {
            var owner: UIViewController? = parent
            while let current = owner {
                if let presentation = current.presentationController, current.presentingViewController != nil {
                    if presentation.delegate === self { return }
                    detach()
                    observed = presentation
                    previous = presentation.delegate
                    presentation.delegate = self
                    return
                }
                owner = current.parent
            }
        }

        /// 销毁前恢复系统观察并释放闭包，不影响另一个 presentation。
        func detach() {
            if observed?.delegate === self { observed?.delegate = previous }
            observed = nil
            previous = nil
        }

        /// 未编辑时尊重系统原有关闭决策，编辑后阻止丢失草稿。
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !hasChanges && (previous?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }

        /// 只在系统确实阻止下拉时弹出退出确认，不模拟 Sheet 手势。
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if hasChanges { onAttempt?() }
            else { previous?.presentationControllerDidAttemptToDismiss?(presentationController) }
        }

        /// 保留原 delegate 的其余可选方法，使 SwiftUI 继续拥有 presentation 生命周期。
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (previous?.responds(to: selector) ?? false)
        }

        /// 将未实现的适配通知转发给原 delegate。
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previous?.responds(to: selector) == true { return previous }
            return super.forwardingTarget(for: selector)
        }
    }
}

#Preview("原文编辑") {
    NoteImportClipboardEditor(text: "书名\n\n一段完整的书摘内容。\n\n-- 来自微信读书") { _ in }
}

#Preview("阅读导入说明") {
    NoteImportGuideSheet(guide: .init(title: "阅读", input: .file(parserID: .legado)))
}
