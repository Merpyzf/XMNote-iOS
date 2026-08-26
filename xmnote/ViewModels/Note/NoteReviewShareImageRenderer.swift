/**
 * [INPUT]: 接收 NoteReviewCardItem 或 NoteContentDetail，复用 AppTypography、NotePositionUnitFormatter 与 RichText HTML 解析能力
 * [OUTPUT]: 对外提供 NoteReviewShareImageRenderer，将回顾卡片或查看器书摘离屏渲染为临时 PNG 文件
 * [POS]: ViewModels/Note 的共享书摘分享图基础能力，供回顾与 ContentViewer 复用同一视觉语言
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftUI
import UIKit

/// 书摘回顾分享图生成器，使用 UIKit 离屏绘制生成固定宽度、自适应高度的高分辨率 PNG。
@MainActor
struct NoteReviewShareImageRenderer: @unchecked Sendable {
    private enum Presentation: Equatable {
        case noteReview
        case contentViewer

        var eyebrowText: String {
            switch self {
            case .noteReview:
                "书摘回顾"
            case .contentViewer:
                "书摘分享"
            }
        }

        var footerText: String {
            switch self {
            case .noteReview:
                "XMNote · 书摘回顾分享图"
            case .contentViewer:
                "XMNote · 书摘分享图"
            }
        }

        var fileNameLabel: String {
            switch self {
            case .noteReview:
                "书摘回顾"
            case .contentViewer:
                "书摘分享"
            }
        }
    }

    private nonisolated enum Layout {
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

    private nonisolated enum Palette {
        static let background = UIColor.xmSRGB(red: 0.957, green: 0.969, blue: 0.953, alpha: 1)
        static let accent = UIColor.xmSRGB(red: 0.176, green: 0.580, blue: 0.322, alpha: 1)
        static let shadow = UIColor.black.withAlphaComponent(0.12)
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

    /// 在主线程准备不可变视觉快照，再把测量、离屏绘制、PNG 编码与文件写入交给独立任务，避免长书摘阻塞交互。
    func renderPNG(
        for item: NoteReviewCardItem,
        settings: NoteReviewSettings,
        isDarkAppearance: Bool,
        backgroundImageData: Data? = nil,
        outputDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> NoteReviewGeneratedShareFile {
        try await renderPNG(
            for: item,
            settings: settings,
            isDarkAppearance: isDarkAppearance,
            backgroundImageData: backgroundImageData,
            outputDirectory: outputDirectory,
            presentation: .noteReview
        )
    }

    /// 使用回顾分享图的稳定版式和默认设计令牌渲染查看器书摘，不读取回顾页的个性化外观设置。
    func renderPNG(
        for detail: NoteContentDetail,
        isDarkAppearance: Bool,
        outputDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> NoteReviewGeneratedShareFile {
        let item = NoteReviewCardItem(
            id: detail.noteId,
            bookID: detail.sourceBookId,
            bookTitle: detail.bookTitle,
            bookAuthor: "",
            bookCoverURL: "",
            chapterTitle: detail.chapterTitle,
            contentHTML: detail.contentHTML,
            ideaHTML: detail.ideaHTML,
            position: detail.position,
            positionUnit: detail.positionUnit,
            includeTime: detail.includeTime,
            createdDate: detail.createdDate,
            imageURLs: detail.imageURLs,
            tags: [],
            weReadOriginalURL: nil
        )
        return try await renderPNG(
            for: item,
            settings: .defaultValue,
            isDarkAppearance: isDarkAppearance,
            backgroundImageData: nil,
            outputDirectory: outputDirectory,
            presentation: .contentViewer
        )
    }

    private func renderPNG(
        for item: NoteReviewCardItem,
        settings: NoteReviewSettings,
        isDarkAppearance: Bool,
        backgroundImageData: Data?,
        outputDirectory: URL,
        presentation: Presentation
    ) async throws -> NoteReviewGeneratedShareFile {
        let payload = try makePayload(
            from: item,
            settings: settings,
            isDarkAppearance: isDarkAppearance,
            backgroundImageData: backgroundImageData,
            presentation: presentation
        )
        let itemID = item.id
        let worker = Task.detached(priority: .userInitiated) {
            try renderPreparedPNG(
                itemID: itemID,
                payload: payload,
                outputDirectory: outputDirectory
            )
        }
        var generatedFile: NoteReviewGeneratedShareFile?
        do {
            let completedFile = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            generatedFile = completedFile
            try Task.checkCancellation()
            return completedFile
        } catch is CancellationError {
            if let fileURL = generatedFile?.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            throw CancellationError()
        }
    }

    /// 后台任务独占不可变渲染快照；父任务显式传播取消，并在测量、编码和写盘阶段间终止且清理本次临时输出。
    private nonisolated func renderPreparedPNG(
        itemID: Int64,
        payload: RenderPayload,
        outputDirectory: URL
    ) throws -> NoteReviewGeneratedShareFile {
        try Task.checkCancellation()
        let measuredLayout = try measureLayout(for: payload)
        try Task.checkCancellation()
        let data = try renderPNGData(payload: payload, measuredLayout: measuredLayout)
        guard !data.isEmpty else {
            throw NoteReviewShareImageRendererError.imageEncodingFailed
        }

        try Task.checkCancellation()
        let fileName = makeFileName(for: payload)
        let fileURL = outputDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL, options: .atomic)
            try Task.checkCancellation()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: fileURL)
            throw CancellationError()
        } catch {
            throw NoteReviewShareImageRendererError.fileWriteFailed(
                fileURL: fileURL,
                reason: error.localizedDescription
            )
        }

        return NoteReviewGeneratedShareFile(
            noteID: itemID,
            title: payload.bookTitle,
            fileURL: fileURL,
            fileName: fileName,
            pixelWidth: Int(Layout.canvasWidth.rounded()),
            pixelHeight: Int(measuredLayout.canvasHeight.rounded()),
            byteCount: data.count
        )
    }

    private func makePayload(
        from item: NoteReviewCardItem,
        settings: NoteReviewSettings,
        isDarkAppearance: Bool,
        backgroundImageData: Data?,
        presentation: Presentation
    ) throws -> RenderPayload {
        let cardSurfaceColor = color(from: settings.cardSurfaceHex(isDarkAppearance: isDarkAppearance))
        let onSurfaceColor = color(from: settings.cardTextHex(isDarkAppearance: isDarkAppearance))
        let primaryTextColor = onSurfaceColor.withAlphaComponent(0.92)
        let secondaryTextColor = onSurfaceColor.withAlphaComponent(0.76)
        let accentColor = onSurfaceColor.withAlphaComponent(0.92)
        let contentFont = settings.fontSelection.uiFont(base: Typography.content)
        let ideaFont = settings.fontSelection.uiFont(base: Typography.idea)
        let content = try makeRichText(
            html: item.contentHTML,
            role: .content,
            font: contentFont,
            color: primaryTextColor,
            linkColor: accentColor,
            lineSpacing: 13,
            textAlignment: settings.textAlignment.nsTextAlignment
        )
        guard content.length > 0 else {
            throw NoteReviewShareImageRendererError.emptyContent
        }

        let idea = try makeRichText(
            html: item.ideaHTML,
            role: .idea,
            font: ideaFont,
            color: secondaryTextColor,
            linkColor: accentColor,
            lineSpacing: 9,
            textAlignment: settings.textAlignment.nsTextAlignment
        )

        return RenderPayload(
            noteID: item.id,
            bookTitle: fallbackText(item.bookTitle, fallback: "未知书籍"),
            bookAuthor: presentation == .noteReview
                ? fallbackText(item.bookAuthor, fallback: "作者未知")
                : item.bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines),
            chapter: fallbackText(item.chapterTitle, fallback: "未记录"),
            position: positionText(position: item.position, unit: item.positionUnit),
            createdDate: createdDateText(item.createdDate),
            content: content,
            idea: idea,
            titleFont: settings.fontSelection.uiFont(base: Typography.title),
            authorFont: settings.fontSelection.uiFont(base: Typography.author),
            eyebrowFont: settings.fontSelection.uiFont(base: Typography.eyebrow),
            metadataLabelFont: settings.fontSelection.uiFont(base: Typography.metadataLabel),
            metadataValueFont: settings.fontSelection.uiFont(base: Typography.metadataValue),
            footerFont: settings.fontSelection.uiFont(base: Typography.footer),
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            accentColor: accentColor,
            dividerColor: onSurfaceColor.withAlphaComponent(0.045),
            ideaFillColor: onSurfaceColor.withAlphaComponent(0.06),
            cardSurfaceColor: cardSurfaceColor,
            backgroundImage: backgroundImageData.flatMap { UIImage(data: $0) },
            auxiliaryTextAlignment: settings.textAlignment.auxiliaryNSTextAlignment,
            eyebrowText: presentation.eyebrowText,
            footerText: presentation.footerText,
            fileNameLabel: presentation.fileNameLabel
        )
    }

    /// 将领域层持有的 RGB 十六进制值转换为确定的 UIKit 颜色，避免离屏渲染读取当前 trait 环境。
    private func color(from rgbHex: UInt32) -> UIColor {
        UIColor.xmSRGB(
            red: CGFloat((rgbHex >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgbHex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgbHex & 0xFF) / 255.0,
            alpha: 1
        )
    }

    private nonisolated func measureLayout(for payload: RenderPayload) throws -> MeasuredLayout {
        let contentWidth = Layout.canvasWidth - Layout.outerInset * 2 - Layout.cardInset * 2
        let titleHeight = attributedText(
            payload.bookTitle,
            font: payload.titleFont,
            color: payload.primaryTextColor,
            lineSpacing: 4,
            textAlignment: payload.auxiliaryTextAlignment
        ).height(constrainedTo: contentWidth)
        let authorHeight = attributedText(
            payload.bookAuthor,
            font: payload.authorFont,
            color: payload.secondaryTextColor,
            lineSpacing: 3,
            textAlignment: payload.auxiliaryTextAlignment
        ).height(constrainedTo: contentWidth)
        let contentHeight = payload.content.height(constrainedTo: contentWidth)
        let ideaHeight = payload.idea.length > 0
            ? payload.idea.height(constrainedTo: contentWidth - Layout.ideaInset.left - Layout.ideaInset.right)
                + Layout.ideaInset.top
                + Layout.ideaInset.bottom
            : 0
        let metadataHeight = metadataHeight(for: payload, width: contentWidth)
        let footerBlockHeight = Layout.dividerHeight + Layout.footerHeight
        let authorBlockHeight = payload.bookAuthor.isEmpty
            ? 0
            : 12 + authorHeight

        let contentBlockSpacing = payload.idea.length > 0 ? Layout.sectionSpacing : 0
        let cardHeight = Layout.topPadding
            + 34
            + Layout.headerSpacing
            + titleHeight
            + authorBlockHeight
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

    private nonisolated func renderPNGData(payload: RenderPayload, measuredLayout: MeasuredLayout) throws -> Data {
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

    private nonisolated func drawBackground(in rect: CGRect, context: UIGraphicsImageRendererContext) {
        let cg = context.cgContext
        Palette.background.setFill()
        cg.fill(rect)

        let accentRect = CGRect(x: 0, y: 0, width: rect.width, height: 18)
        Palette.accent.setFill()
        cg.fill(accentRect)
    }

    private nonisolated func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
        )
        image.draw(in: CGRect(origin: origin, size: size))
    }

    private nonisolated func drawCard(
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
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: Layout.cornerRadius)
        payload.cardSurfaceColor.setFill()
        cardPath.fill()
        cg.restoreGState()

        cg.saveGState()
        cardPath.addClip()
        if let backgroundImage = payload.backgroundImage {
            drawAspectFill(backgroundImage, in: cardRect)
        }
        cg.restoreGState()

        let contentX = cardRect.minX + Layout.cardInset
        var y = cardRect.minY + Layout.topPadding
        let contentWidth = measuredLayout.contentWidth

        drawEyebrow(payload: payload, at: CGPoint(x: contentX, y: y), width: contentWidth)
        y += 34 + Layout.headerSpacing

        attributedText(
            payload.bookTitle,
            font: payload.titleFont,
            color: payload.primaryTextColor,
            lineSpacing: 4,
            textAlignment: payload.auxiliaryTextAlignment
        ).draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.titleHeight))
        y += measuredLayout.titleHeight

        if !payload.bookAuthor.isEmpty {
            y += 12
            attributedText(
                payload.bookAuthor,
                font: payload.authorFont,
                color: payload.secondaryTextColor,
                lineSpacing: 3,
                textAlignment: payload.auxiliaryTextAlignment
            ).draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.authorHeight))
            y += measuredLayout.authorHeight
        }
        y += Layout.sectionSpacing

        payload.content.draw(in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.contentHeight))
        y += measuredLayout.contentHeight

        if payload.idea.length > 0 {
            y += Layout.sectionSpacing
            drawIdea(payload: payload, in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.ideaHeight))
            y += measuredLayout.ideaHeight
        }

        y += Layout.sectionSpacing
        drawMetadata(payload: payload, in: CGRect(x: contentX, y: y, width: contentWidth, height: measuredLayout.metadataHeight))
        y += measuredLayout.metadataHeight + Layout.sectionSpacing

        drawFooter(payload: payload, in: CGRect(x: contentX, y: y, width: contentWidth, height: Layout.dividerHeight + Layout.footerHeight))
    }

    private nonisolated func drawEyebrow(payload: RenderPayload, at point: CGPoint, width: CGFloat) {
        let markerRect = CGRect(x: point.x, y: point.y + 3, width: 10, height: 26)
        payload.accentColor.setFill()
        UIBezierPath(roundedRect: markerRect, cornerRadius: 5).fill()

        attributedText(
            payload.eyebrowText,
            font: payload.eyebrowFont,
            color: payload.accentColor,
            lineSpacing: 0,
            letterSpacing: 1.8,
            textAlignment: payload.auxiliaryTextAlignment
        ).draw(in: CGRect(x: markerRect.maxX + 16, y: point.y, width: width - 26, height: 34))
    }

    private nonisolated func drawIdea(payload: RenderPayload, in rect: CGRect) {
        payload.ideaFillColor.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: Layout.ideaCornerRadius).fill()

        let ruleRect = CGRect(
            x: rect.minX + Layout.ideaInset.left - 16,
            y: rect.minY + Layout.ideaInset.top,
            width: Layout.ideaRuleWidth,
            height: max(0, rect.height - Layout.ideaInset.top - Layout.ideaInset.bottom)
        )
        payload.accentColor.setFill()
        UIBezierPath(roundedRect: ruleRect, cornerRadius: Layout.ideaRuleWidth / 2).fill()

        let textRect = rect.inset(by: Layout.ideaInset)
        payload.idea.draw(in: textRect)
    }

    private nonisolated func drawMetadata(payload: RenderPayload, in rect: CGRect) {
        let columns = metadataColumns(in: rect)
        let rows = metadataRows(for: payload)
        var y = rect.minY

        var rowStart = 0
        while rowStart < rows.count {
            let rowEnd = min(rowStart + columns.count, rows.count)
            let rowItems = Array(rows[rowStart..<rowEnd])
            let rowHeight = rowItems.enumerated().map { index, item in
                metadataItemHeight(payload: payload, label: item.label, value: item.value, width: columns[index].width)
            }.max() ?? 0

            for (index, item) in rowItems.enumerated() {
                let column = columns[index]
                drawMetadataItem(
                    payload: payload,
                    label: item.label,
                    value: item.value,
                    in: CGRect(x: column.minX, y: y, width: column.width, height: rowHeight)
                )
            }

            y += rowHeight + Layout.metadataRowSpacing
            rowStart = rowEnd
        }
    }

    private nonisolated func drawMetadataItem(payload: RenderPayload, label: String, value: String, in rect: CGRect) {
        let labelAttributed = attributedText(
            label,
            font: payload.metadataLabelFont,
            color: payload.accentColor,
            lineSpacing: 0,
            textAlignment: payload.auxiliaryTextAlignment
        )
        let labelWidth = labelAttributed.width(constrainedTo: rect.width)
        let labelRect = CGRect(x: rect.minX, y: rect.minY + 2, width: labelWidth, height: rect.height)
        labelAttributed.draw(in: labelRect)

        let valueX = labelRect.maxX + Layout.metadataValueGap
        attributedText(
            value,
            font: payload.metadataValueFont,
            color: payload.secondaryTextColor,
            lineSpacing: 3,
            textAlignment: payload.auxiliaryTextAlignment
        ).draw(in: CGRect(x: valueX, y: rect.minY, width: rect.maxX - valueX, height: rect.height))
    }

    private nonisolated func drawFooter(payload: RenderPayload, in rect: CGRect) {
        payload.dividerColor.setFill()
        UIBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: Layout.dividerHeight)).fill()

        attributedText(
            payload.footerText,
            font: payload.footerFont,
            color: payload.secondaryTextColor,
            lineSpacing: 0,
            textAlignment: payload.auxiliaryTextAlignment
        ).draw(in: CGRect(x: rect.minX, y: rect.minY + 22, width: rect.width, height: 34))
    }

    private func makeRichText(
        html: String,
        role: RichTextRole,
        font: UIFont,
        color: UIColor,
        linkColor: UIColor,
        lineSpacing: CGFloat,
        textAlignment: NSTextAlignment
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
                textAlignment: textAlignment,
                traitCollection: UITraitCollection(userInterfaceStyle: .light)
            )
        )
        if attributed.length > 0 {
            return restyle(
                attributed,
                font: font,
                color: color,
                linkColor: linkColor,
                lineSpacing: lineSpacing,
                textAlignment: textAlignment
            )
        }

        let imported = try importHTML(trimmedHTML, role: role)
        let styled = trim(
            restyle(
                imported,
                font: font,
                color: color,
                linkColor: linkColor,
                lineSpacing: lineSpacing,
                textAlignment: textAlignment
            )
        )
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
        linkColor: UIColor,
        lineSpacing: CGFloat,
        textAlignment: NSTextAlignment
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
            mutable.addAttribute(.foregroundColor, value: value == nil ? color : linkColor, range: range)
        }

        let defaultParagraph = NSMutableParagraphStyle()
        defaultParagraph.lineSpacing = lineSpacing
        defaultParagraph.lineBreakMode = .byWordWrapping
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? defaultParagraph.mutableCopy() as! NSMutableParagraphStyle
            paragraph.lineSpacing = lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = textAlignment
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

    private nonisolated func metadataHeight(for payload: RenderPayload, width: CGFloat) -> CGFloat {
        let columns = metadataColumns(in: CGRect(x: 0, y: 0, width: width, height: 1))
        let rows = metadataRows(for: payload)
        var heights: [CGFloat] = []
        var rowStart = 0
        while rowStart < rows.count {
            let rowEnd = min(rowStart + columns.count, rows.count)
            let rowItems = Array(rows[rowStart..<rowEnd])
            let rowHeight = rowItems.enumerated().map { index, item in
                metadataItemHeight(payload: payload, label: item.label, value: item.value, width: columns[index].width)
            }.max() ?? 0
            heights.append(rowHeight)
            rowStart = rowEnd
        }
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * Layout.metadataRowSpacing
    }

    private nonisolated func metadataColumns(in rect: CGRect) -> [CGRect] {
        guard rect.width >= 720 else { return [rect] }
        let columnWidth = (rect.width - Layout.metadataColumnGap) / 2
        return [
            CGRect(x: rect.minX, y: rect.minY, width: columnWidth, height: rect.height),
            CGRect(x: rect.minX + columnWidth + Layout.metadataColumnGap, y: rect.minY, width: columnWidth, height: rect.height),
        ]
    }

    private nonisolated func metadataRows(for payload: RenderPayload) -> [(label: String, value: String)] {
        [
            ("章节", payload.chapter),
            ("位置", payload.position),
            ("创建", payload.createdDate),
        ]
    }

    private nonisolated func metadataItemHeight(payload: RenderPayload, label: String, value: String, width: CGFloat) -> CGFloat {
        let labelAttributed = attributedText(
            label,
            font: payload.metadataLabelFont,
            color: payload.accentColor,
            lineSpacing: 0,
            textAlignment: payload.auxiliaryTextAlignment
        )
        let labelWidth = min(labelAttributed.width(constrainedTo: width), width)
        let valueWidth = max(0, width - labelWidth - Layout.metadataValueGap)
        let labelHeight = labelAttributed.height(constrainedTo: labelWidth)
        let valueHeight = attributedText(
            value,
            font: payload.metadataValueFont,
            color: payload.secondaryTextColor,
            lineSpacing: 3,
            textAlignment: payload.auxiliaryTextAlignment
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

    private nonisolated func makeFileName(for payload: RenderPayload) -> String {
        let safeTitle = safeFileName(payload.bookTitle)
        return "\(safeTitle)-\(payload.fileNameLabel)-\(payload.noteID).png"
    }

    private nonisolated func safeFileName(_ rawValue: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = rawValue
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "未命名书籍" : String(sanitized.prefix(48))
    }

    private nonisolated func attributedText(
        _ string: String,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        letterSpacing: CGFloat = 0,
        textAlignment: NSTextAlignment = .natural
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = textAlignment
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

private nonisolated struct RenderPayload: @unchecked Sendable {
    let noteID: Int64
    let bookTitle: String
    let bookAuthor: String
    let chapter: String
    let position: String
    let createdDate: String
    let content: NSAttributedString
    let idea: NSAttributedString
    let titleFont: UIFont
    let authorFont: UIFont
    let eyebrowFont: UIFont
    let metadataLabelFont: UIFont
    let metadataValueFont: UIFont
    let footerFont: UIFont
    let primaryTextColor: UIColor
    let secondaryTextColor: UIColor
    let accentColor: UIColor
    let dividerColor: UIColor
    let ideaFillColor: UIColor
    let cardSurfaceColor: UIColor
    let backgroundImage: UIImage?
    let auxiliaryTextAlignment: NSTextAlignment
    let eyebrowText: String
    let footerText: String
    let fileNameLabel: String
}

private nonisolated struct MeasuredLayout: Sendable {
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
    nonisolated func height(constrainedTo width: CGFloat) -> CGFloat {
        guard length > 0, width > 0 else { return 0 }
        let size = boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral.size
        return ceil(size.height)
    }

    nonisolated func width(constrainedTo width: CGFloat) -> CGFloat {
        guard length > 0, width > 0 else { return 0 }
        let size = boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral.size
        return min(width, ceil(size.width))
    }
}
