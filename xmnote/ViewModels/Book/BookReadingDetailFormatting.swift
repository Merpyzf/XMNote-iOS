/**
 * [INPUT]: 依赖 Foundation 的 Calendar、Date 与本地化日期格式能力
 * [OUTPUT]: 对外提供 BookReadingDetailFormatting，统一阅读详情日期、时长、月份与日标签文案
 * [POS]: ViewModels/Book 纯展示格式层，复刻 Android 阅读详情格式口径并供页面与测试共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 阅读详情的数字与单位片段，让 SwiftUI 可以分别应用 iOS 设计令牌而不改变 Android 文案口径。
nonisolated struct BookReadingDetailDurationPart: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case number
        case unit
    }

    let text: String
    let role: Role
}

/// 阅读详情展示格式的单一 owner；所有函数均为纯计算，不持有跨线程共享格式器。
nonisolated enum BookReadingDetailFormatting {
    /// 复刻 Android `smartFormat(zh=true, showTime=false)` 的相对日与年份省略规则。
    static func smartDate(
        _ date: Date,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let targetDay = calendar.startOfDay(for: date)
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let dayDifference = calendar.dateComponents([.day], from: targetDay, to: referenceDay).day
        switch dayDifference {
        case 0:
            return "今天"
        case 1:
            return "昨天"
        case 2:
            return "前天"
        default:
            let includesYear = calendar.component(.year, from: targetDay)
                != calendar.component(.year, from: referenceDay)
            return formattedDate(targetDay, includesYear: includesYear, calendar: calendar)
        }
    }

    /// 按 Android 规则仅显示小时/分钟或分钟/秒中的有效高位单位。
    static func compactDurationParts(_ seconds: Int64) -> [BookReadingDetailDurationPart] {
        let normalizedSeconds = max(0, seconds)
        let hours = normalizedSeconds / 3_600
        let minutes = normalizedSeconds % 3_600 / 60
        if hours > 0 {
            var parts = pair(number: hours, unit: "小时")
            if minutes > 0 {
                parts.append(contentsOf: pair(number: minutes, unit: "分钟"))
            }
            return parts
        }
        if minutes > 0 {
            return pair(number: minutes, unit: "分钟")
        }
        return pair(number: normalizedSeconds, unit: "秒")
    }

    /// 生成 Android 月度条文案：当年省略年份，时长复用相同紧凑规则。
    static func monthSummary(
        year: Int,
        month: Int,
        seconds: Int64,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let currentYear = calendar.component(.year, from: referenceDate)
        let monthText = year == currentYear ? "\(month)月" : "\(year)年\(month)月"
        return "\(monthText) · \(compactDurationText(seconds))"
    }

    /// 生成 Android 月度展开列表使用的自然日标签。
    static func dayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        "\(calendar.component(.day, from: date))日"
    }
}

private extension BookReadingDetailFormatting {
    /// 创建数字/单位成对片段，避免页面层重复拆分时长。
    nonisolated static func pair(number: Int64, unit: String) -> [BookReadingDetailDurationPart] {
        [
            BookReadingDetailDurationPart(text: String(number), role: .number),
            BookReadingDetailDurationPart(text: unit, role: .unit)
        ]
    }

    /// 将结构化时长拼成 Android 无空格文案，供月度统计复用。
    nonisolated static func compactDurationText(_ seconds: Int64) -> String {
        compactDurationParts(seconds).map(\.text).joined()
    }

    /// 使用调用方日历与时区格式化日期；每次创建格式器以避免跨线程共享可变状态。
    nonisolated static func formattedDate(
        _ date: Date,
        includesYear: Bool,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = includesYear ? "yyyy年M月d日" : "M月d日"
        return formatter.string(from: date)
    }
}
