/**
 * [INPUT]: 依赖 Foundation 与 NoteImportModels，接收 UTF-8 文件字节和 Android 同源文本规则
 * [OUTPUT]: 对内部 Parser 提供不改写正文的行处理、正则捕获与 Android 兼容日期解析
 * [POS]: Data/Import/Parsers 的纯文本解析基础设施，不持有数据库、网络或 UI 状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated enum NoteImportTextSupport {
    static func decodeUTF8(_ data: Data) throws -> String {
        // Kotlin `String(bytes, UTF_8)` 会用 U+FFFD 替换损坏的尾部字节，而不是让整份导入失败。
        // `String(decoding:as:)` 复刻同一容错语义；同时确保 UTF-8 BOM 像 Android 一样留在文本中。
        let content = String(decoding: data, as: UTF8.self)
        guard data.starts(with: [0xEF, 0xBB, 0xBF]), !content.hasPrefix("\u{FEFF}") else {
            return content
        }
        return "\u{FEFF}\(content)"
    }

    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstCapture(
        pattern: String,
        in value: String,
        group: Int = 1,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let fullRange = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: fullRange),
              group <= match.numberOfRanges - 1,
              let range = Range(match.range(at: group), in: value)
        else { return nil }
        return String(value[range])
    }

    static func contains(pattern: String, in value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    static func androidDateMilliseconds(_ value: String) -> Int64 {
        dateMilliseconds(value, format: "yyyy-MM-dd HH:mm")
    }

    static func dateMilliseconds(_ value: String, format: String) -> Int64 {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = format
        formatter.isLenient = true
        guard let date = formatter.date(from: value) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }
}
