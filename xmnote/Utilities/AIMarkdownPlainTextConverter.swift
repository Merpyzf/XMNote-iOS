/**
 * [INPUT]: 依赖 SwiftStreamingMarkdown 的公开纯文本转换能力，接收 AI 返回的 Markdown 源文本
 * [OUTPUT]: 对外提供 AIMarkdownPlainTextConverter，生成复制、导出与想法编辑器交接统一使用的语义纯文本
 * [POS]: Utilities 的 AI 文本归一化工具，隔离展示 Markdown 与可编辑纯文本的格式边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftStreamingMarkdown

/// 将 AI Markdown 转换为可读纯文本，统一复制、导出和想法编辑草稿的可见内容口径。
nonisolated enum AIMarkdownPlainTextConverter {
    /// 异步解析完整 Markdown 快照；调用任务取消时停止后续归一化，避免迟到结果继续触发复制或编辑器交接。
    static func plainText(from markdown: String) async throws -> String {
        try Task.checkCancellation()
        let normalizedSource = normalizedLineEndings(markdown)
        let sourceWithoutThematicBreaks = removingThematicBreaksOutsideCodeFences(normalizedSource)
        let converted = await sourceWithoutThematicBreaks.markdownToPlainText()
        try Task.checkCancellation()
        return normalizedPlainText(converted)
    }

    /// 统一外部模型可能返回的 CRLF/CR，保证后续围栏扫描和最终编辑文本只使用 LF。
    private static func normalizedLineEndings(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// 仅移除代码围栏外的 Markdown 水平分隔线，代码正文中的相同字符保持原样。
    private static func removingThematicBreaksOutsideCodeFences(_ markdown: String) -> String {
        var activeFence: Fence?
        var output: [String] = []

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let fence = activeFence {
                output.append(line)
                if isClosingFence(line, matching: fence) {
                    activeFence = nil
                }
                continue
            }

            if let fence = openingFence(in: line) {
                activeFence = fence
                output.append(line)
                continue
            }

            output.append(isThematicBreak(line) ? "" : line)
        }

        return output.joined(separator: "\n")
    }

    /// 清理库表格转换产生的行尾制表符，仅裁剪整份结果首尾空白，不改变代码缩进或内部空行。
    private static func normalizedPlainText(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                var normalized = String(line)
                while normalized.last == "\t" {
                    normalized.removeLast()
                }
                return normalized
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 识别 CommonMark 允许的反引号或波浪线围栏起始行，并记录关闭围栏需要的字符与长度。
    private static func openingFence(in line: String) -> Fence? {
        let characters = Array(line)
        guard let start = contentStartIndex(in: characters), start < characters.count else { return nil }
        let marker = characters[start]
        guard marker == "`" || marker == "~" else { return nil }

        let count = markerRunLength(in: characters, from: start, marker: marker)
        guard count >= 3 else { return nil }
        if marker == "`", characters.dropFirst(start + count).contains("`") {
            return nil
        }
        return Fence(marker: marker, minimumClosingLength: count)
    }

    /// 判断当前行是否为匹配中的关闭围栏；关闭标记后只允许空格或制表符。
    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let characters = Array(line)
        guard let start = contentStartIndex(in: characters), start < characters.count else { return false }
        guard characters[start] == fence.marker else { return false }

        let count = markerRunLength(in: characters, from: start, marker: fence.marker)
        guard count >= fence.minimumClosingLength else { return false }
        return characters.dropFirst(start + count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 识别由同一种 `*`、`-` 或 `_` 构成且数量不少于三个的水平分隔线。
    private static func isThematicBreak(_ line: String) -> Bool {
        let characters = Array(line)
        guard let start = contentStartIndex(in: characters), start < characters.count else { return false }
        let marker = characters[start]
        guard marker == "*" || marker == "-" || marker == "_" else { return false }

        let meaningful = characters.dropFirst(start).filter { $0 != " " && $0 != "\t" }
        return meaningful.count >= 3 && meaningful.allSatisfy { $0 == marker }
    }

    /// 返回最多三个前导空格后的内容起点；四个及以上空格属于缩进代码而不是围栏或分隔线。
    private static func contentStartIndex(in characters: [Character]) -> Int? {
        var index = 0
        while index < characters.count, characters[index] == " " {
            index += 1
            if index > 3 { return nil }
        }
        return index
    }

    /// 计算指定位置开始的连续标记长度，供围栏开闭匹配复用。
    private static func markerRunLength(
        in characters: [Character],
        from start: Int,
        marker: Character
    ) -> Int {
        var index = start
        while index < characters.count, characters[index] == marker {
            index += 1
        }
        return index - start
    }
}

private extension AIMarkdownPlainTextConverter {
    /// 单个代码围栏会话，关闭行必须使用相同字符且长度不短于起始围栏。
    struct Fence {
        let marker: Character
        let minimumClosingLength: Int
    }
}
