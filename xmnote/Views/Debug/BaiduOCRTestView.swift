#if DEBUG
/**
 * [INPUT]: 依赖 RepositoryContainer 注入 OCR 仓储，依赖 BaiduOCRTestViewModel 驱动状态，依赖 BaiduOCRFlowView 承接 Android 对齐的全屏 OCR 流程
 * [OUTPUT]: 对外提供 BaiduOCRTestView（百度 OCR SDK 调试宿主页）
 * [POS]: Debug 模块百度 OCR 宿主页，负责展示双编辑区、启动 OCR Flow 并消费识别回填结果
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct BaiduOCRTestView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel = BaiduOCRTestViewModel()
    @State private var activeFlowTarget: OCRFlowTarget?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                capabilitySection
                editorSection(
                    title: OCRFlowTarget.content.title,
                    placeholder: "识别结果会追加到这里，也可以手动编辑验证格式能力。",
                    text: $viewModel.contentText,
                    formats: $viewModel.contentFormats,
                    target: .content,
                    height: 220
                )
                editorSection(
                    title: OCRFlowTarget.idea.title,
                    placeholder: "点击“想法 OCR”后，识别结果会回填到这里。",
                    text: $viewModel.ideaText,
                    formats: $viewModel.ideaFormats,
                    target: .idea,
                    height: 180
                )
                highlightSection
                summarySection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("百度 OCR")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeFlowTarget) { target in
            BaiduOCRFlowView(
                target: target,
                repository: repositories.ocrRepository,
                onComplete: { payload in
                    viewModel.applyFlowCompletion(payload)
                }
            )
        }
    }
}

private extension BaiduOCRTestView {
    var capabilitySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("交互流程")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("当前测试页已改为 Android 对齐的独立 OCR Flow：进入拍照/选图页，再进入裁切识别页，成功后自动回到宿主页。")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    capabilityBadge(
                        title: isRuntimeSupported ? "真机可用" : "模拟器仅验证 UI",
                        tint: isRuntimeSupported ? Color.brand : Color.feedbackWarning
                    )
                }

                Text(runtimeHintText)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                HStack(spacing: Spacing.half) {
                    capabilityBadge(title: "单框裁切", tint: Color.brand)
                    capabilityBadge(title: "自由框选", tint: Color.brandDeep)
                    capabilityBadge(title: "自动回填", tint: Color.textSecondary)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func editorSection(
        title: String,
        placeholder: String,
        text: Binding<NSAttributedString>,
        formats: Binding<Set<RichTextFormat>>,
        target: OCRFlowTarget,
        height: CGFloat
    ) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("点击下方按钮会进入独立 OCR Flow。")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    Button(target.actionTitle) {
                        activeFlowTarget = target
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
                }

                RichTextEditor(
                    attributedText: text,
                    activeFormats: formats,
                    placeholder: placeholder,
                    isEditable: true,
                    highlightARGB: viewModel.selectedHighlightARGB
                )
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                )
            }
            .padding(Spacing.contentEdge)
        }
    }

    var highlightSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("高亮色板")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                HighlightColorPicker(selectedARGB: $viewModel.selectedHighlightARGB)
            }
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    var summarySection: some View {
        if let summary = viewModel.lastRecognitionSummary {
            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最近一次识别")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text("来源：\(summary.sourceTitle) · 回填：\(summary.target.title)")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                        capabilityBadge(
                            title: summary.selectionMode.title,
                            tint: summary.selectionMode == .single ? Color.brand : Color.brandDeep
                        )
                    }

                    HStack(spacing: Spacing.half) {
                        capabilityBadge(title: "\(summary.regionCount) 个区域", tint: Color.brand)
                        capabilityBadge(title: "\(summary.totalLineCount) 行", tint: Color.brandDeep)
                        capabilityBadge(title: "\(summary.totalCharacterCount) 字", tint: Color.textSecondary)
                    }

                    Text(summary.combinedText)
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.base)
                        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))

                    ForEach(Array(summary.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: Spacing.half) {
                            Text("区域 \(index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.textSecondary)
                            if let logID = item.result.logID, !logID.isEmpty {
                                capabilityBadge(title: "log_id \(logID)", tint: Color.textSecondary)
                            }
                            Text(item.result.rawJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Spacing.base)
                                .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                        }
                    }
                }
                .padding(Spacing.contentEdge)
            }
        }
    }

    func capabilityBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    var isRuntimeSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    var runtimeHintText: String {
        if isRuntimeSupported {
            return "真机可完整验证拍照、相册、裁切、自由框选和 SDK 识别回填。"
        }
        return "模拟器没有可用相机预览，建议使用相册验证 Flow 与多框交互。"
    }
}

#Preview {
    NavigationStack {
        BaiduOCRTestView()
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    }
}
#endif
