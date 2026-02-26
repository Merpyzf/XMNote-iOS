import SwiftUI
import UIKit

/// SwiftUI 入口：UIViewRepresentable 桥接 RichTextEditorView
struct RichTextEditor: UIViewRepresentable {

    @Binding var attributedText: NSAttributedString
    @Binding var activeFormats: Set<RichTextFormat>
    var placeholder: String = ""
    var isEditable: Bool = true
    var highlightARGB: UInt32 = HighlightColors.defaultHighlightColor
    var linkColor: UIColor? = nil
    var isLinkUnderline: Bool = true
    var onTextChange: (() -> Void)?

    func makeUIView(context: Context) -> RichTextEditorView {
        let editorView = RichTextEditorView()
        editorView.delegate = context.coordinator
        editorView.isEditable = isEditable
        editorView.isScrollEnabled = true
        editorView.linkColor = linkColor
        editorView.isLinkUnderline = isLinkUnderline

        // 设置 inputAccessoryView（工具栏）
        context.coordinator.currentHighlightARGB = highlightARGB
        let toolbar = RichTextToolbar { action in
            context.coordinator.handleToolbarAction(action, editorView: editorView)
        } onClearFormats: {
            context.coordinator.handleClearFormats(editorView: editorView)
        } onDismissKeyboard: {
            editorView.resignFirstResponder()
        }
        toolbar.textView = editorView
        editorView.inputAccessoryView = toolbar

        // 初始内容
        if attributedText.length > 0 {
            editorView.attributedText = attributedText
        }

        return editorView
    }

    func updateUIView(_ editorView: RichTextEditorView, context: Context) {
        editorView.isEditable = isEditable
        editorView.linkColor = linkColor
        editorView.isLinkUnderline = isLinkUnderline
        context.coordinator.currentHighlightARGB = highlightARGB

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
        }
    }

    func makeCoordinator() -> RichTextCoordinator {
        RichTextCoordinator(self)
    }
}
