/**
 * [INPUT]: 依赖 DesktopWebBookSnapshot、29 项书籍字段快照及固定 Locale/TimeZone
 * [OUTPUT]: 对外提供与 Android BookExportFieldRegistry 等价的 Notion Page properties 与可选封面
 * [POS]: Services 层书籍信息 Notion 纯生成器；不访问数据库、网络、设置存储或凭据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书籍信息 Notion 生成器保持用户字段顺序与开关，并强制提供数据库所需的唯一标题属性。
nonisolated enum ExportNotionBookGenerator {
    /// 生成 `POST /v1/pages` 的页面主体；parent 由远端 Service 在冻结目标后补入。
    static func pageBody(
        book: DesktopWebBookSnapshot,
        fields: [ExportBookFieldSelection],
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [String: Any] {
        var enabled = fields.filter(\.isEnabled)
        if !enabled.contains(where: { $0.field == .name }) {
            enabled.insert(.init(field: .name, isEnabled: true), at: 0)
        }
        var properties: [String: Any] = [:]
        for selection in enabled where selection.field != .cover {
            properties[selection.field.title] = value(
                selection.field,
                book: book,
                localeIdentifier: localeIdentifier,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
        var result: [String: Any] = ["properties": properties]
        if enabled.contains(where: { $0.field == .cover }), !book.cover.isEmpty {
            result["cover"] = [
                "type": "external",
                "external": ["url": book.cover]
            ]
        }
        return result
    }

    /// 为持续同步页面补齐 Android 书库协议的技术属性；这些字段不受用户 29 项显示开关影响。
    static func applyingSyncState(
        to source: [String: Any],
        syncID: String,
        metadataFingerprint: String,
        contentFingerprint: String,
        firstSyncMilliseconds: Int64,
        lastSyncMilliseconds: Int64,
        conflictCount: Int,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [String: Any] {
        var result = source
        var properties = result["properties"] as? [String: Any] ?? [:]
        properties["XMNote 同步 ID"] = richText(syncID)
        properties["XMNote 元数据指纹"] = richText(metadataFingerprint)
        properties["XMNote 内容指纹"] = richText(contentFingerprint)
        properties["首次同步时间"] = date(
            firstSyncMilliseconds,
            includesTime: true,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        properties["最近同步时间"] = date(
            lastSyncMilliseconds,
            includesTime: true,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        properties["同步状态"] = select("已同步")
        properties["冲突数"] = number(Double(conflictCount))
        result["properties"] = properties
        return result
    }

    /// 映射 Android `notionValue` 的空值、数值、日期和选项清洗语义。
    private static func value(
        _ field: ExportBookField,
        book: DesktopWebBookSnapshot,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [String: Any] {
        switch field {
        case .name:
            return title(book.name)
        case .author:
            return richText(book.author)
        case .translator:
            return richText(book.translator)
        case .press:
            return richText(book.press)
        case .publishDate:
            return richText(book.pubDate)
        case .isbn:
            return richText(book.isbn)
        case .readScoreDisplay:
            return richText(ratingDisplay(book.score))
        case .source:
            return select(book.sourceName)
        case .readStatus:
            return select(["想读", "在读", "读完", "弃读", "搁置"].element(at: book.readStatus - 1) ?? "")
        case .bookType:
            return select(["纸质书", "电子书"].element(at: book.type) ?? "")
        case .readTag:
            return multiSelect(book.tags.map { "#\($0.name)" })
        case .group:
            return multiSelect(book.groups.map(\.name))
        case .purchaseDate:
            return date(book.purchaseDate ?? 0, includesTime: false, localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .readStatusChangedDate:
            return date(book.readStatusChangedTime, includesTime: false, localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .lastReadingDate:
            return date(book.recentReadTime ?? 0, includesTime: true, localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .createdDate:
            return date(book.createdTime, includesTime: false, localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .updatedDate:
            return date(max(book.updatedTime, book.lastModifiedTime ?? 0), includesTime: false, localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .price:
            return number(book.price.flatMap { $0 > 0 ? $0 : nil })
        case .readScore:
            return number(book.score > 0 ? Double(book.score) / 10 : nil)
        case .readingProgress:
            return number(readingProgress(book))
        case .totalPagination:
            return number(book.totalPagination > 0 ? Double(book.totalPagination) : nil)
        case .wordCount:
            return number((book.wordCount ?? 0) > 0 ? Double(book.wordCount!) : nil)
        case .totalReadingTime:
            return number(book.totalReadingTime > 0 ? Double(book.totalReadingTime / 60) : nil)
        case .readDoneCount:
            return number(book.readDoneCount > 0 ? Double(book.readDoneCount) : nil)
        case .noteCount:
            return number(Double(book.noteCount))
        case .reviewCount:
            return number(Double(book.reviewCount))
        case .relevantCount:
            return number(Double(book.relevantCount))
        case .douban:
            return ["url": book.doubanId.flatMap { $0 > 0 ? "https://book.douban.com/subject/\($0)/" : nil } ?? NSNull()]
        case .cover:
            return [:]
        }
    }

    private static func title(_ value: String) -> [String: Any] {
        ["title": [["type": "text", "text": ["content": value]]]]
    }

    private static func richText(_ value: String) -> [String: Any] {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["rich_text": []]
        }
        return ["rich_text": [["type": "text", "text": ["content": value]]]]
    }

    private static func select(_ value: String) -> [String: Any] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "，")
        return ["select": normalized.isEmpty ? NSNull() : ["name": normalized]]
    }

    private static func multiSelect(_ values: [String]) -> [String: Any] {
        var seen = Set<String>()
        let options: [[String: String]] = values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "，")
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return ["name": normalized]
        }
        return ["multi_select": options]
    }

    private static func number(_ value: Double?) -> [String: Any] {
        ["number": value ?? NSNull()]
    }

    /// Notion 日期使用冻结时区；仅“最后阅读”保留 Android 的时分秒与时区偏移。
    private static func date(
        _ milliseconds: Int64,
        includesTime: Bool,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> [String: Any] {
        guard milliseconds > 0 else { return ["date": NSNull()] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = includesTime ? "yyyy-MM-dd'T'HH:mm:ss.SSSXXX" : "yyyy-MM-dd"
        return ["date": ["start": formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))]]
    }

    private static func readingProgress(_ book: DesktopWebBookSnapshot) -> Double? {
        let value: Double
        switch book.currentPositionUnit {
        case 1:
            guard book.totalPosition != 0 else { return nil }
            value = book.readPosition / Double(book.totalPosition) * 100
        case 2:
            guard book.totalPagination != 0 else { return nil }
            value = book.readPosition / Double(book.totalPagination) * 100
        default:
            value = book.readPosition
        }
        return min(100, max(0, (value * 10).rounded() / 10))
    }

    private static func ratingDisplay(_ score: Int) -> String {
        guard score > 0 else { return "" }
        let halfSteps = min(10, max(0, Int((Double(score) / 10 * 2).rounded())))
        let full = halfSteps / 2
        let half = halfSteps % 2 == 1
        let empty = 5 - full - (half ? 1 : 0)
        return String(repeating: "★", count: full)
            + (half ? "½" : "")
            + String(repeating: "☆", count: empty)
    }
}

private extension Array {
    nonisolated func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
