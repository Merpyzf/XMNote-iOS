#if DEBUG
/**
 * [INPUT]: 依赖 Foundation/NSAttributedString 与 RichTextFormat，承接 Debug OCR 宿主页的编辑内容与识别结果汇总
 * [OUTPUT]: 对外提供 BaiduOCRTestViewModel、OCRFlowTarget、OCRDebugRecognitionSummary 与 BaiduOCRFlowCompletionPayload
 * [POS]: Debug 模块百度 OCR 宿主页状态编排器，负责编辑区内容维护与 OCR Flow 回填结果消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// OCR Flow 的回填目标，对齐 Android 编辑页“内容 OCR / 想法 OCR”两条入口。
enum OCRFlowTarget: String, Identifiable {
    case content
    case idea

    var id: String { rawValue }

    /// 返回宿主页展示用的目标标题。
    var title: String {
        switch self {
        case .content:
            return "书摘内容"
        case .idea:
            return "想法"
        }
    }

    /// 返回宿主页按钮标题。
    var actionTitle: String {
        switch self {
        case .content:
            return "内容 OCR"
        case .idea:
            return "想法 OCR"
        }
    }
}

/// Debug Flow 的识别模式，包含 Android 对齐的单框选择和新增的自由框选模式。
enum OCRSelectionMode: String, CaseIterable, Identifiable {
    case single
    case freeform

    var id: String { rawValue }

    /// 返回裁切页模式标题。
    var title: String {
        switch self {
        case .single:
            return "选择框"
        case .freeform:
            return "自由框选"
        }
    }
}

/// 自由框选模式下的单个识别区域。
struct OCRSelectionRegion: Identifiable {
    let id: UUID
    var normalizedRect: CGRect
    let createdAt: Date

    init(
        id: UUID = UUID(),
        normalizedRect: CGRect,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.createdAt = createdAt
    }
}

/// 单个识别框的原始结果包装，便于宿主页按区域展开调试信息。
struct OCRDebugRecognitionItem: Identifiable {
    let id: UUID
    let region: OCRSelectionRegion
    let result: OCRRecognitionResult

    init(
        id: UUID = UUID(),
        region: OCRSelectionRegion,
        result: OCRRecognitionResult
    ) {
        self.id = id
        self.region = region
        self.result = result
    }
}

/// Flow 返回给宿主页的汇总结果，承接组合文本与逐框原始结果。
struct OCRDebugRecognitionSummary {
    let target: OCRFlowTarget
    let selectionMode: OCRSelectionMode
    let sourceTitle: String
    let combinedText: String
    let items: [OCRDebugRecognitionItem]

    /// 返回当前识别使用的区域数量。
    var regionCount: Int { items.count }

    /// 汇总返回总行数。
    var totalLineCount: Int {
        items.reduce(0) { $0 + $1.result.lineCount }
    }

    /// 汇总返回总字符数。
    var totalCharacterCount: Int {
        items.reduce(0) { $0 + $1.result.characterCount }
    }
}

/// OCR Flow 识别完成后的回传载荷。
struct BaiduOCRFlowCompletionPayload {
    let summary: OCRDebugRecognitionSummary
}

@MainActor
@Observable
final class BaiduOCRTestViewModel {
    var contentText = NSAttributedString(string: "")
    var contentFormats = Set<RichTextFormat>()
    var ideaText = NSAttributedString(string: "")
    var ideaFormats = Set<RichTextFormat>()
    var selectedHighlightARGB: UInt32 = HighlightColors.defaultHighlightColor
    var lastRecognitionSummary: OCRDebugRecognitionSummary?

    /// 消费 OCR Flow 的完成结果，并按目标编辑区追加回填识别文本。
    func applyFlowCompletion(_ payload: BaiduOCRFlowCompletionPayload) {
        lastRecognitionSummary = payload.summary
        let normalizedText = payload.summary.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }

        switch payload.summary.target {
        case .content:
            contentText = appendedText(normalizedText, to: contentText)
        case .idea:
            ideaText = appendedText(normalizedText, to: ideaText)
        }
    }
}

private extension BaiduOCRTestViewModel {
    func appendedText(_ text: String, to original: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: original)
        let suffix = mutable.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty {
            mutable.append(NSAttributedString(string: "\n"))
        }
        mutable.append(NSAttributedString(string: text))
        return mutable
    }
}
#endif
