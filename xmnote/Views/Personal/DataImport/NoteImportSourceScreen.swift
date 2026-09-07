/**
 * [INPUT]: 依赖带平台角标的插画页头、结构化准备步骤、来源说明、输入状态 owner、RepositoryContainer、导入交互式玻璃主按钮与系统文件/剪贴板入口
 * [OUTPUT]: 提供统一的准备说明、文件多选清单、剪贴板草稿入口与显式预览操作
 * [POS]: Views/Personal/DataImport 的通用输入页，不承担最终导入写入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 将来源准备、输入检查与预览入口组合为同一全屏任务页面。
struct NoteImportSourceScreen: View {
    typealias Input = NoteImportSourceInput
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    let title: String
    let input: Input
    let showsCancel: Bool
    @State private var model: NoteImportSourceModel
    @State private var isPickingFile = false
    @State private var showsHelp = false
    @State private var showsEditor = false
    @State private var alert: XMSystemAlertDescriptor?

    /// 输入状态只创建一次，保留预览返回和帮助关闭后的选择。
    init(title: String, input: Input, showsCancel: Bool = true) {
        self.title = title
        self.input = input
        self.showsCancel = showsCancel
        _model = State(initialValue: NoteImportSourceModel(input: input))
    }

    private var guide: NoteImportSourceGuide { .init(title: title, input: input) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.double) {
                introduction
                if model.hasInput {
                    if input.isFile { fileSelection } else { clipboardSummary }
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.feedbackError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("无法预览。\(error)")
                }
            }
            .frame(maxWidth: NoteImportSourceLayout.readableWidth, alignment: .leading)
            .padding(Spacing.screenEdge)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.always)
        .background(Color.surfacePage)
        .safeAreaBar(edge: .bottom, spacing: Spacing.none) { primaryAction }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(showsCancel && !model.opensPreview)
        .toolbar {
            if showsCancel && !model.opensPreview {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: requestCancel).xmToolbarNeutralTint()
                }
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: guide.contentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.addFiles(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsHelp) { NoteImportGuideSheet(guide: guide) }
        .sheet(isPresented: $showsEditor) {
            NoteImportClipboardEditor(text: model.clipboardText) { text in
                model.setClipboard(text, edited: model.hasEditedClipboard || text != model.clipboardText)
            }
        }
        .navigationDestination(isPresented: $model.opensPreview) {
            UnifiedNoteImportPreviewView(books: model.parsedBooks, repository: repositories.noteImportRepository)
        }
        .onDisappear { model.cancelParsing() }
        .xmSystemAlert(isPresented: alertPresented, descriptor: alert)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            NoteImportHero(
                illustration: guide.illustration,
                title: guide.heading,
                subtitle: guide.subtitle,
                isCompact: model.hasInput,
                platform: guide.platform
            )
            if !model.hasInput {
                NoteImportPreparationSteps(steps: guide.preparationSteps)
            }
            NoteImportHelpButton(title: guide.helpTitle) { showsHelp = true }
                .disabled(model.isParsing)
        }
    }

    private var fileSelection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack {
                Text("已选择 \(model.files.count) 个文件")
                    .font(AppTypography.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.base)
                Button("添加文件") { isPickingFile = true }
                    .font(AppTypography.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.textPrimary)
                    .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                    .disabled(model.isParsing)
            }
            ForEach(model.files) { file in
                Divider()
                HStack(alignment: .top, spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(file.access.url.lastPathComponent)
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Spacing.base) {
                            Text(file.access.url.pathExtension.uppercased())
                            if let count = file.access.byteCount {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))
                            }
                        }
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        if let error = file.error {
                            Text(error)
                                .font(AppTypography.footnote)
                                .foregroundStyle(Color.feedbackError)
                        } else if !file.books.isEmpty {
                            Text("已识别 \(file.books.count) 本书")
                                .font(AppTypography.footnote)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    Button { model.removeFile(file.id) } label: {
                        Image(systemName: "xmark")
                            .frame(minWidth: InteractionMetrics.minimumTouchTarget, minHeight: InteractionMetrics.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.iconSecondary)
                    .accessibilityLabel("移除\(file.access.url.lastPathComponent)")
                    .disabled(model.isParsing)
                }
            }
        }
    }

    private var clipboardSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Divider()
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text(model.hasEditedClipboard ? "原文已编辑" : "已读取剪贴板")
                    .font(AppTypography.headline)
                Text("共 \(model.clipboardText.count) 个字符")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.double) { clipboardActions }
                VStack(alignment: .leading, spacing: Spacing.half) { clipboardActions }
            }
            .buttonStyle(.plain)
            .font(AppTypography.body)
            .foregroundStyle(Color.textPrimary)
            .disabled(model.isParsing)
        }
    }

    @ViewBuilder private var clipboardActions: some View {
        Button("查看与编辑") { showsEditor = true }
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        Button("重新读取", action: requestReadClipboard)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
    }

    private var primaryAction: some View {
        VStack(spacing: Spacing.base) {
            NoteImportPreviewHint()
            if model.hasFileErrors && model.successfulFileCount > 0 {
                Button("仅预览成功的 \(model.successfulFileCount) 个文件") { model.previewSuccessfulFiles() }
                    .font(AppTypography.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.textPrimary)
                    .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                    .disabled(model.isParsing)
            }
            Button(action: performPrimaryAction) {
                HStack(spacing: Spacing.cozy) {
                    if model.isParsing { ProgressView().controlSize(.small).tint(Color.buttonDisabledForeground) }
                    Text(model.isParsing ? model.progressText : primaryTitle)
                        .font(AppTypography.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NoteImportPrimaryButtonStyle())
            .disabled(model.isParsing)
        }
        .frame(maxWidth: NoteImportSourceLayout.readableWidth)
        .padding(Spacing.screenEdge)
        .frame(maxWidth: .infinity)
    }

    private var primaryTitle: String {
        if !model.hasInput { return guide.primaryTitle }
        return model.hasFileErrors ? "重试未成功的文件" : "预览书摘"
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
    }

    /// 唯一主操作根据是否已有输入切换获取与解析，不在读取完成后自动跳转。
    private func performPrimaryAction() {
        if model.hasInput {
            let registry = NoteImportParserRegistry(attachmentImporter: S3NoteImportAttachmentImporter(repository: repositories.s3UploadRepository))
            model.parse(registry: registry)
        } else if input.isFile { isPickingFile = true }
        else { readClipboard() }
    }

    /// 替换经过编辑的草稿必须先确认，取消确认不触碰剪贴板。
    private func requestReadClipboard() {
        guard model.hasEditedClipboard else { readClipboard(); return }
        alert = .init(title: "替换已编辑的原文？", message: "重新读取会替换本次编辑的内容。", actions: [
            .init(title: "保留原文", role: .cancel) { alert = nil },
            .init(title: "重新读取", role: .destructive) { alert = nil; readClipboard() }
        ])
    }

    /// 仅由可见按钮触发系统剪贴板读取；拒绝授权或空文本保留已有草稿。
    private func readClipboard() {
        guard let text = UIPasteboard.general.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.errorMessage = "未读取到文本，请先复制完整笔记，并允许纸间书摘粘贴。"
            return
        }
        model.setClipboard(text, edited: false)
    }

    /// 取消有输入的任务前确认；实际离场先取消解析并使所有异步回写失效。
    private func requestCancel() {
        model.cancelParsing()
        guard model.hasInput else { dismissTask(); return }
        alert = .init(title: "取消本次导入？", message: "本次选择和编辑将不会保留，原文件与剪贴板不会改变。", actions: [
            .init(title: "继续导入", role: .cancel) { alert = nil },
            .init(title: "取消导入", role: .destructive) { alert = nil; dismissTask() }
        ])
    }

    /// 主线程取消当前请求后退出，保证关闭的任务不会再次进入预览。
    private func dismissTask() {
        model.cancelParsing()
        navigationCoordinator.dismissTask()
    }
}

/// 功能内容的最大阅读宽度，不扩展为设计系统全局令牌。
enum NoteImportSourceLayout {
    static let readableWidth: CGFloat = 600
}

/// 用对齐和留白组织步骤，不使用装饰性卡片或中心圆点分隔信息。
struct NoteImportInstructionList: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    Text("\(index + 1)")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .monospacedDigit()
                    Text(step)
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
