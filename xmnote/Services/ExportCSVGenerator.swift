/**
 * [INPUT]: 依赖 ExportSnapshot、ExportBookFieldSelection 与固定 Locale/TimeZone，接收 Android 对齐的书籍信息快照
 * [OUTPUT]: 对外提供 UTF-8 CSV 字节，保持字段顺序、启用状态、五个派生字段排除和逐行换行规则
 * [POS]: Services 层书籍信息本地生成器；不访问数据库、UserDefaults、Keychain 或界面状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 纯函数式 CSV 生成器；固定输入快照可直接用于 Android Oracle 字节比较。
nonisolated enum ExportCSVGenerator {
    /// 生成 Android CSVGenerator 等价的 UTF-8 内容，表头和每本书行末均保留 `\n`。
    static func generate(
        snapshot: ExportSnapshot,
        fields: [ExportBookFieldSelection],
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> Data {
        let enabledFields = fields.compactMap { selection in
            selection.isEnabled && selection.field.isCSVOutputField ? selection.field : nil
        }
        var output = enabledFields.map(\.title).joined(separator: ",") + "\n"
        for value in snapshot.books {
            output += enabledFields.map {
                csvValue(
                    $0,
                    book: value.book,
                    localeIdentifier: localeIdentifier,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            }.joined(separator: ",")
            output += "\n"
        }
        return Data(output.utf8)
    }

    /// 映射 Android BookExportFieldRegistry.csvValue 的字段级空值、引号与格式化语义。
    private static func csvValue(
        _ field: ExportBookField,
        book: DesktopWebBookSnapshot,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> String {
        switch field {
        case .cover: quoted(book.cover)
        case .name: quoted(book.name)
        case .author: quoted(book.author)
        case .translator: quoted(book.translator)
        case .press: quoted(book.press)
        case .publishDate: quoted(book.pubDate)
        case .isbn: quoted(book.isbn)
        case .source: quoted(book.sourceName)
        case .purchaseDate:
            date(book.purchaseDate ?? 0, format: "yyyy-MM-dd", localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .price:
            book.price.map(decimalPrice) ?? ""
        case .readStatus:
            quoted(["想读", "在读", "读完", "弃读", "搁置"].element(at: book.readStatus - 1) ?? "")
        case .readScore:
            book.score == 0 ? "" : String(describing: Float(book.score) / 10)
        case .readScoreDisplay:
            quoted(ratingDisplay(book.score))
        case .readTag:
            quoted(book.tags.map { "#\($0.name)" }.joined(separator: " "))
        case .group:
            quoted(book.groups.map(\.name).joined(separator: "；"))
        case .douban:
            book.doubanId.map { "https://book.douban.com/subject/\($0)/" } ?? ""
        case .bookType:
            quoted(["纸质书", "电子书"].element(at: book.type) ?? "")
        case .readStatusChangedDate:
            date(book.readStatusChangedTime, format: "yyyy-MM-dd", localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .readingProgress:
            readingProgress(book)
        case .lastReadingDate:
            date(book.recentReadTime ?? 0, format: "yyyy-MM-dd HH:mm:ss", localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .totalPagination:
            book.totalPagination > 0 ? String(book.totalPagination) : ""
        case .wordCount:
            (book.wordCount ?? 0) > 0 ? String(book.wordCount!) : ""
        case .totalReadingTime:
            book.totalReadingTime > 0 ? String(Double(book.totalReadingTime) / 60) : ""
        case .readDoneCount:
            book.readDoneCount > 0 ? String(book.readDoneCount) : ""
        case .noteCount:
            String(book.noteCount)
        case .reviewCount:
            String(book.reviewCount)
        case .relevantCount:
            String(book.relevantCount)
        case .createdDate:
            date(book.createdTime, format: "yyyy-MM-dd", localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        case .updatedDate:
            date(max(book.updatedTime, book.lastModifiedTime ?? 0), format: "yyyy-MM-dd", localeIdentifier: localeIdentifier, timeZoneIdentifier: timeZoneIdentifier)
        }
    }

    /// Android `wrapAsCsvValue` 对所有字符串一律加双引号，并把内部引号加倍。
    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// 以请求冻结的区域和时区格式化 epoch 毫秒；非正时间保持空字段。
    private static func date(
        _ milliseconds: Int64,
        format: String,
        localeIdentifier: String,
        timeZoneIdentifier: String
    ) -> String {
        guard milliseconds > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.dateFormat = format
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }

    /// 复刻 BigDecimal HALF_UP、最多两位且去尾零的价格输出。
    private static func decimalPrice(_ value: Double) -> String {
        guard value > 0, value.isFinite else { return "" }
        let number = NSDecimalNumber(value: value).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 2,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            )
        )
        return number.stringValue
    }

    /// 按当前进度单位计算百分比、四舍五入到一位，再以 Kotlin Float.toString 语义输出。
    private static func readingProgress(_ book: DesktopWebBookSnapshot) -> String {
        let raw: Double
        switch book.currentPositionUnit {
        case 1:
            guard book.totalPosition != 0 else { return "" }
            raw = book.readPosition / Double(book.totalPosition) * 100
        case 2:
            guard book.totalPagination != 0 else { return "" }
            raw = book.readPosition / Double(book.totalPagination) * 100
        default:
            raw = book.readPosition
        }
        let rounded = (raw * 10).rounded() / 10
        guard rounded != 0 else { return "" }
        return String(describing: Float(min(100, max(0, rounded))))
    }

    /// 保留 Notion 使用的评分展示计算，即使 CSV 当前明确排除该列。
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
    /// 安全读取固定产品枚举名称，异常数据库值按 Android 导出空值边界处理。
    nonisolated func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
