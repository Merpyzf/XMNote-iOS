/**
 * [INPUT]: 依赖 UIKit/CoreText/PDFKit、单书不可变 ExportBookSnapshot 与冻结的 PDF 设置，接收可选远端/本地图片 URL
 * [OUTPUT]: 对外提供每本书一份 595×842 PDF，包含封面、完整章节目录、正文、页码、链接、命名目的地与裁剪后的 outline
 * [POS]: Services 层 PDF 生成器；先计算不可变分页方案再渲染，不访问数据库、设置存储或凭据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreText
import Foundation
import PDFKit
import UIKit

/// Android 阅读笔记 PDF 的 iOS 布局实现；图片失败只降级为文本，任务取消会停止后续下载和分页。
final class ExportPDFGenerator: @unchecked Sendable {
    private enum Layout {
        static let pageSize = CGSize(width: 595, height: 842)
        static let left: CGFloat = 36
        static let right: CGFloat = 36
        static let top: CGFloat = 62
        static let bottom: CGFloat = 788
        static let width: CGFloat = 523
        static let usableHeight: CGFloat = 726
        static let itemSeparator: CGFloat = 29
        static let imageColumns = 4
        static let imageGap: CGFloat = 8
        static let imageMaximumHeight: CGFloat = 176
        static let tocIndent: CGFloat = 14
        static let tocTop: CGFloat = 126
    }

    private struct TextBlock {
        let attributed: NSAttributedString
        let frame: CGRect
    }

    private struct ImageBlock {
        let image: UIImage
        let frame: CGRect
    }

    private struct PagePlan {
        var textBlocks: [TextBlock] = []
        var imageBlocks: [ImageBlock] = []
        var anchors: [String: CGFloat] = [:]
    }

    private struct AnchorLocation {
        let bodyPageIndex: Int
        let top: CGFloat
    }

    private struct TOCEntry {
        let title: String
        let depth: Int
        let anchor: String?
    }

    private struct TOCRow {
        let entry: TOCEntry
        let frame: CGRect
    }

    private struct TOCPage {
        var rows: [TOCRow] = []
    }

    private struct ColorScheme {
        let spine: UIColor
        let spineText: UIColor
        let rule: UIColor
    }

    private enum Ink {
        static let primary = UIColor.xmHex(0x262523)
        static let secondary = UIColor.xmHex(0x52504C)
        static let metadata = UIColor.xmHex(0x797670)
        static let tocLeader = UIColor.xmHex(0xD3D0CA)
        static let warmGray = UIColor.xmHex(0x48443F)
    }

    private enum Element {
        case text(
            NSAttributedString,
            before: CGFloat,
            after: CGFloat,
            keepTogether: Bool,
            anchor: String?
        )
        case images([UIImage])
        case separator
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 先下载可用图片并完成全部分页，再一次性绘制 PDF；执行不绑定主线程且不读取运行中界面设置。
    func generate(
        book: ExportBookSnapshot,
        settings: ExportSettingsSnapshot,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) async throws -> Data {
        let imageURLs = collectedImageURLs(book)
        let images = try await loadImages(imageURLs)
        try Task.checkCancellation()
        let elements = makeElements(
            book,
            settings: settings,
            images: images,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        guard !elements.isEmpty else { throw ExportRepositoryError.noContent }
        let (bodyPages, anchors) = layoutBody(elements)
        let tocEntries = makeTOCEntries(book, settings: settings, anchors: anchors)
        let tocPages = layoutTOC(tocEntries)
        let rawData = render(
            book: book,
            settings: settings,
            cover: images[book.book.cover],
            bodyPages: bodyPages,
            anchors: anchors,
            tocPages: tocPages
        )
        return addOutline(
            to: rawData,
            book: book,
            entries: tocEntries,
            anchors: anchors,
            tocPageCount: tocPages.count
        )
    }

    private func makeElements(
        _ snapshot: ExportBookSnapshot,
        settings: ExportSettingsSnapshot,
        images: [String: UIImage],
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [Element] {
        var result: [Element] = []
        let book = snapshot.book
        if settings.includesBookInformation {
            let summary = Self.clearHTML(book.summary)
            let authorIntro = Self.clearHTML(book.authorIntro)
            if !summary.isEmpty || !authorIntro.isEmpty {
                result.append(.text(
                    attributed("书籍简介", style: .heading),
                    before: 0,
                    after: 14,
                    keepTogether: true,
                    anchor: "book-info"
                ))
                if !summary.isEmpty {
                    result.append(.text(
                        attributed(summary, style: .secondaryBody),
                        before: 0,
                        after: 34,
                        keepTogether: false,
                        anchor: nil
                    ))
                }
                if !authorIntro.isEmpty {
                    result.append(.text(
                        attributed("作者简介", style: .heading),
                        before: 0,
                        after: 14,
                        keepTogether: true,
                        anchor: summary.isEmpty ? "book-info" : nil
                    ))
                    result.append(.text(
                        attributed(Self.normalizedAuthorIntroduction(authorIntro), style: .secondaryBody),
                        before: 0,
                        after: 34,
                        keepTogether: false,
                        anchor: nil
                    ))
                }
            }
        }

        if settings.content.includesNotes, !snapshot.notes.isEmpty {
            appendSectionHeading("书摘", count: snapshot.notes.count, anchor: "notes", to: &result)
            var renderedChapterID: Int64?
            for (index, note) in snapshot.notes.enumerated() {
                if index > 0 { result.append(.separator) }
                if let chapter = note.chapter, chapter.id != renderedChapterID {
                    let indent = CGFloat(max(0, chapter.level)) * 18
                    result.append(.text(
                        attributed(chapter.title, style: .chapter(level: chapter.level), headIndent: indent),
                        before: 8,
                        after: 12,
                        keepTogether: true,
                        anchor: "chapter-\(chapter.id)"
                    ))
                    renderedChapterID = chapter.id
                }
                let content = Self.clearHTML(note.content)
                if !content.isEmpty {
                    result.append(.text(
                        attributed(content, style: .body(fontSize: settings.pdfReadingFontSize)),
                        before: 0,
                        after: 0,
                        keepTogether: settings.pdfKeepsItemTogether,
                        anchor: "note-\(note.id)"
                    ))
                }
                if let idea = note.idea.map(Self.clearHTML), !idea.isEmpty {
                    result.append(.text(
                        attributed(idea, style: .idea(fontSize: settings.pdfReadingFontSize)),
                        before: 10,
                        after: 0,
                        keepTogether: settings.pdfKeepsItemTogether,
                        anchor: content.isEmpty ? "note-\(note.id)" : nil
                    ))
                }
                let noteImages = note.images.compactMap { images[$0.url] }
                if !noteImages.isEmpty { result.append(.images(noteImages)) }
                let meta = noteMetadata(
                    note,
                    settings: settings,
                    localeIdentifier: localeIdentifier,
                    timeZoneIdentifier: timeZoneIdentifier
                )
                if !meta.isEmpty {
                    result.append(.text(
                        attributed(meta, style: .metadata),
                        before: 10,
                        after: 0,
                        keepTogether: true,
                        anchor: nil
                    ))
                }
            }
        }

        if settings.content.includesRelatedNotes, !snapshot.relatedNotes.isEmpty {
            appendSectionHeading("相关", count: snapshot.relatedNotes.count, anchor: "related", to: &result)
            var renderedCategoryID: Int64?
            for (index, related) in snapshot.relatedNotes.enumerated() {
                if index > 0 { result.append(.separator) }
                if related.categoryID != renderedCategoryID, !related.categoryTitle.isEmpty {
                    result.append(.text(
                        attributed(related.categoryTitle, style: .chapter(level: 0)),
                        before: 8,
                        after: 12,
                        keepTogether: true,
                        anchor: "related-category-\(related.categoryID)"
                    ))
                    renderedCategoryID = related.categoryID
                }
                let title = related.contentBook?.name ?? related.title
                if !title.isEmpty {
                    result.append(.text(
                        attributed(title, style: .itemTitle),
                        before: 0,
                        after: 9,
                        keepTogether: true,
                        anchor: "related-\(related.id)"
                    ))
                }
                let content = Self.clearHTML(related.content)
                if !content.isEmpty {
                    result.append(.text(
                        attributed(content, style: .body(fontSize: settings.pdfReadingFontSize)),
                        before: 0,
                        after: 0,
                        keepTogether: settings.pdfKeepsItemTogether,
                        anchor: title.isEmpty ? "related-\(related.id)" : nil
                    ))
                }
                let relatedImages = related.images.compactMap { images[$0.url] }
                if !relatedImages.isEmpty { result.append(.images(relatedImages)) }
            }
        }

        if settings.content.includesReviews, !snapshot.reviews.isEmpty {
            appendSectionHeading("书评", count: snapshot.reviews.count, anchor: "reviews", to: &result)
            for (index, review) in snapshot.reviews.enumerated() {
                if index > 0 { result.append(.separator) }
                if !review.title.isEmpty {
                    result.append(.text(
                        attributed(review.title, style: .itemTitle),
                        before: 0,
                        after: 9,
                        keepTogether: true,
                        anchor: "review-\(review.id)"
                    ))
                }
                let content = Self.clearHTML(review.content)
                if !content.isEmpty {
                    result.append(.text(
                        attributed(content, style: .body(fontSize: settings.pdfReadingFontSize)),
                        before: 0,
                        after: 0,
                        keepTogether: settings.pdfKeepsItemTogether,
                        anchor: review.title.isEmpty ? "review-\(review.id)" : nil
                    ))
                }
                let reviewImages = review.images.compactMap { images[$0.url] }
                if !reviewImages.isEmpty { result.append(.images(reviewImages)) }
                if settings.includesDateTime, review.createdTime > 0 {
                    result.append(.text(
                        attributed(
                            dateText(
                                review.createdTime,
                                localeIdentifier: localeIdentifier,
                                timeZoneIdentifier: timeZoneIdentifier
                            ),
                            style: .metadata
                        ),
                        before: 10,
                        after: 0,
                        keepTogether: true,
                        anchor: nil
                    ))
                }
            }
        }
        return result
    }

    private func appendSectionHeading(
        _ title: String,
        count: Int,
        anchor: String,
        to elements: inout [Element]
    ) {
        elements.append(.text(
            attributed(title, style: .sectionTitle),
            before: elements.isEmpty ? 0 : 34,
            after: 7,
            keepTogether: true,
            anchor: anchor
        ))
        elements.append(.text(
            attributed("\(count) 项", style: .metadata),
            before: 0,
            after: 18,
            keepTogether: true,
            anchor: nil
        ))
    }

    /// CoreText 只负责计算每个不可变文本块的可见字符范围；分页结束后渲染阶段不再改变任何 frame。
    private func layoutBody(_ elements: [Element]) -> ([PagePlan], [String: AnchorLocation]) {
        var pages = [PagePlan()]
        var anchors: [String: AnchorLocation] = [:]
        var y = Layout.top

        func beginPage() {
            pages.append(PagePlan())
            y = Layout.top
        }

        for element in elements {
            switch element {
            case .separator:
                if y + Layout.itemSeparator > Layout.bottom { beginPage() }
                y += Layout.itemSeparator
            case .images(let images):
                for row in stride(from: 0, to: images.count, by: Layout.imageColumns) {
                    let values = Array(images[row..<min(row + Layout.imageColumns, images.count)])
                    let cellWidth = (Layout.width - Layout.imageGap * 3) / 4
                    let heights = values.map { image in
                        min(Layout.imageMaximumHeight, image.size.height * cellWidth / max(1, image.size.width))
                    }
                    let height = heights.max() ?? 0
                    if y + 12 + height > Layout.bottom { beginPage() }
                    y += 12
                    for (index, image) in values.enumerated() {
                        let imageHeight = heights[index]
                        let frame = CGRect(
                            x: Layout.left + CGFloat(index) * (cellWidth + Layout.imageGap),
                            y: y + height - imageHeight,
                            width: cellWidth,
                            height: imageHeight
                        )
                        pages[pages.count - 1].imageBlocks.append(.init(image: image, frame: frame))
                    }
                    y += height
                }
            case let .text(attributed, before, after, keepTogether, anchor):
                y += before
                let completeHeight = textHeight(attributed, width: Layout.width)
                if keepTogether,
                   completeHeight <= Layout.usableHeight,
                   y + completeHeight > Layout.bottom {
                    beginPage()
                }
                var remaining = attributed
                var isFirstChunk = true
                while remaining.length > 0 {
                    let available = Layout.bottom - y
                    if available < 12 {
                        beginPage()
                        continue
                    }
                    let visibleLength = visibleStringLength(
                        remaining,
                        width: Layout.width,
                        height: available
                    )
                    if visibleLength <= 0 {
                        beginPage()
                        continue
                    }
                    let chunk = remaining.attributedSubstring(from: NSRange(location: 0, length: visibleLength))
                    let height = min(available, textHeight(chunk, width: Layout.width))
                    if isFirstChunk, let anchor {
                        anchors[anchor] = AnchorLocation(
                            bodyPageIndex: pages.count - 1,
                            top: y
                        )
                        pages[pages.count - 1].anchors[anchor] = y
                    }
                    pages[pages.count - 1].textBlocks.append(.init(
                        attributed: chunk,
                        frame: CGRect(x: Layout.left, y: y, width: Layout.width, height: height)
                    ))
                    y += height
                    isFirstChunk = false
                    if visibleLength == remaining.length { break }
                    remaining = remaining.attributedSubstring(from: NSRange(
                        location: visibleLength,
                        length: remaining.length - visibleLength
                    ))
                    beginPage()
                }
                y += after
            }
        }
        return (pages, anchors)
    }

    private func makeTOCEntries(
        _ snapshot: ExportBookSnapshot,
        settings: ExportSettingsSnapshot,
        anchors: [String: AnchorLocation]
    ) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        if anchors["book-info"] != nil {
            entries.append(.init(title: "书籍信息", depth: 0, anchor: "book-info"))
        }
        if settings.content.includesNotes {
            entries.append(.init(title: "书摘", depth: 0, anchor: anchors["notes"] == nil ? nil : "notes"))
            for chapter in snapshot.chapters {
                let anchor = "chapter-\(chapter.id)"
                entries.append(.init(
                    title: chapter.title,
                    depth: max(1, chapter.level + 1),
                    anchor: anchors[anchor] == nil ? nil : anchor
                ))
            }
        }
        if settings.content.includesRelatedNotes {
            entries.append(.init(title: "相关", depth: 0, anchor: anchors["related"] == nil ? nil : "related"))
            var seen = Set<Int64>()
            for related in snapshot.relatedNotes where seen.insert(related.categoryID).inserted {
                let anchor = "related-category-\(related.categoryID)"
                entries.append(.init(
                    title: related.categoryTitle.isEmpty ? "未分类" : related.categoryTitle,
                    depth: 1,
                    anchor: anchors[anchor] == nil ? nil : anchor
                ))
            }
        }
        if settings.content.includesReviews {
            entries.append(.init(title: "书评", depth: 0, anchor: anchors["reviews"] == nil ? nil : "reviews"))
        }
        return entries
    }

    private func layoutTOC(_ entries: [TOCEntry]) -> [TOCPage] {
        guard !entries.isEmpty else { return [] }
        var pages = [TOCPage()]
        var y = Layout.tocTop
        for entry in entries {
            let rowHeight: CGFloat = entry.depth == 0 ? 28 : 24
            let before: CGFloat = entry.depth == 0 && !pages[pages.count - 1].rows.isEmpty ? 8 : 0
            if y + before + rowHeight > Layout.bottom {
                pages.append(TOCPage())
                y = Layout.tocTop
            } else {
                y += before
            }
            pages[pages.count - 1].rows.append(.init(
                entry: entry,
                frame: CGRect(x: Layout.left, y: y, width: Layout.width, height: rowHeight)
            ))
            y += rowHeight
        }
        return pages
    }

    private func render(
        book: ExportBookSnapshot,
        settings: ExportSettingsSnapshot,
        cover: UIImage?,
        bodyPages: [PagePlan],
        anchors: [String: AnchorLocation],
        tocPages: [TOCPage]
    ) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: book.book.name,
            kCGPDFContextCreator as String: "纸间书摘"
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: Layout.pageSize),
            format: format
        )
        let runningTitle = Self.runningTitle(book.book.name)
        let colors = Self.colorScheme(fallbackSeed: book.book.name.ifEmpty(String(book.book.id)))
        return renderer.pdfData { context in
            context.beginPage()
            drawCover(book, settings: settings, image: cover, colors: colors)

            for tocPage in tocPages {
                context.beginPage()
                drawRunningHeader(runningTitle)
                "目录".draw(
                    at: CGPoint(x: Layout.left, y: 70),
                    withAttributes: textAttributes(.tocTitle)
                )
                colors.rule.setStroke()
                let rule = UIBezierPath()
                rule.move(to: CGPoint(x: Layout.left, y: 110))
                rule.addLine(to: CGPoint(x: Layout.pageSize.width - Layout.right, y: 110))
                rule.lineWidth = 0.8
                rule.stroke()
                for row in tocPage.rows {
                    drawTOCRow(row, anchors: anchors, colors: colors)
                    if let anchor = row.entry.anchor {
                        context.setDestinationWithName(anchor, for: row.frame)
                    }
                }
            }

            for (pageIndex, page) in bodyPages.enumerated() {
                context.beginPage()
                drawRunningHeader(runningTitle)
                drawPageNumber(pageIndex + 1)
                for (anchor, top) in page.anchors {
                    context.addDestination(withName: anchor, at: CGPoint(x: Layout.left, y: top))
                }
                for block in page.textBlocks { drawCoreText(block) }
                for block in page.imageBlocks {
                    block.image.draw(in: block.frame)
                }
            }
        }
    }

    private func drawCover(
        _ snapshot: ExportBookSnapshot,
        settings: ExportSettingsSnapshot,
        image: UIImage?,
        colors: ColorScheme
    ) {
        let book = snapshot.book
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: Layout.pageSize))
        colors.spine.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 26, height: Layout.pageSize.height))
        colors.rule.setStroke()
        let spineRule = UIBezierPath()
        spineRule.move(to: CGPoint(x: 26, y: 0))
        spineRule.addLine(to: CGPoint(x: 26, y: Layout.pageSize.height))
        spineRule.lineWidth = 0.7
        spineRule.stroke()
        drawSpineText(
            book.name,
            startY: 72,
            maximumY: 570,
            fontSize: 10.5,
            color: colors.spineText
        )
        drawSpineText(
            book.author,
            startY: 660,
            maximumY: 790,
            fontSize: 8.5,
            color: colors.spineText
        )
        if let image {
            drawAspectFit(image, in: CGRect(x: 82, y: 86, width: 148, height: 208))
        }
        let textX: CGFloat = image == nil ? 82 : 282
        let textWidth = Layout.pageSize.width - textX - 58
        var textY: CGFloat = 91
        let title = book.name.ifEmpty("未命名书籍")
        let titleAttributes = textAttributes(.coverTitle)
        let titleHeight = min(
            ceil(title.boundingRect(
                with: CGSize(width: textWidth, height: 27 * 1.12 * 5),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: titleAttributes,
                context: nil
            ).height),
            27 * 1.12 * 5
        )
        title.draw(
            with: CGRect(x: textX, y: textY, width: textWidth, height: titleHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttributes,
            context: nil
        )
        textY += titleHeight
        if !book.author.isEmpty {
            textY += 16
            let authorAttributes = textAttributes(.coverAuthor)
            let authorHeight = min(
                ceil(book.author.boundingRect(
                    with: CGSize(width: textWidth, height: 34),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: authorAttributes,
                    context: nil
                ).height),
                34
            )
            book.author.draw(
                with: CGRect(x: textX, y: textY, width: textWidth, height: authorHeight),
                options: [.usesLineFragmentOrigin],
                attributes: authorAttributes,
                context: nil
            )
            textY += authorHeight
        }
        let publishing = [
            book.translator.isEmpty ? nil : "译者 \(book.translator)",
            book.press.isEmpty ? nil : book.press,
            book.pubDate.isEmpty ? nil : book.pubDate
        ].compactMap { $0 }.joined(separator: " · ")
        if !publishing.isEmpty {
            textY += 13
            let publishingAttributes = textAttributes(.metadata)
            let publishingHeight = min(
                ceil(publishing.boundingRect(
                    with: CGSize(width: textWidth, height: 42),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: publishingAttributes,
                    context: nil
                ).height),
                42
            )
            publishing.draw(
                with: CGRect(x: textX, y: textY, width: textWidth, height: publishingHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: publishingAttributes,
                context: nil
            )
            textY += publishingHeight
        }
        let counts = [
            settings.content.includesNotes ? "\(snapshot.notes.count) 条书摘" : nil,
            settings.content.includesRelatedNotes ? "\(snapshot.relatedNotes.count) 条相关" : nil,
            settings.content.includesReviews ? "\(snapshot.reviews.count) 篇书评" : nil
        ].compactMap { $0 }.joined(separator: " · ")
        let countY = max(342, textY + 24)
        colors.rule.setStroke()
        let countRule = UIBezierPath()
        countRule.move(to: CGPoint(x: textX, y: countY))
        countRule.addLine(to: CGPoint(x: textX + min(textWidth, 180), y: countY))
        countRule.lineWidth = 0.8
        countRule.stroke()
        counts.draw(
            with: CGRect(x: textX, y: countY + 17, width: textWidth, height: 28),
            options: [.usesLineFragmentOrigin],
            attributes: [
                .font: AppTypography.uiFixed(
                    baseSize: 9.5,
                    textStyle: .caption2,
                    weight: .medium,
                    minimumPointSize: 9.5
                ),
                .foregroundColor: Ink.secondary
            ],
            context: nil
        )
    }

    private func drawTOCRow(
        _ row: TOCRow,
        anchors: [String: AnchorLocation],
        colors _: ColorScheme
    ) {
        let indent = CGFloat(row.entry.depth) * Layout.tocIndent
        let attributes = textAttributes(row.entry.depth == 0 ? .tocRoot : .tocChild)
        let titleRect = CGRect(
            x: row.frame.minX + indent,
            y: row.frame.minY + 2,
            width: row.frame.width - indent - 54,
            height: row.frame.height - 4
        )
        row.entry.title.draw(
            with: titleRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
        if let anchor = row.entry.anchor, let location = anchors[anchor] {
            let number = String(location.bodyPageIndex + 1)
            let numberAttributes = textAttributes(.tocPageNumber)
            let numberSize = number.size(withAttributes: numberAttributes)
            let numberStart = row.frame.maxX - numberSize.width
            let titleWidth = min(
                row.entry.title.size(withAttributes: attributes).width,
                titleRect.width
            )
            let leaderStart = titleRect.minX + titleWidth + 8
            let leaderEnd = numberStart - 8
            let leaderSpan = leaderEnd - leaderStart
            if leaderSpan >= 28 {
                let dotCount = Int(floor(leaderSpan / 4))
                if dotCount >= 5, let cgContext = UIGraphicsGetCurrentContext() {
                    cgContext.saveGState()
                    cgContext.setFillColor(Ink.tocLeader.cgColor)
                    let first = leaderStart + (leaderSpan - CGFloat(dotCount - 1) * 4) / 2
                    let y = row.frame.minY + 13
                    for index in 0..<dotCount {
                        cgContext.fillEllipse(in: CGRect(
                            x: first + CGFloat(index) * 4 - 0.4,
                            y: y - 0.4,
                            width: 0.8,
                            height: 0.8
                        ))
                    }
                    cgContext.restoreGState()
                }
            }
            number.draw(
                with: CGRect(x: row.frame.maxX - 34, y: row.frame.minY + 2, width: 34, height: 18),
                options: [.usesLineFragmentOrigin],
                attributes: numberAttributes,
                context: nil
            )
        }
    }

    private func drawCoreText(_ block: TextBlock) {
        guard let cgContext = UIGraphicsGetCurrentContext() else { return }
        cgContext.saveGState()
        cgContext.textMatrix = .identity
        cgContext.translateBy(x: 0, y: Layout.pageSize.height)
        cgContext.scaleBy(x: 1, y: -1)
        let coreFrame = CGRect(
            x: block.frame.minX,
            y: Layout.pageSize.height - block.frame.maxY,
            width: block.frame.width,
            height: block.frame.height
        )
        let path = CGPath(rect: coreFrame, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(block.attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: block.attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, cgContext)
        cgContext.restoreGState()
    }

    private func drawRunningHeader(_ title: String) {
        title.draw(at: CGPoint(x: Layout.left, y: 22), withAttributes: textAttributes(.running))
    }

    private func drawPageNumber(_ value: Int) {
        let text = String(value)
        let size = text.size(withAttributes: textAttributes(.running))
        text.draw(
            at: CGPoint(x: (Layout.pageSize.width - size.width) / 2, y: Layout.pageSize.height - 32),
            withAttributes: textAttributes(.running)
        )
    }

    private func addOutline(
        to data: Data,
        book: ExportBookSnapshot,
        entries: [TOCEntry],
        anchors: [String: AnchorLocation],
        tocPageCount: Int
    ) -> Data {
        guard let document = PDFDocument(data: data) else { return data }
        let root = PDFOutline()
        root.label = book.book.name.ifEmpty("读书笔记")
        var parentForDepth: [Int: PDFOutline] = [-1: root]
        for entry in entries {
            guard let anchor = entry.anchor,
                  let location = anchors[anchor],
                  let page = document.page(at: 1 + tocPageCount + location.bodyPageIndex) else {
                continue
            }
            let item = PDFOutline()
            item.label = entry.title
            item.destination = PDFDestination(
                page: page,
                at: CGPoint(x: Layout.left, y: Layout.pageSize.height - location.top)
            )
            let parent = parentForDepth[entry.depth - 1] ?? root
            parent.insertChild(item, at: parent.numberOfChildren)
            parentForDepth[entry.depth] = item
            parentForDepth = parentForDepth.filter { $0.key <= entry.depth }
        }
        document.outlineRoot = root
        return document.dataRepresentation() ?? data
    }

    private func collectedImageURLs(_ snapshot: ExportBookSnapshot) -> [String] {
        var values = [snapshot.book.cover]
        values += snapshot.notes.flatMap { $0.images.map(\.url) }
        values += snapshot.relatedNotes.flatMap { $0.images.map(\.url) }
        values += snapshot.reviews.flatMap { $0.images.map(\.url) }
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 图片按稳定 URL 顺序串行读取，避免批量导出瞬间制造并发峰值；单图错误降级为无图，取消继续抛出。
    private func loadImages(_ urls: [String]) async throws -> [String: UIImage] {
        var result: [String: UIImage] = [:]
        for rawValue in urls {
            try Task.checkCancellation()
            guard let url = URL(string: rawValue) else { continue }
            do {
                let data: Data
                if url.isFileURL {
                    data = try Data(contentsOf: url, options: .mappedIfSafe)
                } else {
                    let response = try await session.data(from: url)
                    data = response.0
                }
                if let image = UIImage(data: data) { result[rawValue] = image }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return result
    }

    private func visibleStringLength(
        _ value: NSAttributedString,
        width: CGFloat,
        height: CGFloat
    ) -> Int {
        let framesetter = CTFramesetterCreateWithAttributedString(value)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        return CTFrameGetVisibleStringRange(frame).length
    }

    private func textHeight(_ value: NSAttributedString, width: CGFloat) -> CGFloat {
        let framesetter = CTFramesetterCreateWithAttributedString(value)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: value.length),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(size.height + 1)
    }

    private enum TextStyle {
        case heading
        case sectionTitle
        case chapter(level: Int)
        case itemTitle
        case body(fontSize: Double)
        case secondaryBody
        case idea(fontSize: Double)
        case metadata
        case coverTitle
        case coverAuthor
        case running
        case tocTitle
        case tocRoot
        case tocChild
        case tocPageNumber
    }

    private func attributed(
        _ text: String,
        style: TextStyle,
        headIndent: CGFloat = 0
    ) -> NSAttributedString {
        let attributes = textAttributes(style, headIndent: headIndent)
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func textAttributes(
        _ style: TextStyle,
        headIndent: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = headIndent
        let font: UIFont
        let color: UIColor
        switch style {
        case .heading:
            font = titleFont(size: 20)
            color = Ink.primary
            paragraph.lineHeightMultiple = 1.1
        case .sectionTitle:
            font = titleFont(size: 22)
            color = Ink.primary
            paragraph.lineHeightMultiple = 1.1
        case .chapter(let level):
            font = titleFont(size: max(12, 16 - CGFloat(level)))
            color = Ink.primary
            paragraph.lineHeightMultiple = 1.18
        case .itemTitle:
            font = titleFont(size: 14)
            color = Ink.primary
            paragraph.lineHeightMultiple = 1.2
        case .body(let fontSize):
            font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif) ?? .preferredFontDescriptor(withTextStyle: .body), size: fontSize)
            color = Ink.primary
            paragraph.lineHeightMultiple = 1.42
        case .secondaryBody:
            font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif) ?? .preferredFontDescriptor(withTextStyle: .body), size: 10.5)
            color = Ink.secondary
            paragraph.lineHeightMultiple = 1.42
        case .idea(let fontSize):
            font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif) ?? .preferredFontDescriptor(withTextStyle: .body), size: fontSize)
            color = Ink.warmGray
            paragraph.lineHeightMultiple = 1.42
        case .metadata:
            font = UIFont.preferredFont(forTextStyle: .caption2).withSize(8.7)
            color = Ink.metadata
            paragraph.lineHeightMultiple = 1.25
        case .coverTitle:
            font = titleFont(size: 27)
            color = Ink.primary
            paragraph.lineHeightMultiple = 1.12
        case .coverAuthor:
            font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif) ?? .preferredFontDescriptor(withTextStyle: .body), size: 12)
            color = Ink.secondary
        case .running:
            font = UIFont.preferredFont(forTextStyle: .caption2).withSize(8)
            color = Ink.metadata
        case .tocTitle:
            font = titleFont(size: 24)
            color = Ink.primary
        case .tocRoot:
            font = titleFont(size: 11.5)
            color = Ink.primary
        case .tocChild:
            font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif) ?? .preferredFontDescriptor(withTextStyle: .body), size: 10.5)
            color = Ink.secondary
        case .tocPageNumber:
            font = UIFont.preferredFont(forTextStyle: .caption2).withSize(8.7)
            color = Ink.metadata
            paragraph.alignment = .right
        }
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func titleFont(size: CGFloat) -> UIFont {
        UIFont(name: "SourceHanSerifSC-SemiBold", size: size)
            ?? UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline).withDesign(.serif) ?? .preferredFontDescriptor(withTextStyle: .headline), size: size)
    }

    private func drawSpineText(
        _ value: String,
        startY: CGFloat,
        maximumY: CGFloat,
        fontSize: CGFloat,
        color: UIColor
    ) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let step = fontSize + 3
        let maximumCharacters = max(1, Int((maximumY - startY) / step))
        let characters = Array(text.prefix(maximumCharacters))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: titleFont(size: fontSize),
            .foregroundColor: color
        ]
        var y = startY
        for character in characters {
            let glyph = String(character)
            let size = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: CGPoint(x: 13 - size.width / 2, y: y),
                withAttributes: attributes
            )
            y += step
        }
    }

    /// 复刻 Android 无封面时的 Java 字符串种子与 HSL 归一化，保证色带在不同设备上稳定。
    private static func colorScheme(fallbackSeed: String) -> ColorScheme {
        var hash: Int32 = 0
        for unit in fallbackSeed.utf16 {
            hash = hash &* 31 &+ Int32(unit)
        }
        let red = CGFloat((UInt32(bitPattern: hash) >> 16) & 0xff) / 255
        let green = CGFloat((UInt32(bitPattern: hash) >> 8) & 0xff) / 255
        let blue = CGFloat(UInt32(bitPattern: hash) & 0xff) / 255
        var representative = HSL(uiColor: UIColor.xmSRGB(red: red, green: green, blue: blue))
        if representative.saturation < 0.08 {
            representative.saturation = 0
            representative.lightness = representative.lightness.exportPDFClamped(to: 0.32...0.86)
        } else {
            representative.saturation = min(representative.saturation, 0.72)
            representative.lightness = representative.lightness.exportPDFClamped(to: 0.24...0.82)
        }

        var spine = representative
        spine.saturation = spine.saturation < 0.08 ? 0 : min(spine.saturation * 0.24, 0.18)
        spine.lightness = 0.92

        var accent = representative
        if accent.saturation < 0.08 {
            accent.saturation = 0
            accent.lightness = accent.lightness.exportPDFClamped(to: 0.28...0.76)
        } else {
            accent.saturation = accent.saturation.exportPDFClamped(to: 0.22...0.78)
            accent.lightness = accent.lightness.exportPDFClamped(to: 0.24...0.76)
        }
        accent.saturation = accent.saturation < 0.08 ? 0 : accent.saturation.exportPDFClamped(to: 0.18...0.34)
        accent.lightness = accent.lightness.exportPDFClamped(to: 0.26...0.38)
        while contrast(accent.color, .white) < 4.5, accent.lightness > 0.18 {
            accent.lightness -= 0.02
        }
        let accentColor = contrast(accent.color, .white) >= 4.5 ? accent.color : Ink.warmGray
        let spineColor = spine.color
        let spineText = contrast(Ink.warmGray, spineColor) >= 4.5 ? Ink.warmGray : .black
        return ColorScheme(
            spine: spineColor,
            spineText: spineText,
            rule: blend(accentColor, with: .white, fraction: 0.84)
        )
    }

    private struct HSL {
        var hue: CGFloat
        var saturation: CGFloat
        var lightness: CGFloat

        init(uiColor: UIColor) {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            let lightness = brightness * (1 - saturation / 2)
            self.hue = hue
            self.lightness = lightness
            self.saturation = lightness == 0 || lightness == 1
                ? 0
                : (brightness - lightness) / min(lightness, 1 - lightness)
        }

        var color: UIColor {
            let brightness = lightness + saturation * min(lightness, 1 - lightness)
            let hsvSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
            return UIColor.xmSRGB(
                red: brightness * (1 - hsvSaturation + hsvSaturation * Self.hueChannel(hue + 1 / 3)),
                green: brightness * (1 - hsvSaturation + hsvSaturation * Self.hueChannel(hue)),
                blue: brightness * (1 - hsvSaturation + hsvSaturation * Self.hueChannel(hue - 1 / 3))
            )
        }

        private static func hueChannel(_ value: CGFloat) -> CGFloat {
            let wrapped = value - floor(value)
            if wrapped < 1 / 6 { return wrapped * 6 }
            if wrapped < 1 / 2 { return 1 }
            if wrapped < 2 / 3 { return (2 / 3 - wrapped) * 6 }
            return 0
        }
    }

    private static func contrast(_ lhs: UIColor, _ rhs: UIColor) -> CGFloat {
        let first = relativeLuminance(lhs)
        let second = relativeLuminance(rhs)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    private static func blend(_ color: UIColor, with other: UIColor, fraction: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var otherRed: CGFloat = 0
        var otherGreen: CGFloat = 0
        var otherBlue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        other.getRed(&otherRed, green: &otherGreen, blue: &otherBlue, alpha: nil)
        return UIColor.xmSRGB(
            red: red + (otherRed - red) * fraction,
            green: green + (otherGreen - green) * fraction,
            blue: blue + (otherBlue - blue) * fraction,
            alpha: 1
        )
    }

    private func noteMetadata(
        _ note: DesktopWebBookNoteSnapshot,
        settings: ExportSettingsSnapshot,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> String {
        var values: [String] = []
        if settings.includesPage, let position = note.position, !position.isEmpty {
            let unit = note.positionUnit == 2 ? "页码" : note.positionUnit == 0 ? "进度" : "位置"
            values.append("\(unit)：\(position)\(note.positionUnit == 0 ? "%" : "")")
        }
        if settings.includesDateTime, note.createdTime > 0 {
            values.append(dateText(note.createdTime, localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier))
        }
        if settings.includesTags, !note.tags.isEmpty {
            values.append(note.tags.map { "#\($0.name)" }.joined(separator: " "))
        }
        return values.joined(separator: " | ")
    }

    private func dateText(
        _ milliseconds: Int64,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    private func drawAspectFit(_ image: UIImage, in rect: CGRect) {
        let scale = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }

    nonisolated private static func clearHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedAuthorIntroduction(_ value: String) -> String {
        value.replacingOccurrences(
            of: "\\s*:recycling_symbol:\\s*",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runningTitle(_ bookName: String) -> String {
        let value = bookName.isEmpty ? "读书笔记" : "《\(bookName)》读书笔记"
        guard value.count > 32 else { return value }
        return String(value.prefix(31)) + "…"
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

private extension CGFloat {
    func exportPDFClamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
