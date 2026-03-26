/**
 * [INPUT]: 依赖 RichTextEditor 模块格式定义与 UIKit/TextKit 能力，承接富文本解析/渲染/编辑链路
 * [OUTPUT]: 对外提供 RichTextEditor 能力，用于富文本编辑器的序列化、交互或样式支持
 * [POS]: RichTextEditor 功能模块内部构件，服务 Note 编辑场景的 Android 业务意图对齐
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 富文本工具栏呈现模式：默认跟随键盘，或交由外部浮动挂饰承载。
enum RichTextToolbarPresentation {
    case inputAccessory
    case ornament(RichTextOrnamentController)
}

/// SwiftUI 入口：UIViewRepresentable 桥接 RichTextEditorView
struct RichTextEditor: UIViewRepresentable {

    @Binding var attributedText: NSAttributedString
    @Binding var activeFormats: Set<RichTextFormat>
    var placeholder: String = ""
    var isEditable: Bool = true
    var highlightARGB: UInt32 = HighlightColors.defaultHighlightColor
    var linkColor: UIColor? = nil
    var isLinkUnderline: Bool = true
    var baseFont: UIFont = .systemFont(ofSize: 16)
    var allowsCameraTextCapture: Bool = false
    var toolbarPresentation: RichTextToolbarPresentation = .inputAccessory
    var onTextChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// 创建底层 UITextView 容器并注入配置。
    func makeUIView(context: Context) -> RichTextEditorView {
        let editorView = RichTextEditorView(baseFont: baseFont)
        editorView.delegate = context.coordinator
        editorView.isEditable = isEditable
        editorView.isScrollEnabled = true
        editorView.linkColor = linkColor
        editorView.isLinkUnderline = isLinkUnderline

        context.coordinator.currentHighlightARGB = highlightARGB
        applyToolbarPresentation(to: editorView, context: context)

        // 初始内容
        if attributedText.length > 0 {
            editorView.attributedText = attributedText
        }

        return editorView
    }

    /// 同步 SwiftUI 侧可编辑状态、文本内容与工具栏高亮态到 UIKit 编辑器。
    func updateUIView(_ editorView: RichTextEditorView, context: Context) {
        context.coordinator.parent = self
        editorView.isEditable = isEditable
        editorView.linkColor = linkColor
        editorView.isLinkUnderline = isLinkUnderline
        editorView.updateBaseFont(baseFont)
        context.coordinator.currentHighlightARGB = highlightARGB
        applyToolbarPresentation(to: editorView, context: context)

        // 格式操作触发的同步不需要回写，避免用旧 binding 覆盖新格式
        guard !context.coordinator.isSyncingToBinding else {
            if let toolbar = editorView.inputAccessoryView as? RichTextToolbar {
                toolbar.updateActiveFormats(activeFormats)
            }
            return
        }

        // 仅在外部驱动变更时同步（避免循环更新）
        if editorView.attributedText != attributedText {
            editorView.attributedText = attributedText
        }

        // 同步工具栏激活状态
        if let toolbar = editorView.inputAccessoryView as? RichTextToolbar {
            toolbar.updateActiveFormats(activeFormats)
            toolbar.updateCameraTextCaptureState(
                isEnabled: allowsCameraTextCapture && isEditable && XMCameraTextCaptureSupport.canCapture(on: editorView)
            )
        }
    }

    /// 创建协调器用于处理编辑事件回调。
    func makeCoordinator() -> RichTextCoordinator {
        RichTextCoordinator(self)
    }

    var ornamentController: RichTextOrnamentController? {
        if case .ornament(let controller) = toolbarPresentation {
            return controller
        }
        return nil
    }

    private func applyToolbarPresentation(to editorView: RichTextEditorView, context: Context) {
        switch toolbarPresentation {
        case .inputAccessory:
            if editorView.inputAccessoryView == nil {
                let toolbar = RichTextToolbar(
                    onFormatAction: { action in
                        context.coordinator.handleToolbarAction(action, editorView: editorView)
                    },
                    onClearFormats: {
                        context.coordinator.handleClearFormats(editorView: editorView)
                    },
                    onCameraTextCapture: {
                        context.coordinator.handleCameraTextCapture(editorView: editorView)
                    },
                    onDismissKeyboard: {
                        editorView.resignFirstResponder()
                    },
                    showsCameraTextCapture: allowsCameraTextCapture
                )
                toolbar.textView = editorView
                editorView.inputAccessoryView = toolbar
                if editorView.isFirstResponder {
                    editorView.reloadInputViews()
                }
            }
        case .ornament(let controller):
            if editorView.inputAccessoryView != nil {
                editorView.inputAccessoryView = nil
                if editorView.isFirstResponder {
                    editorView.reloadInputViews()
                }
            }
            context.coordinator.attachOrnamentController(controller, editorView: editorView)
        }
    }
}
