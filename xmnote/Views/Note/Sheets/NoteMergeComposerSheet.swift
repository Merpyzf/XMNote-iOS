/**
 * [INPUT]: 依赖 NoteTextComposerView、RichTextBridge、OCR Repository 与富文本合并草稿
 * [OUTPUT]: 对外提供 NoteMergeComposer 与 NoteMergeComposerSheet，承载正文/想法合并结果编辑
 * [POS]: Views/Note/Sheets 的书摘合并富文本业务 Sheet
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftUI

/// 标识当前编辑的是合并正文还是合并想法。
enum NoteMergeComposer: String, Identifiable {
    case content
    case idea

    var id: String { rawValue }
}

/// 富文本合并结果编辑 Sheet，复用书摘编辑器并在关闭时回写 HTML。
struct NoteMergeComposerSheet: View {
    let composer: NoteMergeComposer
    let ocrRepository: any OCRRepositoryProtocol
    let onSave: (String) -> Void

    @State private var attributedText: NSAttributedString
    @State private var showsPhotoOCR = false

    init(
        composer: NoteMergeComposer,
        initialHTML: String,
        ocrRepository: any OCRRepositoryProtocol,
        onSave: @escaping (String) -> Void
    ) {
        self.composer = composer
        self.ocrRepository = ocrRepository
        self.onSave = onSave
        _attributedText = State(
            initialValue: RichTextBridge.htmlToAttributed(
                initialHTML,
                baseFont: NoteEditorViewModel.editorBaseUIFont
            )
        )
    }

    var body: some View {
        NavigationStack {
            NoteTextComposerView(
                composerTarget: composer == .content ? .content : .idea,
                title: composer == .content ? "编辑合并正文" : "编辑合并想法",
                text: $attributedText,
                onRequestPhotoOCR: { showsPhotoOCR = true }
            )
            .navigationDestination(isPresented: $showsPhotoOCR) {
                NotePhotoOCRFlowView(
                    target: composer == .content ? .content : .idea,
                    repository: ocrRepository
                ) { payload in
                    appendRecognizedText(payload.summary.combinedText)
                }
            }
        }
        .onDisappear {
            onSave(RichTextBridge.attributedToHtml(attributedText))
        }
    }

    /// 将拍照 OCR 文本以编辑器基础字体追加到合并草稿末尾。
    private func appendRecognizedText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        if mutable.length > 0 {
            mutable.append(NSAttributedString(string: "\n"))
        }
        mutable.append(NSAttributedString(
            string: normalized,
            attributes: [.font: NoteEditorViewModel.editorBaseUIFont]
        ))
        attributedText = mutable
    }
}
