/**
 * [INPUT]: 依赖 RichTextEditor（父视图引用）、RichTextEditorView（UITextView 子类）、RichTextToolbar（工具栏）、Foundation（String(localized:) 本地化）
 * [OUTPUT]: 对外提供 UITextViewDelegate 实现、格式状态追踪、工具栏回调处理
 * [POS]: RichTextEditor 模块的事件协调器，桥接 UIKit delegate 事件与 SwiftUI 状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit
import SwiftUI

/// UITextViewDelegate 桥接：UIKit 事件 → SwiftUI 状态
/// 对标 Android TextWatcher 的职责
final class RichTextCoordinator: NSObject, UITextViewDelegate {

    private let parent: RichTextEditor

    /// 格式操作同步 binding 时置 true，防止 updateUIView 回写覆盖
    var isSyncingToBinding = false

    /// 当前高亮色（由 updateUIView 同步），工具栏闭包读取此属性获取最新值
    var currentHighlightARGB: UInt32 = HighlightColors.defaultHighlightColor

    /// 防止重复调度 typingAttributes 边界清理
    private var hasPendingBoundaryCleanup = false

    init(_ parent: RichTextEditor) {
        self.parent = parent
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        guard let editorView = textView as? RichTextEditorView else { return }
        parent.attributedText = editorView.attributedText
        parent.onTextChange?()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let editorView = textView as? RichTextEditorView else { return }
        updateActiveFormats(editorView)
        scheduleBoundaryCleanup(editorView)
    }

    // MARK: - 格式状态检测

    /// 选区变化时，检查各格式是否激活，更新工具栏高亮状态
    func updateActiveFormats(_ editorView: RichTextEditorView) {
        let range = editorView.selectedRange
        var formats = Set<RichTextFormat>()

        for format in RichTextFormat.allCases {
            if editorView.containsFormat(format, in: range) {
                formats.insert(format)
            }
        }

        // 避免不必要的 SwiftUI 更新
        if formats != parent.activeFormats {
            parent.activeFormats = formats
        }

        // 选区变化时，始终刷新工具栏启用态和视觉态。
        // 即使 formats 未变化，也要避免按钮从禁用恢复后残留灰色。
        if let toolbar = editorView.inputAccessoryView as? RichTextToolbar {
            toolbar.updateSelectionState(hasSelection: range.length > 0)
            toolbar.updateActiveFormats(formats)
        }
    }

    // MARK: - 格式传染防护

    /// UIKit 在 textViewDidChangeSelection 返回后会从 pos-1 重新同步 typingAttributes，
    /// 覆盖 delegate 内的清理。延迟到下一个 run loop 迭代，确保在 UIKit 同步之后生效。
    private func scheduleBoundaryCleanup(_ editorView: RichTextEditorView) {
        guard !hasPendingBoundaryCleanup else { return }
        hasPendingBoundaryCleanup = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingBoundaryCleanup = false
            self.resetTypingAttributesAtBoundary(editorView)
        }
    }

    /// 模拟 Android SPAN_EXCLUSIVE_EXCLUSIVE：光标在格式边界时清除 typingAttributes 中的字符级格式
    /// 防止在格式末尾继续输入时自动继承前一字符的格式
    private func resetTypingAttributesAtBoundary(_ editorView: RichTextEditorView) {
        let range = editorView.selectedRange
        guard range.length == 0 else { return }
        let pos = range.location
        let storage = editorView.textStorage
        guard storage.length > 0 else { return }

        // ── 末尾位置：无 after 可对比，直接清除前一字符携带的格式 ──
        if pos == storage.length {
            let lastAttrs = storage.attributes(at: pos - 1, effectiveRange: nil)
            var typing = editorView.typingAttributes

            // 清除 font traits（粗体/斜体）
            if let lastFont = lastAttrs[.font] as? UIFont {
                let traits = lastFont.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) || traits.contains(.traitItalic) {
                    let baseFont = editorView.font ?? .systemFont(ofSize: 16)
                    typing[.font] = baseFont
                }
            }

            // 清除 oblique
            if lastAttrs[.obliqueItalic] != nil {
                typing.removeValue(forKey: .obliqueItalic)
                if let current = typing[.font] as? UIFont {
                    let cleanDesc = current.fontDescriptor.addingAttributes(
                        [.matrix: CGAffineTransform.identity]
                    )
                    typing[.font] = UIFont(descriptor: cleanDesc, size: current.pointSize)
                }
            }

            // 清除字符级属性
            let endKeys: [NSAttributedString.Key] = [
                .underlineStyle, .strikethroughStyle,
                .backgroundColor, .highlightColor, .link
            ]
            for key in endKeys {
                if lastAttrs[key] != nil {
                    typing.removeValue(forKey: key)
                }
            }

            editorView.typingAttributes = typing
            return
        }

        // ── pos == 0：无前文，UIKit 使用默认属性，无需干预 ──
        guard pos > 0 else { return }

        // ── 中间位置：before/after 边界对比 ──
        let attrsBefore = storage.attributes(at: pos - 1, effectiveRange: nil)
        let attrsAfter = storage.attributes(at: pos, effectiveRange: nil)

        var typing = editorView.typingAttributes

        // 粗体/斜体：检查 font traits 边界
        if let fontBefore = attrsBefore[.font] as? UIFont,
           let fontAfter = attrsAfter[.font] as? UIFont {
            let traitsBefore = fontBefore.fontDescriptor.symbolicTraits
            let traitsAfter = fontAfter.fontDescriptor.symbolicTraits

            if traitsBefore.contains(.traitBold) && !traitsAfter.contains(.traitBold) {
                if let current = typing[.font] as? UIFont,
                   let desc = current.fontDescriptor.withSymbolicTraits(current.fontDescriptor.symbolicTraits.subtracting(.traitBold)) {
                    typing[.font] = UIFont(descriptor: desc, size: current.pointSize)
                }
            }
            if traitsBefore.contains(.traitItalic) && !traitsAfter.contains(.traitItalic) {
                if let current = typing[.font] as? UIFont,
                   let desc = current.fontDescriptor.withSymbolicTraits(current.fontDescriptor.symbolicTraits.subtracting(.traitItalic)) {
                    typing[.font] = UIFont(descriptor: desc, size: current.pointSize)
                }
            }
        }

        // oblique 斜体边界
        if attrsBefore[.obliqueItalic] != nil && attrsAfter[.obliqueItalic] == nil {
            typing.removeValue(forKey: .obliqueItalic)
            if let current = typing[.font] as? UIFont {
                let cleanDesc = current.fontDescriptor.addingAttributes([.matrix: CGAffineTransform.identity])
                typing[.font] = UIFont(descriptor: cleanDesc, size: current.pointSize)
            }
        }

        // 下划线/删除线/高亮/链接：检查属性边界
        let boundaryKeys: [NSAttributedString.Key] = [
            .underlineStyle, .strikethroughStyle,
            .backgroundColor, .highlightColor, .link
        ]
        for key in boundaryKeys {
            if attrsBefore[key] != nil && attrsAfter[key] == nil {
                typing.removeValue(forKey: key)
            }
        }

        editorView.typingAttributes = typing
    }

    // MARK: - 工具栏回调

    /// 工具栏按钮触发格式切换
    func handleToolbarAction(_ format: RichTextFormat, editorView: RichTextEditorView) {
        let range = editorView.selectedRange

        // 字符级格式需要选区，段落级格式作用于光标所在行
        if range.length == 0 {
            let isParagraphFormat = (format == .bulletList || format == .blockquote)
            guard isParagraphFormat else { return }
        }

        if format == .link {
            if editorView.containsFormat(.link, in: range) {
                editorView.removeFormat(.link, in: range)
                updateActiveFormats(editorView)
                syncAttributedText(from: editorView)
            } else {
                presentLinkInput(editorView: editorView, range: range)
            }
            return
        }

        editorView.toggleFormat(format, highlightARGB: currentHighlightARGB)
        updateActiveFormats(editorView)
        syncAttributedText(from: editorView)
    }

    /// 工具栏触发链接插入
    func handleLinkAction(url: String, editorView: RichTextEditorView) {
        editorView.applyLink(url, in: editorView.selectedRange)
        updateActiveFormats(editorView)
        syncAttributedText(from: editorView)
    }

    /// 工具栏触发清除格式
    func handleClearFormats(editorView: RichTextEditorView) {
        editorView.clearFormats(in: editorView.selectedRange)
        updateActiveFormats(editorView)
        syncAttributedText(from: editorView)
    }

    // MARK: - Binding 同步

    /// 格式操作后手动同步 attributedText binding，防止 updateUIView 用旧值覆盖
    private func syncAttributedText(from editorView: RichTextEditorView) {
        isSyncingToBinding = true
        parent.attributedText = editorView.attributedText
        isSyncingToBinding = false
    }

    // MARK: - Link

    private func presentLinkInput(editorView: RichTextEditorView, range: NSRange) {
        guard range.length > 0 else { return }
        guard let presenter = topViewController(from: editorView.window?.rootViewController) else { return }
        guard !(presenter.presentedViewController is UIAlertController) else { return }

        let alert = UIAlertController(title: String(localized: "添加链接"), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "https://example.com"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.text = self.currentLinkString(in: range, editorView: editorView)
        }

        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "确定"), style: .default) { [weak self, weak editorView, weak alert] _ in
            guard let self, let editorView, let urlText = alert?.textFields?.first?.text else { return }
            let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let normalizedURL = Self.normalizeURL(trimmed)
            self.handleLinkAction(url: normalizedURL, editorView: editorView)
        })

        presenter.present(alert, animated: true)
    }

    private static func normalizeURL(_ raw: String) -> String {
        if raw.contains("://") {
            return raw
        }
        return "https://\(raw)"
    }

    private func currentLinkString(in range: NSRange, editorView: RichTextEditorView) -> String? {
        guard range.length > 0 else { return nil }
        guard range.location < editorView.textStorage.length else { return nil }
        let linkValue = editorView.textStorage.attribute(.link, at: range.location, effectiveRange: nil)
        if let url = linkValue as? URL {
            return url.absoluteString
        }
        return linkValue as? String
    }

    private func topViewController(from root: UIViewController?) -> UIViewController? {
        var current = root
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }
}
