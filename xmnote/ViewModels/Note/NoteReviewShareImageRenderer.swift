/**
 * [INPUT]: 接收 NoteReviewCardItem，复用 AppTypography、NotePositionUnitFormatter 与 RichText HTML 解析能力
 * [OUTPUT]: 对外提供 NoteReviewShareImageRenderer，将书摘回顾卡片数据离屏渲染为临时 PNG 文件
 * [POS]: ViewModels/Note 的书摘回顾分享图基础能力，供 NoteReviewViewModel 后续编排分享/保存流程
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit

/// 书摘回顾分享图生成器，使用 UIKit 离屏绘制生成固定宽度、自适应高度的高分辨率 PNG。
@MainActor
struct NoteReviewShareImageRenderer {
    private enum Layout {
        static let canvasWidth: CGFloat = 1240
        static let maxCanvasHeight: CGFloat = 12_000
        static let outerInset: CGFloat = 72
        static let cardInset: CGFloat = 64
        static let topPadding: CGFloat = 68
        static let bottomPadding: CGFloat = 58
        static let cornerRadius: CGFloat = 46
        static let cardShadowOffset = CGSize(width: 0, height: 18)
        static let cardShadowBlur: CGFloat = 38
        static let headerSpacing: CGFloat = 18
        static let sectionSpacing: CGFloat = 38
        static let ideaInset = UIEdgeInsets(top: 30, left: 36, bottom: 30, right: 36)
        static let ideaCornerRadius: CGFloat = 26
        static let ideaRuleWidth: CGFloat = 5
        static let metadataRowSpacing: CGFloat = 14
        static let metadataColumnGap: CGFloat = 20
        static let metadataValueGap: CGFloat = 10
        static let footerHeight: CGFloat = 56
        static let dividerHeight: CGFloat = 1
    }

    private enum Palette {
        static let background = UIColor(red: 0.957, green: 0.969, blue: 0.953, alpha: 1)
        static let card = UIColor(red: 1, green: 0.996, blue: 0.984, alpha: 1)
        static let primaryText = UIColor(red: 0.104, green: 0.117, blue: 0.128, alpha: 1)
        static let secondaryText = UIColor(red: 0.384, green: 0.420, blue: 0.455, alpha: 1)
        static let tertiaryText = UIColor(red: 0.584, green: 0.620, blue: 0.650, alpha: 1)
        static let accent = UIColor(red: 0.176, green: 0.580, blue: 0.322, alpha: 1)
        static let divider = UIColor(red: 0.858, green: 0.886, blue: 0.866, alpha: 1)
        static let shadow = UIColor.black.withAlphaComponent(0.12)
        static let ideaFill = UIColor(red: 0.941, green: 0.969, blue: 0.957, alpha: 1)
    }

    private enum Typography {
        static let eyebrow = AppTypography.uiFixed(
            baseSize: 24,
            textStyle: .footnote,
            weight: .semibold,
            minimumPointSize: 24
        )
        static let title = AppTypography.uiFixed(
            baseSize: 54,
            textStyle: .largeTitle,
            weight: .semibold,
            minimumPointSize: 54
        )
        static let author = AppTypography.uiFixed(
            baseSize: 28,
            textStyle: .title3,
            weight: .regular,
            minimumPointSize: 28
        )
        static let content = AppTypography.uiFixed(
            baseSize: 38,
            textStyle: .body,
            weight: .regular,
            minimumPointSize: 38
        )
        static let idea = AppTypography.uiFixed(
            baseSize: 30,
            textStyle: .callout,
            weight: .regular,
            minimumPointSize: 30
        )
        static let metadataLabel = AppTypography.uiFixed(
            baseSize: 22,
            textStyle: .caption1,
            weight: .semibold,
            minimumPointSize: 22
        )
        static let metadataValue = AppTypography.uiFixed(
            baseSize: 24,
            textStyle: .subheadline,
            weight: .regular,
            minimumPointSize: 24
        )
        static let footer = AppTypography.uiFixed(
            baseSize: 22,
            textStyle: .caption1,
            weight: .regular,
            minimumPointSize: 22
        )
    }

    /// 在主线程完成 UIKit 绘制与 PNG 编码；方法本身不启动 Task，调用取消策略由集成方在 ViewModel 中控制。
    func renderPNG(
        for item: NoteReviewCardItem,
        outputDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> NoteReviewGeneratedShareFile {
        let payload = try makePayload(from: item)
        let measuredLayout = try measureLayout(for: payload)
        let data = try renderPNGData(payload: payload, measuredLayout: measuredLayout)
        guard !data.isEmpty else {
            throw NoteReviewShareImageRendererError.imageEncodingFailed
        }

        let fileName = makeFileName(for: payload)
        let fileURL = outputDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw NoteReviewShareImageRendererError.fileWriteFailed(
                fileURL: fileURL,
                reason: error.localizedDescription
            )
        }

        return NoteReviewGeneratedShareFile(
            noteID: item.id,
            title: payload.bookTitle,
            fileURL: fileURL,
            fileName: fileName,
            pixelWidth: Int(Layout.canvasWidth.rounded()),
            pixelHeight: Int(measuredLayout.canvasHeight.rounded()),
            byteCount: data.count
        )
    }

    private func makePayload(from item: NoteReviewCardItem) throws -> RenderPayload {
        let content = try makeRichText(
            html: item.contentHTML,
            role: .content,
            font: Typography.content,
            color: Palette.primaryText,
            lineSpacing: 13
        )
        guard content.length > 0 else {
            throw NoteReviewShareImageRendererError.emptyContent
        }

        let idea = try makeRichText(
            html: item.ideaHTML,
            role: .idea,
            font: Typography.idea,
            color: Palette.secondaryText,
            lineSpacing: 9
        )

        return RenderPayload(
            noteID: item.id,
            bookTitle: fallbackText(item.bookTitle, fallback: "未知书籍"),
            bookAuthor: fallbackText(item.bookAuthor, fallback: "作者未知"),
            chapter: fallbackText(item.chapterTitle, fallback: "未记录"),
            position: positionText(position: item.position, unit: item.positionUnit),
            createdDate: createdDateText(item.createdDate),
            content: content,
            idea: idea
        )
    }

    private func measureLayout(for payload: RenderPayload) throws -> MeasuredLayout {
        let contentWidth = Layout.canvasWidth - Layout.outerInset * 2 - Layout.cardInset * 2
        let titleHeight = attributedText(
            payload.bookTitle,
            font: Typography.title,
            color: Palette.primaryText,
            lineSpacing: 4
        ).height(constrainedTo: contentWidth)
        let authorHeight = attributedText(
            payload.bookAuthor,
            font: Typography.author,
            color: Palette.secondaryText,
            lineSpacing: 3
        ).height(constrainedTo: contentWidth)
        let contentHeight = payload.content.height(constrainedTo: contentWidth)
        let ideaHeight = payload.idea.length > 0
            ? payload.idea.height(constrainedTo: contentWidth - Layout.ideaInset.left - Layout.ideaInset.right)
                + Layout.ideaInset.top
                + Layout.ideaInset.bottom
            : 0
        let metadataHeight = metadataHeight(for: payload, width: contentWidth)
        let footerBlockHeight = Layout.dividerHeight + Layout.footerHeight

        let contentBlockSpacing = payload.idea.length > 0 ? Layout.sectionSpacing : 0
        let cardHeight = Layout.topPadding
            + 34
            + Layout.headerSpacing
            + titleHeight
            + 12
            + authorHeight
            + Layout.sectionSpacing
            + contentHeight
            + contentBlockSpacing
            + ideaHeight
            + Layout.sectionSpacing
            + metadataHeight
            + Layout.sectionSpacing
            + footerBlockHeight
            + Layout.bottomPadding
        let canvasHeight = cardHeight + Layout.outerInset * 2

        guard canvasHeight <= Layout.maxCanvasHeight else {
            throw NoteReviewShareImageRendererError.layoutExceededHeight(
                actual: Int(canvasHeight.rounded()),
                maximum: Int(Layout.maxCanvasHeight.rounded())
            )
        }

        return MeasuredLayout(
            canvasHeight: ceil(canvasHeight),
            cardHeight: ceil(cardHeight),
            contentWidth: contentWidth,
            titleHeight: ceil(titleHeight),
            authorHeight: ceil(authorHeight),
            contentHeight: ceil(contentHeight),
            ideaHeight: ceil(ideaHeight),
            metadataHeight: ceil(metadataHeight)
        )
    }

    private func renderPNGData(payload: RenderPayload, measuredLayout: MeasuredLayout) throws -> Data {
        let size = CGSize(width: Layout.canvasWidth, height: measuredLayout.canvasHeight)
        guard size.width > 0, size.height > 0 else {
            throw NoteReviewShareImageRendererError.invalidCanvasSize
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.pngData { context in
            drawBackground(in: CGRect(origin: .zero, size: size), context: context)
            drawCard(payload: payload, measuredLayout: measuredLayout, context: context)
        }
    }

    private func drawBackground(in rect: CGRect, context: UIGraphicsImageRendererContext) {
        let cg = context.cgContext
        Palette.background.setFill()
        cg.fill(rect)

        let accentRect = CGRect(x: 0, y: 0, width: rect.width, height: 18)
        Palette.accent.setFill()
        cg.fill(accentRect)
    }

    private func drawCard(
        payload: RenderPayload,
        measuredLayout: MeasuredLayout,
        context: UIGraphicsImageRendererContext
    ) {
        let cardRect = CGRect(
            x: Layout.outerInset,
            y: Layout.outerInset,
            width: Layout.canvasWidth - Layout.outerInset * 2,
            height: measuredLayout.cardHeight
        )
        let cg = context.cgContext
        cg.saveGState()
        cg.setShadow(
            offset: Layout.cardShadowOffset,
            blur: Layout.cardShadowBlur,
            color: Palette.shadow.cgColor
        )
        Palette.card.setFill()
        UIBezierPath(roundedRect: cardRect, cornerRadius: Layout.cornerRadius).fill()
        cg.restoreGState()

        let contentX = cardRect.minX + Layout.cardInset
        var y = cardRect.minY + Layout.topPadding
        let contentWidth = measuredLayout.contentWidth

        drawEyebrow(at: CGPoint(x: contentX, y: y), width: contentWidth)
        y += 34 + Layout.headerSpacing

        attributedText(
            payload.bookTitle,
            font: Typography.title,
            color: Palette.primaryText,
            lineSpacing: 4
        ).draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.titleHeight))
        y += measuredLayout.titleHeight + 12

        attributedText(
            payload.bookAuthor,
            font: Typography.author,
            color: Palette.secondaryText,
            lineSpacing: 3
        ).draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.authorHeight))
        y += measuredLayout.authorHeight + Layout.sectionSpacing

        payload.content.draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.contentHeight))
        y += measuredLayout.contentHeight

        if payload.idea.length > 0 {
            y += Layout.sectionSpacing
            drawIdea(payload.idea, in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.ideaHeight))
            y += measuredLayout.ideaHeight
        }

        y += Layout.sectionSpacing
        drawMetadata(payload: payload, in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.metadataHeight))
        y += measuredLayout.metadataHeight + Layout.sectionSpacing

        drawFooter(in: CGRect(x: contentX, y: y, width: contentWidth, height: Layout.dividerHeight + Layout.footerHeight))
    }

    private func drawEyebrow(at point: CGPoint, width: CGFloat) {
        let markerRect = CGRect(x: point.x, y: point.y + 3, width: 10, height: 26)
        Palette.accent.setFill()
        UIBezierPath(roundedRect: markerRect, cornerRadius: 5).fill()

        attributedText(
            "书摘回顾",
            font: Typography.eyebrow,
            color: Palette.accent,
            lineSpacing: 0,
            letterSpacing: 1.8
        ).draw(in: CGRect(x: markerRect.maxX + 16, y: point.y, width: width - 26, height: 34))
    }

    private func drawIdea(_ idea: NSAttributedString, in rect: CGRect) {
        Palette.ideaFill.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: Layout.ideaCornerRadius).fill()

        let ruleRect = CGRect(
            x: rect.minX + Layout.ideaInset.left - 16,
            y: rect.minY + Layout.ideaInset.top,
            width: Layout.ideaRuleWidth,
            height: max(0, rect.height - Layout.ideaInset.top - Layout.ideaInset.bottom)
        )
        Palette.accent.setFill()
        UIBezierPath(roundedRect: ruleRect, cornerRadius: Layout.ideaRuleWidth / 2).fill()

        let textRect = rect.inset(by: Layout.ideaInset)
        idea.draw(in: textRect)
    }

    private func drawMetadata(payload: RenderPayload, in rect: CGRect) {
        let columns = metadataColumns(in: rect)
        let rows = metadataRows(for: payload)
        var y = rect.minY

        var rowStart = 0
        while rowStart < rows.count {
            let rowEnd = min(rowStart + columns.count, rows.count)
            let rowItems = Array(rows[rowStart..<rowEnd])
            let rowHeight = rowItems.enumerated().map { index, item in
                metadataItemHeight(label: item.label, value: item.value, width: columns[index].width)
            }.max() ?? 0

            for (index, item) in rowItems.enumerated() {
                let column = columns[index]
                drawMetadataItem(
                    label: item.label,
                    value: item.value,
                    in: CGRect(x: column.minX, y: y, width: column.width, height: rowHeight)
                )
            }

            y += rowHeight + Layout.metadataRowSpacing
            rowStart = rowEnd
        }
    }

    private func drawMetadataItem(label: String, value: String, in rect: CGRect) {
        let labelAttributed = attributedText(label, font: Typography.metadataLabel, color: Palette.accent, lineSpacing: 0)
        let labelWidth = labelAttributed.width(constrainedTo: rect.width)
        let labelRect = CGRect(x: rect.minX, y: rect.minY + 2, width: labelWidth, height: rect.height)
        labelAttributed.draw(in: labelRect)

        let valueX = labelRect.maxX + Layout.metadataValueGap
        attributedText(
            value,
            font: Typography.metadataValue,
            color: Palette.secondaryText,
            lineSpacing: 3
        ).draw(in: CGRect(x: valueX, y: rect.minY, width: rect.maxX - valueX, height: rect.height))
    }

    private func drawFooter(in rect: CGRect) {
        Palette.divider.setFill()
        UIBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Layout.dividerHeight)).fill()

        attributedText(
            "XMNote · 书摘回顾分享图",
            font: Typography.footer,
            color: Palette.tertiaryText,
            lineSpacing: 0
        ).draw(in: CGRect(x: rect.minX, y: rect.minY + 22, width: rect.width, height: 34))
    }

    private func makeRichText(
        html: String,
        role: RichTextRole,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat
    ) throws -> NSAttributedString {
        let trimmedHTML = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHTML.isEmpty else {
            return NSAttributedString(string: "")
        }

        let attributed = trim(
            RichText.resolvedAttributedString(
                html: trimmedHTML,
                baseFont: font,
                textColor: color,
                lineSpacing: lineSpacing,
                textAlignment: .natural,
                traitCollection: UITraitCollection(userInterfaceStyle: .light)
            )
        )
        if attributed.length > 0 {
            return restyle(attributed, font: font, color: color, lineSpacing: lineSpacing)
        }

        let imported = try importHTML(trimmedHTML, role: role)
        let styled = trim(restyle(imported, font: font, color: color, lineSpacing: lineSpacing))
        guard styled.length > 0 else {
            if htmlContainsRenderableText(trimmedHTML) {
                throw NoteReviewShareImageRendererError.htmlDecodingFailed(field: role.title)
            }
            return NSAttributedString(string: "")
        }
        return styled
    }

    private func importHTML(_ html: String, role: RichTextRole) throws -> NSAttributedString {
        let wrappedHTML = """
        <html><head><meta charset="utf-8"></head><body>\(html)</body></html>
        """
        guard let data = wrappedHTML.data(using: .utf8) else {
            throw NoteReviewShareImageRendererError.htmlDecodingFailed(field: role.title)
        }
        do {
            return try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            )
        } catch {
            throw NoteReviewShareImageRendererError.htmlDecodingFailed(field: role.title)
        }
    }

    private func restyle(
        _ attributed: NSAttributedString,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }

        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let sourceFont = value as? UIFont
            let nextFont = fontPreservingTraits(from: sourceFont, baseFont: font)
            mutable.addAttribute(.font, value: nextFont, range: range)
        }
        mutable.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
            mutable.addAttribute(.foregroundColor, value: value == nil ? color : Palette.accent, range: range)
        }

        let defaultParagraph = NSMutableParagraphStyle()
        defaultParagraph.lineSpacing = lineSpacing
        defaultParagraph.lineBreakMode = .byWordWrapping
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? defaultParagraph.mutableCopy() as! NSMutableParagraphStyle
            paragraph.lineSpacing = lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return mutable
    }

    private func fontPreservingTraits(from sourceFont: UIFont?, baseFont: UIFont) -> UIFont {
        guard let sourceFont else { return baseFont }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if sourceFont.fontDescriptor.symbolicTraits.contains(.traitBold) {
            traits.insert(.traitBold)
        }
        if sourceFont.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            traits.insert(.traitItalic)
        }
        guard !traits.isEmpty, let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) else {
            return baseFont
        }
        return UIFont(descriptor: descriptor, size: baseFont.pointSize)
    }

    private func metadataHeight(for payload: RenderPayload, width: CGFloat) -> CGFloat {
        let columns = metadataColumns(in: CGRect(x: 0, y: 0, width: width, height: 1))
        let rows = metadataRows(for: payload)
        var heights: [CGFloat] = []
        var rowStart = 0
        while rowStart < rows.count {
            let rowEnd = min(rowStart + columns.count, rows.count)
            let rowItems = Array(rows[rowStart..<rowEnd])
            let rowHeight = rowItems.enumerated().map { index, item in
                metadataItemHeight(label: item.label, value: item.value, width: columns[index].width)
            }.max() ?? 0
            heights.append(rowHeight)
            rowStart = rowEnd
        }
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * Layout.metadataRowSpacing
    }

    private func metadataColumns(in rect: CGRect) -> [CGRect] {
        guard rect.width >= 720 else { return [rect] }
        let columnWidth = (rect.width - Layout.metadataColumnGap) / 2
        return [
            CGRect(x: rect.minX, y: rect.minY, width: columnWidth, height: rect.height),
            CGRect(x: rect.minX + columnWidth + Layout.metadataColumnGap, y: rect.minY, width: columnWidth, height: rect.height),
        ]
    }

    private func metadataRows(for payload: RenderPayload) -> [(label: String, value: String)] {
        [
            ("章节", payload.chapter),
            ("位置", payload.position),
            ("创建", payload.createdDate),
        ]
    }

    private func metadataItemHeight(label: String, value: String, width: CGFloat) -> CGFloat {
        let labelAttributed = attributedText(label, font: Typography.metadataLabel, color: Palette.accent, lineSpacing: 0)
        let labelWidth = min(labelAttributed.width(constrainedTo: width), width)
        let valueWidth = max(0, width - labelWidth - Layout.metadataValueGap)
        let labelHeight = labelAttributed.height(constrainedTo: labelWidth)
        let valueHeight = attributedText(
            value,
            font: Typography.metadataValue,
            color: Palette.secondaryText,
            lineSpacing: 3
        ).height(constrainedTo: valueWidth)
        return max(labelHeight, valueHeight) + 4
    }

    private func positionText(position: String, unit: Int64) -> String {
        NotePositionUnitFormatter.labeledFooterText(position: position, unit: unit) ?? "未记录"
    }

    private func createdDateText(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "未知" }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    private func fallbackText(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func makeFileName(for payload: RenderPayload) -> String {
        let safeTitle = safeFileName(payload.bookTitle)
        return "\(safeTitle)-书摘回顾-\(payload.noteID).png"
    }

    private func safeFileName(_ rawValue: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = rawValue
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "未命名书籍" : String(sanitized.prefix(48))
    }

    private func attributedText(
        _ string: String,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        letterSpacing: CGFloat = 0
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .kern: letterSpacing,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func trim(_ attributed: NSAttributedString) -> NSAttributedString {
        let string = attributed.string as NSString
        var start = 0
        var end = string.length
        while start < end, isTrimCharacter(string.character(at: start)) {
            start += 1
        }
        while end > start, isTrimCharacter(string.character(at: end - 1)) {
            end -= 1
        }
        guard end > start else {
            return NSAttributedString(string: "")
        }
        return attributed.attributedSubstring(from: NSRange(location: start, length: end - start))
    }

    private func isTrimCharacter(_ value: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(value)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func htmlContainsRenderableText(_ html: String) -> Bool {
        let stripped = html.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let decoded = stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !decoded.isEmpty
    }
}

/// 书摘回顾分享图渲染阶段的显式失败类型，便于 ViewModel 后续映射为用户可感知反馈。
nonisolated enum NoteReviewShareImageRendererError: LocalizedError, Equatable, Sendable {
    case emptyContent
    case htmlDecodingFailed(field: String)
    case invalidCanvasSize
    case layoutExceededHeight(actual: Int, maximum: Int)
    case imageEncodingFailed
    case fileWriteFailed(fileURL: URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "书摘正文为空，无法生成分享图"
        case .htmlDecodingFailed(let field):
            return "\(field)富文本解析失败，无法生成分享图"
        case .invalidCanvasSize:
            return "分享图画布尺寸无效，无法生成 PNG"
        case .layoutExceededHeight(let actual, let maximum):
            return "分享图内容过长（\(actual)px），已超过当前 PNG 生成上限（\(maximum)px）"
        case .imageEncodingFailed:
            return "分享图 PNG 编码失败"
        case .fileWriteFailed(let fileURL, let reason):
            return "分享图写入临时文件失败：\(fileURL.lastPathComponent)，\(reason)"
        }
    }
}

private enum RichTextRole {
    case content
    case idea

    var title: String {
        switch self {
        case .content:
            return "书摘正文"
        case .idea:
            return "想法"
        }
    }
}

private struct RenderPayload {
    let noteID: Int64
    let bookTitle: String
    let bookAuthor: String
    let chapter: String
    let position: String
    let createdDate: String
    let content: NSAttributedString
    let idea: NSAttributedString
}

private struct MeasuredLayout {
    let canvasHeight: CGFloat
    let cardHeight: CGFloat
    let contentWidth: CGFloat
    let titleHeight: CGFloat
    let authorHeight: CGFloat
    let contentHeight: CGFloat
    let ideaHeight: CGFloat
    let metadataHeight: CGFloat
}

private extension NSAttributedString {
    func height(constrainedTo width: CGFloat) -> CGFloat {
        guard length > 0, width > 0 else { return 0 }
        let size = boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral.size
        return ceil(size.height)
    }

    func width(constrainedTo width: CGFloat) -> CGFloat {
        guard length > 0, width > 0 else { return 0 }
        let size = boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral.size
        return min(width, ceil(size.width))
    }
}
