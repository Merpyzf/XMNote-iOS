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
        .xmSystemAlert(
            isPresented: $errorMessage.isPresented(),
            descriptor: XMSystemAlertDescriptor(
                title: "OCR 提示",
                message: errorMessage ?? "",
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) { }
                ]
            )
        )
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
                    NoteToolbarIconStrip(actions: toolbarIconActions, dividerOpacity: 0.18)
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, Spacing.cozy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, Spacing.cozy)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .background(Color.clear)
    }

    var toolbarIconActionIDs: [NoteToolbarActionID] {
        NoteToolbarActionID.androidPriorityOrder.filter { actionID in
            switch actionID {
            case .fullScreen, .choiceImage:
                return false
            case .ocr:
                return showsOCRAction
            default:
                return true
            }
        }
    }

    var toolbarIconActions: [NoteToolbarIconAction] {
        toolbarIconActionIDs.map { actionID in
            NoteToolbarIconAction(
                id: actionID,
                isEnabled: isActionEnabled(actionID),
                isActive: isActionActive(actionID),
                handler: { handleToolbarAction(actionID) }
            )
        }
    }

    func isActionEnabled(_ actionID: NoteToolbarActionID) -> Bool {
        switch actionID {
        case .undo:
            return ornamentController.canUndo
        case .redo:
            return ornamentController.canRedo
        case .ocr:
            return showsOCRAction
        case .fullScreen, .choiceImage:
            return false
        default:
            return true
        }
    }

    func isActionActive(_ actionID: NoteToolbarActionID) -> Bool {
        guard let format = actionID.format else { return false }
        return ornamentController.activeFormats.contains(format)
    }

    func handleToolbarAction(_ actionID: NoteToolbarActionID) {
        switch actionID {
        case .undo:
            ornamentController.send(.undo)
        case .redo:
            ornamentController.send(.redo)
        case .cursorLeft:
            ornamentController.send(.moveCursorLeft)
        case .cursorRight:
            ornamentController.send(.moveCursorRight)
        case .indent:
            ornamentController.send(.indent)
        case .bold:
            ornamentController.send(.toggleFormat(.bold))
        case .highlight:
            ornamentController.send(.toggleFormat(.highlight))
        case .underlined:
            ornamentController.send(.toggleFormat(.underline))
        case .italic:
            ornamentController.send(.toggleFormat(.italic))
        case .strikeThrough:
            ornamentController.send(.toggleFormat(.strikethrough))
        case .formatClear:
            ornamentController.send(.clearFormats)
        case .ocr:
            if showsOCRAction {
                showsOCRChooser = true
            } else {
                errorMessage = "当前环境不支持 OCR"
            }
        case .fullScreen, .choiceImage:
            break
        }
    }

    var showsOCRAction: Bool {
        ornamentController.canCaptureTextFromCamera || supportsPhotoOCR
    }

    var supportsPhotoOCR: Bool {
        true
    }
}
