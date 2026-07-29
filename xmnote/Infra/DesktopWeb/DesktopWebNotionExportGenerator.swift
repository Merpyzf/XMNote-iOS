/**
 * [INPUT]: 依赖 Web 导出只读快照、导出选择、设置与调用时冻结的时间戳
 * [OUTPUT]: 对外提供 Android NotionGenerator 对齐的页面标题和 Notion block JSON
 * [POS]: Infra 层 Notion 纯生成器；不访问数据库、网络、文件系统或 Package HTTP 类型
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import XMNoteWeb

/// 单个 Notion 页面；body 尚未写入 database parent，由远端服务准备目标数据库后统一补齐。
nonisolated struct DesktopWebNotionExportPage {
    let title: String
    let body: [String: Any]
}

/// 复刻 Android NotionGenerator 的 2,000 UTF-16 单元文本切片与 100 block 分页行为。
nonisolated enum DesktopWebNotionExportGenerator {
    /// 按 Android 固定顺序生成书评、相关、书摘页面，并为拆分页追加 `-1` 起始后缀。
    static func pages(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any],
        timestamp: String
    ) -> [DesktopWebNotionExportPage] {
        var result: [DesktopWebNotionExportPage] = []
        if selection.review, !bundle.reviews.isEmpty {
            result += titledPages(
                baseTitle: "\(bundle.book.name)_书评_\(timestamp)",
                bodies: reviewPages(bundle, settings: settings)
            )
        }
        if selection.relevant, !bundle.related.isEmpty {
            result += titledPages(
                baseTitle: "\(bundle.book.name)_相关_\(timestamp)",
                bodies: relatedPages(bundle, settings: settings)
            )
        }
        if selection.note {
            result += titledPages(
                baseTitle: "\(bundle.book.name)_书摘_\(timestamp)",
                bodies: notePages(bundle, settings: settings)
            )
        }
        return result
    }
}

nonisolated extension DesktopWebNotionExportGenerator {
    struct BlockPaginator {
        var pages: [[[String: Any]]]
        var blockCount: Int
        var initialBlockCount: Int

        /// 创建分页器；related 使用 Android 写死的 3 作为首屏计数，其余使用实际头部数量。
        init(initialBlocks: [[String: Any]], initialCounter: Int? = nil) {
            pages = [initialBlocks]
            blockCount = initialCounter ?? initialBlocks.count
            initialBlockCount = initialBlocks.count
        }

        /// 在写入前检查 100 block 上限；第一次拆页保留 Android 的初始计数复位差异。
        mutating func append(_ block: [String: Any]) {
            if blockCount >= 100 {
                pages.append([])
                blockCount = initialBlockCount
                initialBlockCount = 0
            }
            pages[pages.count - 1].append(block)
            blockCount += 1
        }
    }

    /// 为每个 JSON 页面写入数据库 `Page` 标题属性。
    static func titledPages(
        baseTitle: String,
        bodies: [[String: Any]]
    ) -> [DesktopWebNotionExportPage] {
        bodies.enumerated().map { index, body in
            var value = body
            let title = bodies.count == 1 ? baseTitle : "\(baseTitle)-\(index + 1)"
            value["properties"] = [
                "Page": [
                    "title": [
                        ["text": ["content": title]]
                    ]
                ]
            ]
            return .init(title: title, body: value)
        }
    }

    /// 生成书摘 Notion 页面，章节在相邻章节变化时以完整路径 heading_2 输出。
    static func notePages(
        _ bundle: DesktopWebExportBundle,
        settings: [String: Any]
    ) -> [[String: Any]] {
        let template = pageTemplate(icon: "📖", cover: bundle.book.cover)
        let initial = initialBlocks(
            book: bundle.book,
            noteCount: bundle.notes.count,
            settings: settings
        )
        var paginator = BlockPaginator(initialBlocks: initial)
        var lastChapterID: Int64?
        for (index, note) in bundle.notes.enumerated() {
            if let chapter = note.chapter,
               chapter.id != lastChapterID,
               !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                paginator.append(heading2(chapterDisplayTitle(chapter)))
                lastChapterID = chapter.id
            }
            for text in limitedTextList(clearHTML(note.content)) where !text.isEmpty {
                paginator.append(paragraph(text))
            }
            if let idea = note.idea.map(clearHTML), !idea.isEmpty {
                for text in limitedTextList(idea) {
                    paginator.append(callout(text))
                }
            }
            for image in note.images {
                paginator.append(imageBlock(image.url))
            }
            if settings.bool("includeTag", fallback: true), !note.tags.isEmpty {
                paginator.append(paragraph(
                    note.tags.map { "#\($0.name)" }.joined(separator: "  "),
                    color: "gray"
                ))
            }
            if let info = noteInfo(note, settings: settings) {
                paginator.append(info)
            }
            if index != bundle.notes.count - 1 {
                paginator.append(divider())
            }
        }
        return paginator.pages.map { body(template: template, children: $0) }
    }

    /// 生成相关内容 Notion 页面，并保留 Android 首屏 block 计数固定为 3 的历史行为。
    static func relatedPages(
        _ bundle: DesktopWebExportBundle,
        settings: [String: Any]
    ) -> [[String: Any]] {
        let template = pageTemplate(icon: "🗂", cover: bundle.book.cover)
        let initial = initialBlocks(book: bundle.book, settings: settings)
        var paginator = BlockPaginator(initialBlocks: initial, initialCounter: 3)
        var lastCategory = ""
        for (index, value) in bundle.related.enumerated() {
            if value.categoryTitle != lastCategory {
                paginator.append(heading2(value.categoryTitle))
                lastCategory = value.categoryTitle
            }
            if let book = value.contentBook {
                paginator.append(paragraph(relatedBookInfo(book)))
                if settings.bool("includeDateTime", fallback: true) {
                    paginator.append(paragraph(dateText(value.createdTime), color: "gray"))
                }
            } else {
                if !value.title.isEmpty {
                    paginator.append(heading3(value.title))
                }
                let content = clearHTML(value.content)
                if !content.isEmpty {
                    for text in limitedTextList(content) {
                        paginator.append(paragraph(text))
                    }
                }
                for image in value.images {
                    paginator.append(imageBlock(image.url))
                }
                if settings.bool("includeDateTime", fallback: true) {
                    paginator.append(paragraph(dateText(value.createdTime), color: "gray"))
                }
            }
            if index != bundle.related.count - 1 {
                paginator.append(divider())
            }
        }
        return paginator.pages.map { body(template: template, children: $0) }
    }

    /// 生成书评 Notion 页面；标题 trim、图片和灰色日期均与 Android 一致。
    static func reviewPages(
        _ bundle: DesktopWebExportBundle,
        settings: [String: Any]
    ) -> [[String: Any]] {
        let template = pageTemplate(icon: "💡", cover: bundle.book.cover)
        let initial = initialBlocks(book: bundle.book, settings: settings)
        var paginator = BlockPaginator(initialBlocks: initial)
        for (index, review) in bundle.reviews.enumerated() {
            let title = review.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                paginator.append(heading2(title))
            }
            let content = clearHTML(review.content)
            if !content.isEmpty {
                for text in limitedTextList(content) {
                    paginator.append(paragraph(text))
                }
            }
            for image in review.images {
                paginator.append(imageBlock(image.url))
            }
            if settings.bool("includeDateTime", fallback: true) {
                paginator.append(paragraph(dateText(review.createdTime), color: "gray"))
            }
            if index != bundle.reviews.count - 1 {
                paginator.append(divider())
            }
        }
        return paginator.pages.map { body(template: template, children: $0) }
    }

    /// 生成每类页面共用的书籍信息、简介和 divider 头部。
    static func initialBlocks(
        book: DesktopWebBookSnapshot,
        noteCount: Int = 0,
        settings: [String: Any]
    ) -> [[String: Any]] {
        var blocks = [
            heading2("书籍信息"),
            paragraph(bookInfo(book, noteCount: noteCount))
        ]
        if settings.bool("includeBookInfo", fallback: true) {
            if !book.summary.isEmpty {
                blocks.append(heading3("书籍简介"))
                blocks += limitedTextList(book.summary).map { paragraph($0) }
            }
            // Android 当前实现以 author 是否为空决定是否输出作者简介。
            if !book.author.isEmpty {
                blocks.append(heading3("作者简介"))
                blocks += limitedTextList(book.authorIntro).map { paragraph($0) }
            }
        }
        blocks.append(divider())
        return blocks
    }

    /// 生成不含 title、parent 和 children 的 Notion 页面模板。
    static func pageTemplate(icon: String, cover: String) -> [String: Any] {
        var value: [String: Any] = [
            "icon": ["type": "emoji", "emoji": icon]
        ]
        if !cover.isEmpty {
            value["cover"] = [
                "type": "external",
                "external": ["url": cover]
            ]
        }
        return value
    }

    /// 将分页后的 children 写回页面模板。
    static func body(
        template: [String: Any],
        children: [[String: Any]]
    ) -> [String: Any] {
        var value = template
        value["children"] = children
        return value
    }

    /// 生成 Notion 书籍信息段落，每个非空字段独占一行。
    static func bookInfo(_ book: DesktopWebBookSnapshot, noteCount: Int) -> String {
        var items: [String] = []
        if !book.name.isEmpty { items.append("《\(book.name)》") }
        if !book.cover.isEmpty { items.append("封面：\(book.cover)") }
        if !book.author.isEmpty { items.append("作者：\(book.author)") }
        if !book.translator.isEmpty { items.append("译者：\(book.translator)") }
        if !book.press.isEmpty { items.append("出版社：\(book.press)") }
        if !book.pubDate.isEmpty { items.append("出版年：\(book.pubDate)") }
        if !book.isbn.isEmpty { items.append("ISBN：\(book.isbn)") }
        if noteCount != 0 { items.append("\(noteCount) 条书摘") }
        return items.joined(separator: "\n")
    }

    /// 生成 Notion 关联书籍信息段落。
    static func relatedBookInfo(_ book: DesktopWebRelatedBookSnapshot) -> String {
        var items: [String] = []
        if !book.name.isEmpty { items.append("《\(book.name)》") }
        if !book.cover.isEmpty { items.append("封面：\(book.cover)") }
        if !book.author.isEmpty { items.append("作者：\(book.author)") }
        if let translator = book.translator, !translator.isEmpty {
            items.append("译者：\(translator)")
        }
        if !book.press.isEmpty { items.append("出版社：\(book.press)") }
        if let publicationDate = book.publicationDate, !publicationDate.isEmpty {
            items.append("出版年：\(publicationDate)")
        }
        return items.joined(separator: "\n")
    }

    /// 生成章节完整路径标题。
    static func chapterDisplayTitle(_ chapter: DesktopWebChapterSnapshot) -> String {
        let path = chapter.pathTitles.isEmpty ? [chapter.title] : chapter.pathTitles
        return path.joined(separator: " / ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 生成灰色书摘位置信息；Notion 与语雀都要求 isIncludeTime 为真才输出时间。
    static func noteInfo(
        _ note: DesktopWebBookNoteSnapshot,
        settings: [String: Any]
    ) -> [String: Any]? {
        var items: [String] = []
        if settings.bool("includePage", fallback: true),
           let position = note.position,
           !position.isEmpty {
            let unit = switch note.positionUnit {
            case 1: "页码"
            case 3: "进度"
            default: "位置"
            }
            items.append("\(unit)：\(position)\(note.positionUnit == 3 ? "%" : "")")
        }
        if settings.bool("includeDateTime", fallback: true),
           note.createdTime != 0,
           note.isIncludeTime {
            items.append(dateText(note.createdTime))
        }
        return items.isEmpty ? nil : paragraph(items.joined(separator: " | "), color: "gray")
    }

    /// 按 Java/Kotlin UTF-16 长度切成 2,000 单元片段，并保留整倍数时的尾部空片段。
    static func limitedTextList(_ text: String) -> [String] {
        let units = Array(text.utf16)
        guard units.count > 2_000 else {
            return [text]
        }
        let paragraphCount = units.count / 2_000 + 1
        return (0..<paragraphCount).map { index in
            let start = index * 2_000
            let end = min(start + 2_000, units.count)
            guard start < end else {
                return ""
            }
            return String(decoding: units[start..<end], as: UTF16.self)
        }
    }

    /// 生成 heading_2 block。
    static func heading2(_ text: String) -> [String: Any] {
        textBlock(type: "heading_2", text: text)
    }

    /// 生成 heading_3 block。
    static func heading3(_ text: String) -> [String: Any] {
        textBlock(type: "heading_3", text: text)
    }

    /// 生成 paragraph block。
    static func paragraph(_ text: String, color: String = "default") -> [String: Any] {
        textBlock(type: "paragraph", text: text, color: color)
    }

    /// 生成 Notion 文本 block 的 Android JSON 结构。
    static func textBlock(
        type: String,
        text: String,
        color: String = "default"
    ) -> [String: Any] {
        [
            "object": "block",
            "type": type,
            type: [
                "rich_text": [
                    [
                        "type": "text",
                        "text": ["content": text]
                    ]
                ],
                "color": color
            ]
        ]
    }

    /// 生成想法 callout block。
    static func callout(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "callout",
            "callout": [
                "rich_text": [
                    [
                        "type": "text",
                        "text": ["content": text]
                    ]
                ],
                "icon": ["emoji": "💡"],
                "color": "default"
            ]
        ]
    }

    /// 生成外链图片 block。
    static func imageBlock(_ url: String) -> [String: Any] {
        [
            "object": "block",
            "type": "image",
            "image": [
                "type": "external",
                "external": ["url": url]
            ]
        ]
    }

    /// 生成 divider block。
    static func divider() -> [String: Any] {
        ["type": "divider", "divider": [String: Any]()]
    }

    /// 清理 Android clearHtml 的核心可观察 HTML 标签与常用实体。
    static func clearHTML(_ value: String) -> String {
        value.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 使用本地时区输出 Android `ymdHms` 的秒级时间文本。
    static func dateText(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// 读取导出布尔设置；缺失字段使用 Android 默认值。
    nonisolated func bool(_ key: String, fallback: Bool) -> Bool {
        self[key] as? Bool ?? fallback
    }
}
