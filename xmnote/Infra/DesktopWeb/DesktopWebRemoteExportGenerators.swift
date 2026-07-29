/**
 * [INPUT]: 依赖 Web 导出只读快照、导出设置和调用时冻结的时间戳
 * [OUTPUT]: 对外提供语雀、思源与 Obsidian 的 Android 对齐远端文档正文
 * [POS]: Infra 层远端导出纯生成器；不访问数据库、网络、文件系统或 Package HTTP 类型
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import XMNoteWeb

/// 远端 Markdown 目标的标题与正文；标题已包含 Android 每页生成的秒级时间戳。
nonisolated struct DesktopWebRemoteExportPage: Sendable, Equatable {
    let title: String
    let body: String
}

/// 复刻 Android YuQueGenerator、SiYuanMarkdownGenerator 与 Obsidian MarkdownGenerator 的可观察文本。
nonisolated enum DesktopWebRemoteExportGenerators {
    /// 生成语雀专属 Markdown；其书籍信息、图片闭合标签和时间条件与普通 Markdown 不同。
    static func yuQuePages(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any],
        timestamp: String
    ) -> [DesktopWebRemoteExportPage] {
        selectedPages(bundle: bundle, selection: selection, timestamp: timestamp) { kind in
            switch kind {
            case .note:
                yuQueNotes(bundle, settings)
            case .review:
                yuQueReviews(bundle, settings)
            case .related:
                yuQueRelated(bundle, settings)
            }
        }
    }

    /// 生成思源专属 Markdown；保留 Android 为块级内容添加 div 的兼容格式。
    static func siYuanPages(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any],
        timestamp: String
    ) -> [DesktopWebRemoteExportPage] {
        selectedPages(bundle: bundle, selection: selection, timestamp: timestamp) { kind in
            switch kind {
            case .note:
                markdownNotes(bundle, settings: settings, style: .siYuan)
            case .review:
                markdownReviews(bundle, settings: settings, style: .siYuan)
            case .related:
                markdownRelated(bundle, settings: settings, style: .siYuan)
            }
        }
    }

    /// 生成 Obsidian Markdown，并按 Android 开关把书籍标签逐行追加到每一个导出页面。
    static func obsidianPages(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        settings: [String: Any],
        timestamp: String
    ) -> [DesktopWebRemoteExportPage] {
        let tags = settings.bool("obsidianExportTags", fallback: true)
            ? bundle.book.tags.map { "#\($0.name)" }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return selectedPages(bundle: bundle, selection: selection, timestamp: timestamp) { kind in
            let body = switch kind {
            case .note:
                markdownNotes(bundle, settings: settings, style: .obsidian)
            case .review:
                markdownReviews(bundle, settings: settings, style: .obsidian)
            case .related:
                markdownRelated(bundle, settings: settings, style: .obsidian)
            }
            return tags.isEmpty ? body : "\(body)\n\(tags)"
        }
    }
}

nonisolated extension DesktopWebRemoteExportGenerators {
    enum ContentKind {
        case note
        case review
        case related
    }

    enum MarkdownStyle {
        case siYuan
        case obsidian
    }

    /// 固定 Android 远端导出页面顺序：书评、相关、书摘。
    static func selectedPages(
        bundle: DesktopWebExportBundle,
        selection: DesktopWebExportContentSelection,
        timestamp: String,
        body: (ContentKind) -> String
    ) -> [DesktopWebRemoteExportPage] {
        var pages: [DesktopWebRemoteExportPage] = []
        if selection.review, !bundle.reviews.isEmpty {
            pages.append(.init(
                title: "\(bundle.book.name)_书评_\(timestamp)",
                body: body(.review)
            ))
        }
        if selection.relevant, !bundle.related.isEmpty {
            pages.append(.init(
                title: "\(bundle.book.name)_相关_\(timestamp)",
                body: body(.related)
            ))
        }
        if selection.note {
            pages.append(.init(
                title: "\(bundle.book.name)_书摘_\(timestamp)",
                body: body(.note)
            ))
        }
        return pages
    }

    /// 生成语雀书摘页，保留 `<img>…<img>` 的 Android 历史输出。
    static func yuQueNotes(
        _ bundle: DesktopWebExportBundle,
        _ settings: [String: Any]
    ) -> String {
        var page = yuQueBookInfo(bundle.book, noteCount: bundle.notes.count, settings: settings)
        page += "\n\n---\n"
        var lastPath: [String] = []
        for (index, note) in bundle.notes.enumerated() {
            page += chapterHeadings(note.chapter, lastPath: &lastPath, trailing: "\n\n")
            let content = clearHTML(note.content)
            if !content.isEmpty {
                page += content.replacingOccurrences(of: "\n", with: "<br>") + "\n\n"
            }
            if let idea = note.idea.map(clearHTML), !idea.isEmpty {
                page += "> \(idea.replacingOccurrences(of: "\n", with: "<br>"))\n\n"
            }
            if !note.images.isEmpty {
                page += note.images.map {
                    "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\"><img>"
                }.joined()
                page += "\n\n"
            }
            if settings.bool("includeTag", fallback: true), !note.tags.isEmpty {
                page += note.tags.map { "#\($0.name)" }.joined(separator: "  ") + "\n\n"
            }
            let info = noteInfo(note, settings: settings, requireIncludeTime: true)
            if !info.isEmpty {
                page += info + "\n\n"
            }
            if index != bundle.notes.count - 1 {
                page += "---\n"
            }
        }
        return page
    }

    /// 生成语雀书评页；Android 该生成器不会输出书评附图。
    static func yuQueReviews(
        _ bundle: DesktopWebExportBundle,
        _ settings: [String: Any]
    ) -> String {
        var page = yuQueBookInfo(bundle.book, settings: settings) + "\n\n---\n"
        for (index, review) in bundle.reviews.enumerated() {
            page += "### \(review.title)\n"
            page += clearHTML(review.content).replacingOccurrences(of: "\n", with: "<br>") + "\n\n"
            if settings.bool("includeDateTime", fallback: true) {
                page += dateText(review.createdTime) + "\n\n"
            }
            if index != bundle.reviews.count - 1 {
                page += "---\n"
            }
        }
        return page
    }

    /// 生成语雀相关页，按类别切换插入标题并保留关联书籍的独立日期条件。
    static func yuQueRelated(
        _ bundle: DesktopWebExportBundle,
        _ settings: [String: Any]
    ) -> String {
        var page = yuQueBookInfo(bundle.book, settings: settings) + "\n\n---\n"
        var lastCategory = ""
        for (index, value) in bundle.related.enumerated() {
            if value.categoryTitle != lastCategory {
                page += "### \(value.categoryTitle)\n"
                lastCategory = value.categoryTitle
            }
            if let book = value.contentBook {
                page += yuQueRelatedBookInfo(book) + "\n\n"
                if settings.bool("includeDateTime", fallback: true) {
                    page += dateText(value.createdTime) + "\n\n"
                }
            } else {
                if !value.title.isEmpty {
                    page += "#### \(value.title)\n"
                }
                if !value.content.isEmpty {
                    page += clearHTML(value.content).replacingOccurrences(of: "\n", with: "<br>") + "\n\n"
                }
                if !value.images.isEmpty {
                    page += value.images.map {
                        "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\"><img>"
                    }.joined()
                    page += "\n\n"
                }
                if settings.bool("includeDateTime", fallback: true) {
                    page += dateText(value.createdTime)
                }
            }
            if index != bundle.related.count - 1 {
                page += "---\n"
            }
        }
        return page
    }

    /// 生成语雀书籍头；字段即使为空也保留作者、出版社、出版年和 ISBN 行。
    static func yuQueBookInfo(
        _ book: DesktopWebBookSnapshot,
        noteCount: Int = 0,
        settings: [String: Any]
    ) -> String {
        var result = "<img src=\"\(book.cover)\" width=\"160\" style=\"margin:14px\"><img>\n\n"
        result += "《\(book.name)》\n"
        result += "作者：\(book.author)\n"
        if !book.translator.isEmpty {
            result += "译者：\(book.translator)\n"
        }
        result += "出版社：\(book.press)\n"
        result += "出版年：\(book.pubDate)\n"
        result += "ISBN：\(book.isbn)\n"
        if noteCount != 0 {
            result += "\(noteCount) 条书摘\n"
        }
        if settings.bool("includeBookInfo", fallback: true) {
            if !book.summary.isEmpty {
                result += "### 书籍简介\n\(book.summary)"
            }
            if !book.authorIntro.isEmpty {
                if !book.summary.isEmpty {
                    result += "\n"
                }
                result += "### 作者简介\n\(book.authorIntro)\n"
            }
        }
        return result
    }

    /// 生成语雀关联书籍头，其 Android 输入没有作者简介和书摘计数。
    static func yuQueRelatedBookInfo(_ book: DesktopWebRelatedBookSnapshot) -> String {
        var result = "<img src=\"\(book.cover)\" width=\"160\" style=\"margin:14px\"><img>\n\n"
        result += "《\(book.name)》\n"
        result += "作者：\(book.author)\n"
        if let translator = book.translator, !translator.isEmpty {
            result += "译者：\(translator)\n"
        }
        result += "出版社：\(book.press)\n"
        result += "出版年：\(book.publicationDate ?? "")\n"
        result += "ISBN：\n"
        return result
    }

    /// 生成思源或 Obsidian 书摘页；两者仅在块级 div 与换行处理上不同。
    static func markdownNotes(
        _ bundle: DesktopWebExportBundle,
        settings: [String: Any],
        style: MarkdownStyle
    ) -> String {
        var page = markdownBookInfo(bundle.book, style: style) + "\n"
        if !bundle.notes.isEmpty {
            let count = "<center><font color='#6e6e6e' size=2>\(bundle.notes.count) 条书摘</font></center>"
            page += style == .siYuan ? "<div>\(count)</div>" : count
        }
        page += "\n\n"
        let summary = markdownSummary(bundle.book, settings: settings)
        if !summary.isEmpty {
            page += summary + "\n\n"
        }
        page += "---\n\n"
        var lastPath: [String] = []
        for (index, note) in bundle.notes.enumerated() {
            page += chapterHeadings(note.chapter, lastPath: &lastPath, trailing: "\n\n")
            let content = clearHTML(note.content)
            if !content.isEmpty {
                page += style == .obsidian
                    ? content + "\n\n"
                    : content + "\n\n"
            }
            if let idea = note.idea.map(clearHTML), !idea.isEmpty {
                page += "> \(idea)\n\n"
            }
            if !note.images.isEmpty {
                let images = note.images.map {
                    "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\">"
                }.joined()
                page += style == .siYuan ? "<div>\(images)</div>\n\n" : images + "\n\n"
            }
            if settings.bool("includeTag", fallback: true), !note.tags.isEmpty {
                let tags = note.tags.map { "#\($0.name)" }.joined(separator: "  ")
                page += tags + "\n\n"
            }
            let info = noteInfo(note, settings: settings, requireIncludeTime: false)
            if !info.isEmpty {
                let value = "<font color='#6e6e6e' size=2> \(info) </font>"
                page += style == .siYuan ? "<div>\(value)</div>\n\n" : value + "\n\n"
            }
            if index != bundle.notes.count - 1 {
                page += "---\n\n"
            }
        }
        return page
    }

    /// 生成思源或 Obsidian 书评页；Android 两个生成器均无条件输出书评日期。
    static func markdownReviews(
        _ bundle: DesktopWebExportBundle,
        settings: [String: Any],
        style: MarkdownStyle
    ) -> String {
        var page = markdownBookInfo(bundle.book, style: style) + "\n\n"
        let summary = markdownSummary(bundle.book, settings: settings)
        if !summary.isEmpty {
            page += summary + "\n\n"
        }
        page += "---\n\n"
        for (index, review) in bundle.reviews.enumerated() {
            if !review.title.isEmpty {
                page += "### \(review.title)\n\n"
            }
            let content = clearHTML(review.content)
            if !content.isEmpty {
                page += content + "\n\n"
            }
            if !review.images.isEmpty {
                let images = review.images.map {
                    "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\">"
                }.joined()
                page += style == .siYuan ? "<div>\(images)</div>\n\n" : images + "\n\n"
            }
            let date = "<font color='#6e6e6e' size=2>\(dateText(review.createdTime))</font>"
            page += style == .siYuan ? "<div>\(date)</div>\n\n" : date + "\n\n"
            if index != bundle.reviews.count - 1 {
                page += "---\n\n"
            }
        }
        return page
    }

    /// 生成思源或 Obsidian 相关页；关联书籍日期沿用 Android 无条件输出行为。
    static func markdownRelated(
        _ bundle: DesktopWebExportBundle,
        settings: [String: Any],
        style: MarkdownStyle
    ) -> String {
        var page = markdownBookInfo(bundle.book, style: style) + "\n\n"
        let summary = markdownSummary(bundle.book, settings: settings)
        if !summary.isEmpty {
            page += summary + "\n\n"
        }
        page += "---\n\n"
        var lastCategory = ""
        for (index, value) in bundle.related.enumerated() {
            if value.categoryTitle != lastCategory {
                page += "### \(value.categoryTitle)\n\n\n"
                lastCategory = value.categoryTitle
            }
            if let book = value.contentBook {
                page += markdownRelatedBookInfo(book, style: style) + "\n\n"
                let date = "<font color='#6e6e6e' size=2>\(dateText(value.createdTime))</font>"
                page += style == .siYuan ? "<div>\(date)</div>\n\n" : date + "\n\n"
            } else {
                page += "#### \(value.title)\n\n"
                let content = clearHTML(value.content)
                if !content.isEmpty {
                    page += content + "\n\n"
                }
                if !value.images.isEmpty {
                    let images = value.images.map {
                        "<img src=\"\($0.url)\" width=\"160\" style=\"margin:14px\">"
                    }.joined()
                    page += style == .siYuan ? "<div>\(images)</div>\n\n" : images + "\n\n"
                }
                if settings.bool("includeDateTime", fallback: true) {
                    let date = "<font color='#6e6e6e' size=2>\(dateText(value.createdTime))</font>"
                    page += style == .siYuan ? "<div>\(date)</div>\n\n" : date + "\n\n"
                }
            }
            if index != bundle.related.count - 1 {
                page += "---\n\n"
            }
        }
        return page
    }

    /// 生成普通 Markdown 或思源 div 版本的书籍信息。
    static func markdownBookInfo(
        _ book: DesktopWebBookSnapshot,
        style: MarkdownStyle
    ) -> String {
        let author = book.author.isEmpty ? "" : "作者：\(book.author)"
        let translator = book.translator.isEmpty ? "" : "译者：\(book.translator)"
        let press = book.press.isEmpty ? "" : "出版社：\(book.press)"
        let pubDate = book.pubDate.isEmpty ? "" : "出版年：\(book.pubDate)"
        let isbn = book.isbn.isEmpty ? "" : "ISBN：\(book.isbn)"
        let value = """
        <center><img src="\(book.cover)" width="135px" height="200px"> </center>
        <center><font size=4>《\(book.name)》</font></center>
        <center><font color='#6e6e6e' size=2>\(author)</font></center>
        <center><font color='#6e6e6e' size=2>\(translator)</font></center>
        <center><font color='#6e6e6e' size=2>\(press)</font></center>
        <center><font color='#6e6e6e' size=2>\(pubDate)</font></center>
        <center><font color='#6e6e6e' size=2>\(isbn)</font></center>
        """
        return style == .siYuan ? "<div>\n\(value)\n</div>" : value
    }

    /// 生成关联书籍的普通 Markdown 信息。
    static func markdownRelatedBookInfo(
        _ book: DesktopWebRelatedBookSnapshot,
        style: MarkdownStyle
    ) -> String {
        let value = """
        <center><img src="\(book.cover)" width="135px" height="200px"> </center>
        <center><font size=4>《\(book.name)》</font></center>
        <center><font color='#6e6e6e' size=2>\(book.author.isEmpty ? "" : "作者：\(book.author)")</font></center>
        <center><font color='#6e6e6e' size=2>\((book.translator ?? "").isEmpty ? "" : "译者：\(book.translator!)")</font></center>
        <center><font color='#6e6e6e' size=2>\(book.press.isEmpty ? "" : "出版社：\(book.press)")</font></center>
        <center><font color='#6e6e6e' size=2>\((book.publicationDate ?? "").isEmpty ? "" : "出版年：\(book.publicationDate!)")</font></center>
        <center><font color='#6e6e6e' size=2></font></center>
        """
        return style == .siYuan ? "<div>\n\(value)\n</div>" : value
    }

    /// 生成普通 Markdown 的书籍简介；作者简介输出条件保留 Android 的 author 判断。
    static func markdownSummary(
        _ book: DesktopWebBookSnapshot,
        settings: [String: Any]
    ) -> String {
        guard settings.bool("includeBookInfo", fallback: true) else {
            return ""
        }
        var result = ""
        if !book.summary.isEmpty {
            result += "### 书籍简介\n\n\(book.summary)"
        }
        if !book.author.isEmpty {
            if !book.summary.isEmpty {
                result += "\n"
            }
            result += "### 作者简介\n\n\(book.authorIntro)"
        }
        return result
    }

    /// 只补充章节路径的变化部分，复刻 Android MarkdownChapterHeadingRenderer。
    static func chapterHeadings(
        _ chapter: DesktopWebChapterSnapshot?,
        lastPath: inout [String],
        trailing: String
    ) -> String {
        guard let chapter else {
            return ""
        }
        let source = chapter.pathTitles.isEmpty ? [chapter.title] : chapter.pathTitles
        let path = source.compactMap { value -> String? in
            let normalized = value.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }.prefix(5).map { $0 }
        guard !path.isEmpty else {
            return ""
        }
        var common = 0
        while common < min(lastPath.count, path.count), lastPath[common] == path[common] {
            common += 1
        }
        lastPath = path
        guard common < path.count else {
            return ""
        }
        let value = path.dropFirst(common).enumerated().map { offset, title in
            "\(String(repeating: "#", count: common + offset + 2)) \(title)"
        }.joined(separator: "\n")
        return value + trailing
    }

    /// 生成书摘页码/位置与时间信息；不同 Android 生成器对 isIncludeTime 的判断并不一致。
    static func noteInfo(
        _ note: DesktopWebBookNoteSnapshot,
        settings: [String: Any],
        requireIncludeTime: Bool
    ) -> String {
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
           (!requireIncludeTime || note.isIncludeTime) {
            items.append(dateText(note.createdTime))
        }
        return items.joined(separator: " | ")
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
