/**
 * [INPUT]: 依赖 RichTextEditor 浮动挂饰模式与 SwiftUI safeAreaBar/glassEffect，承接书摘正文/想法的全屏编辑
 * [OUTPUT]: 对外提供 NoteTextComposerView，服务 NoteEditorView 的正文与想法全屏编辑入口
 * [POS]: Views/Note/Components 的页面私有子视图，负责液态玻璃挂饰工具栏、系统 OCR 选择与键盘联动
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘正文/想法的全屏富文本编辑页，承载居中的液态玻璃挂饰工具栏。
struct NoteTextComposerView: View {
    let composerTarget: NoteEditorComposerTarget
    let title: String
    @Binding var text: NSAttributedString
    let ocrRepository: any OCRRepositoryProtocol

    @Environment(\.dismiss) private var dismiss
    @State private var activeFormats: Set<RichTextFormat> = []
    @State private var ornamentController = RichTextOrnamentController()
    @State private var showsOCRChooser = false
    @State private var showsPhotoOCRFlow = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            editor
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarGlassBackButton {
                    dismiss()
                }
            }
        }
        .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
            bottomOrnament
        }
        .confirmationDialog("选择 OCR 方式", isPresented: $showsOCRChooser) {
            if ornamentController.canCaptureTextFromCamera {
                Button("系统取词") {
                    ornamentController.send(.cameraTextCapture)
                }
            }
            if supportsPhotoOCR {
                Button("拍照 OCR") {
                    showsPhotoOCRFlow = true
                }
            }
            Button("取消", role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showsPhotoOCRFlow) {
            NotePhotoOCRFlowView(
                target: composerTarget,
                repository: ocrRepository
            ) { payload in
                ornamentController.send(.insertText(payload.summary.combinedText))
            }
        }
        .alert(
            "OCR 提示",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private extension NoteTextComposerView {
    var editor: some View {
        RichTextEditor(
            attributedText: $text,
            activeFormats: $activeFormats,
            isEditable: true,
            allowsCameraTextCapture: true,
            toolbarPresentation: .ornament(ornamentController)
        )
        .background(Color.surfacePage)
    }

    var bottomOrnament: some View {
        HStack {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: Spacing.tight) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.tight) {
                        ornamentButton("arrow.uturn.backward", isEnabled: ornamentController.canUndo) {
                            ornamentController.send(.undo)
                        }
                        ornamentButton("arrow.uturn.forward", isEnabled: ornamentController.canRedo) {
                            ornamentController.send(.redo)
                        }
                        ornamentButton("arrow.left", isEnabled: true) {
                            ornamentController.send(.moveCursorLeft)
                        }
                        ornamentButton("arrow.right", isEnabled: true) {
                            ornamentController.send(.moveCursorRight)
                        }
                        ornamentDivider
                        formatButton(.bold, systemName: "bold")
                        formatButton(.italic, systemName: "italic")
                        formatButton(.underline, systemName: "underline")
                        formatButton(.strikethrough, systemName: "strikethrough")
                        formatButton(.highlight, systemName: "highlighter")
                        ornamentButton("increase.indent", isEnabled: true) {
                            ornamentController.send(.indent)
                        }
                        ornamentDivider
                        ornamentButton("textformat", isEnabled: true) {
                            ornamentController.send(.clearFormats)
                        }
                        ornamentDivider
                        ornamentButton("text.viewfinder", isEnabled: true) {
                            if ornamentController.canCaptureTextFromCamera || supportsPhotoOCR {
                                showsOCRChooser = true
                            } else {
                                errorMessage = "当前环境不支持 OCR"
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.cozy)
                }
                .frame(maxWidth: 520)
            }
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, Spacing.cozy)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .background(Color.clear)
    }

    var ornamentDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 1, height: 18)
    }

    func formatButton(_ format: RichTextFormat, systemName: String) -> some View {
        ornamentButton(
            systemName,
            isEnabled: true,
            isActive: ornamentController.activeFormats.contains(format)
        ) {
            ornamentController.send(.toggleFormat(format))
        }
    }

    func ornamentButton(
        _ systemName: String,
        isEnabled: Bool,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.textPrimary : Color.textHint)
                .frame(width: 34, height: 34)
                .background(
                    isActive ? Color.brand.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(systemName)
    }
    var supportsPhotoOCR: Bool {
        true
    }
}
