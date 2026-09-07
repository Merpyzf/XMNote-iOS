/**
 * [INPUT]: 依赖 Foundation 字符与 UTF-16 编码，接收候选标题、扩展名和任务内已用名称集合
 * [OUTPUT]: 对外提供 Android 对齐的非法字符替换、65 UTF-16 单元截断、空名回退与 _1..._9999 冲突分配
 * [POS]: Utilities 的导出文件命名规则唯一实现，被本地书摘、PDF、CSV 和 ZIP 共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 同一导出任务内的确定性文件名分配器。
nonisolated struct ExportFileNameAllocator {
    enum AllocationError: LocalizedError {
        case exhausted(String)

        var errorDescription: String? {
            switch self {
            case let .exhausted(name): "文件名冲突过多：\(name)"
            }
        }
    }

    private var usedNames = Set<String>()

    /// 返回包含扩展名的唯一文件名；大小写折叠用于兼容 iOS 默认不区分大小写的文件系统。
    mutating func allocate(title: String, extension fileExtension: String) throws -> String {
        let stem = Self.sanitizedStem(title)
        let normalizedExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        for suffix in 0...9_999 {
            let candidateStem = suffix == 0 ? stem : "\(stem)_\(suffix)"
            let candidate = normalizedExtension.isEmpty
                ? candidateStem
                : "\(candidateStem).\(normalizedExtension)"
            if usedNames.insert(candidate.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted {
                return candidate
            }
        }
        throw AllocationError.exhausted(stem)
    }

    /// 复刻 Android 文件名规则：九类非法字符替换为下划线、trim、空名回退、UTF-16 截断到 65。
    static func sanitizedStem(_ value: String) -> String {
        let illegal = try? NSRegularExpression(pattern: "[:\\\\/*\\\"?|<>'']")
        let range = NSRange(value.startIndex..., in: value)
        let escaped = illegal?.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "_"
        ) ?? value
        let trimmed = escaped.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "读书笔记" : trimmed
        return String(decoding: Array(source.utf16.prefix(65)), as: UTF16.self)
    }
}
