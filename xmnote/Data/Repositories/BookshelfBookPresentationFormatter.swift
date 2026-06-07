import Foundation

/**
 * [INPUT]: 依赖书籍原始日期、进度、阅读状态与读完次数等展示派生字段
 * [OUTPUT]: 对外提供 BookshelfBookPresentationFormatter（发布日期、进度文案、书签文案与阅读状态徽标）
 * [POS]: Data 层书架展示字段格式化协作者，隔离无数据库副作用的列表展示派生逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书架书籍展示字段格式化助手，统一列表与分组预览的派生文案。
nonisolated enum BookshelfBookPresentationFormatter {
    static func resolvedReadDoneDate(
        readStatusID: Int64,
        statusChangedDate: Int64,
        latestReadDoneDate: Int64
    ) -> Int64 {
        if latestReadDoneDate > 0 {
            return latestReadDoneDate
        }
        guard readStatusID == BookEntryReadingStatus.finished.rawValue else {
            return 0
        }
        return statusChangedDate
    }

    static func normalizedPubDateText(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: trimmed) {
            let output = DateFormatter()
            output.dateFormat = "yyyy-MM"
            output.locale = Locale(identifier: "en_US_POSIX")
            return output.string(from: date)
        }
        return trimmed
    }

    static func bookmarkText(readPosition: Double, currentPositionUnit: Int64) -> String {
        guard currentPositionUnit != 0 else { return "" }
        guard Int(readPosition * 100) != 0 else { return "" }
        return "\(Int(readPosition.rounded())) 页"
    }

    static func readingProgressText(from progress: Double?) -> String {
        guard let progress else { return "" }
        let rounded = (progress * 10).rounded() / 10
        guard rounded != 0 else { return "" }
        if rounded == 100 {
            return "100%"
        }
        return String(format: "%.1f%%", rounded)
    }

    static func readStatusBadgeTitle(
        readStatusID: Int64,
        readStatusName: String,
        readDoneCount: Int64
    ) -> String {
        if readStatusID == BookEntryReadingStatus.finished.rawValue, readDoneCount > 1 {
            return "\(readDoneCount) 刷"
        }
        if readStatusID == BookEntryReadingStatus.reading.rawValue, readDoneCount >= 1 {
            return "\(readDoneCount + 1) 刷中"
        }
        if let status = BookEntryReadingStatus(rawValue: readStatusID) {
            let title = readStatusName.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? fallbackReadStatusTitle(for: status) : title
        }
        return readStatusName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func publishTimestamp(from pubDate: String) -> Int64 {
        let trimmed = pubDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let pattern = #"(\d{4})(?:[-/.年 ]+(\d{1,2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let yearRange = Range(match.range(at: 1), in: trimmed),
              let year = Int(trimmed[yearRange]) else {
            return 0
        }
        var month = 1
        if match.numberOfRanges > 2,
           let monthRange = Range(match.range(at: 2), in: trimmed),
           let parsedMonth = Int(trimmed[monthRange]) {
            month = max(1, min(parsedMonth, 12))
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = 1
        return components.date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }

    static func readingProgress(
        readPosition: Double,
        totalPosition: Int64,
        totalPagination: Int64
    ) -> Double? {
        readingProgress(
            readPosition: readPosition,
            currentPositionUnit: totalPosition > 0 ? 1 : 2,
            totalPosition: totalPosition,
            totalPagination: totalPagination
        )
    }

    static func readingProgress(
        readPosition: Double,
        currentPositionUnit: Int64,
        totalPosition: Int64,
        totalPagination: Int64
    ) -> Double? {
        if currentPositionUnit == 0 {
            return readPosition > 0 ? readPosition : nil
        }
        let denominator: Double
        if currentPositionUnit == 1, totalPosition > 0 {
            denominator = Double(totalPosition)
        } else if currentPositionUnit == 2, totalPagination > 0 {
            denominator = Double(totalPagination)
        } else if totalPosition > 0 {
            denominator = Double(totalPosition)
        } else if totalPagination > 0 {
            denominator = Double(totalPagination)
        } else {
            return nil
        }
        let progress = readPosition / denominator * 100
        return progress > 0 ? progress : nil
    }

    private static func fallbackReadStatusTitle(for status: BookEntryReadingStatus) -> String {
        switch status {
        case .wantRead:
            return "想读"
        case .reading:
            return "在读"
        case .finished:
            return "读完"
        case .abandoned:
            return "弃读"
        case .onHold:
            return "搁置"
        }
    }
}
