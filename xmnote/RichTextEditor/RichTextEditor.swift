/**
 * [INPUT]: 依赖 RichTextEditor 模块格式定义、RichTextTypography 与 UIKit/TextKit/UIScrollEdgeEffect 能力，承接富文本解析/渲染/编辑链路、可选焦点绑定及调用方注入的编辑表层
 * [OUTPUT]: 对外提供 RichTextEditor 能力，用于富文本编辑器的序列化、交互、可控焦点、样式、背景连续性与系统滚动边缘支持
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
    var baseFont: UIFont = RichTextTypography.editorBodyUIFont
    var allowsCameraTextCapture: Bool = false
    var toolbarPresentation: RichTextToolbarPresentation = .inputAccessory
    var isBackgroundTransparent: Bool = false
    var usesSoftScrollEdgeEffects: Bool = false
    var focusBinding: Binding<Bool>? = nil
    var onTextChange: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// 创建底层 UITextView 容器并注入配置。
    func makeUIView(context: Context) -> RichTextEditorView {
        let editorView = RichTextEditorView(baseFont: baseFont)
        editorView.delegate = context.coordinator
        editorView.isEditable = isEditable
        editorView.isScrollEnabled = true
        if isBackgroundTransparent {
            editorView.backgroundColor = .clear
        }
        configureScrollEdgeEffects(for: editorView)
        editorView.linkColor = linkColor
        editorView.isLinkUnderline = isLinkUnderline

        context.coordinator.currentHighlightARGB = highlightARGB
        applyToolbarPresentation(to: editorView, context: context)
        reconcileFocus(for: editorView)

        // 初始内容
        if attributedText.length > 0 {
            editorView.setCanonicalAttributedText(attributedText)
        }

        return editorView
    }

    /// 同步 SwiftUI 侧可编辑状态、文本内容与工具栏高亮态到 UIKit 编辑器。
    func updateUIView(_ editorView: RichTextEditorView, context: Context) {
        context.coordinator.parent = self
        editorView.isEditable = isEditable
        if isBackgroundTransparent, editorView.backgroundColor != .clear {
            editorView.backgroundColor = .clear
        }
        configureScrollEdgeEffects(for: editorView)
        editorView.linkColor = linkColor
        editorView.isLinkUnderline = isLinkUnderline
        editorView.updateBaseFont(baseFont)
        context.coordinator.currentHighlightARGB = highlightARGB
        applyToolbarPresentation(to: editorView, context: context)
        reconcileFocus(for: editorView)

        // 格式操作触发的同步不需要回写，避免用旧 binding 覆盖新格式
        guard !context.coordinator.isSyncingToBinding else {
            if let toolbar = editorView.inputAccessoryView as? RichTextToolbar {
                toolbar.updateActiveFormats(activeFormats)
            }
            return
        }

        // 仅在外部驱动变更时同步（避免循环更新）
        if editorView.canonicalAttributedText() != attributedText {
            editorView.setCanonicalAttributedText(attributedText)
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

    /// 仅在调用方显式提供焦点绑定时协调 first responder；既有调用方继续由 UIKit 自主管理焦点。
    private func reconcileFocus(for editorView: RichTextEditorView) {
        guard let focusBinding else { return }
        if focusBinding.wrappedValue, isEditable, !editorView.isFirstResponder {
            editorView.becomeFirstResponder()
        } else if (!focusBinding.wrappedValue || !isEditable), editorView.isFirstResponder {
            editorView.resignFirstResponder()
        }
    }

    /// 视图离开层级时只释放自身 first responder，不向全局 responder 链广播。
    static func dismantleUIView(_ editorView: RichTextEditorView, coordinator: RichTextCoordinator) {
        if editorView.isFirstResponder {
            editorView.resignFirstResponder()
        }
        editorView.delegate = nil
    }

    var ornamentController: RichTextOrnamentController? {
        if case .ornament(let controller) = toolbarPresentation {
            return controller
        }
        return nil
    }

    /// 由真实 UITextView 滚动 owner 配置 iOS 26 系统边缘效果，避免 SwiftUI 包装层无法触达内部滚动视图。
    private func configureScrollEdgeEffects(for editorView: RichTextEditorView) {
        editorView.topEdgeEffect.style = usesSoftScrollEdgeEffects ? .soft : .automatic
        editorView.bottomEdgeEffect.style = usesSoftScrollEdgeEffects ? .soft : .automatic
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
