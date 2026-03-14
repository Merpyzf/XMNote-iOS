#if DEBUG
/**
 * [INPUT]: 依赖 CameraTextCaptureTestViewModel 提供语言/焦点状态，依赖 RichTextEditor 与 HighlightColorPicker 作为可复用测试载体
 * [OUTPUT]: 对外提供 CameraTextCaptureTestView（系统文本识别测试页）
 * [POS]: Debug 测试页，验证系统相机取词在富文本编辑器中的可用性与语言能力信息
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct CameraTextCaptureTestView: View {
    @State private var viewModel = CameraTextCaptureTestViewModel()

    var body: some View {
        CameraTextCaptureTestContentView(viewModel: viewModel)
    }
}

private struct CameraTextCaptureTestContentView: View {
    @Bindable var viewModel: CameraTextCaptureTestViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                capabilitySection
                languageSection
                editorsSection
                instructionsSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("系统取词")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension CameraTextCaptureTestContentView {
    var capabilitySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionTitle("能力状态")

                HStack(spacing: Spacing.half) {
                    infoBadge("API", value: viewModel.isAPISupported ? "可用" : "不可用")
                    infoBadge("当前目标", value: viewModel.focusedFieldTitle)
                    infoBadge("可触发", value: viewModel.isCurrentResponderEligible ? "是" : "否")
                }

                Text("权限文案：在使用文本识别、添加附图、扫描书籍等功能时会访问设备的相机。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                Text(viewModel.cameraHintText)
                    .font(.caption)
                    .foregroundStyle(viewModel.isAPISupported ? Color.textSecondary : Color.feedbackWarning)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var languageSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack {
                    sectionTitle("语言信息")
                    Spacer()
                    Text(viewModel.supportedLanguageCountText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.brand.opacity(0.12), in: Capsule())
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: Spacing.half)],
                    alignment: .leading,
                    spacing: Spacing.half
                ) {
                    ForEach(viewModel.supportedLanguages) { language in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(language.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                            Text(language.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Color.textHint)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(
                            Color.surfaceCard,
                            in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                        )
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var editorsSection: some View {
        VStack(spacing: Spacing.base) {
            editorCard(
                title: "书摘内容",
                placeholder: "点击此处后，使用键盘上方 OCR 按钮插入识别文本。",
                text: $viewModel.contentText,
                formats: $viewModel.contentFormats,
                field: .content,
                height: 220
            )

            editorCard(
                title: "想法",
                placeholder: "这里用于验证第二个编辑目标不会串写。",
                text: $viewModel.ideaText,
                formats: $viewModel.ideaFormats,
                field: .idea,
                height: 180
            )

            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    sectionTitle("高亮色板")
                    HighlightColorPicker(selectedARGB: $viewModel.selectedHighlightARGB)
                }
                .padding(Spacing.contentEdge)
            }
        }
    }

    func editorCard(
        title: String,
        placeholder: String,
        text: Binding<NSAttributedString>,
        formats: Binding<Set<RichTextFormat>>,
        field: CameraTextCaptureTestViewModel.FocusField,
        height: CGFloat
    ) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack {
                    sectionTitle(title)
                    Spacer()
                    Text(viewModel.focusedField == field ? "已聚焦" : "未聚焦")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(viewModel.focusedField == field ? Color.brand : Color.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            (viewModel.focusedField == field ? Color.brand.opacity(0.12) : Color.surfacePage),
                            in: Capsule()
                        )
                }

                RichTextEditor(
                    attributedText: text,
                    activeFormats: formats,
                    placeholder: placeholder,
                    isEditable: true,
                    highlightARGB: viewModel.selectedHighlightARGB,
                    allowsCameraTextCapture: true,
                    onFocusChange: { isFocused in
                        viewModel.updateFocus(isFocused: isFocused, field: field)
                    }
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

    var instructionsSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionTitle("使用说明")

                Text("1. 点按任一编辑器获取焦点。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Text("2. 通过键盘上方工具栏的 OCR 按钮触发系统取词。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Text("3. 识别结果由系统直接插入光标位置，不额外拼接换行。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Text("4. 若后续业务页需要接入，只需为 RichTextEditor 打开 allowsCameraTextCapture。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Spacing.contentEdge)
        }
    }

    func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.textPrimary)
    }

    func infoBadge(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.textHint)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        CameraTextCaptureTestView()
    }
}
#endif
