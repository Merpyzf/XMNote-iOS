/**
 * [INPUT]: 依赖 Foundation 的 URL 与正则表达能力，从系统分享文本、URL 或深链参数中提取微信读书书单链接
 * [OUTPUT]: 对外提供 WereadCollectionLinkExtractor，供主 App 与 Share Extension 复用同一套微信读书书单链接识别规则
 * [POS]: Infra/ShareImport 的轻量分享导入基础设施，不访问数据库与网络，仅负责跨进程输入的业务链接归一化
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 识别微信读书书单分享内容中的可导入 URL，覆盖 Android 两行分享文本与 iOS 系统 URL 分享。
nonisolated struct WereadCollectionLinkExtractor {
    /// 从任意分享文本中扫描首个 `weread.qq.com` HTTP(S) 链接；未命中时返回 nil。
    static func extractLink(from text: String) -> String? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return nil }

        for candidate in candidates(from: normalizedText) {
            if let link = normalizedWereadLink(from: candidate) {
                return link
            }
        }
        return nil
    }

    /// 判断 URL 是否为可导入微信读书链接，并返回原始绝对地址。
    static func extractLink(from url: URL) -> String? {
        normalizedWereadLink(from: url.absoluteString)
    }

    /// 判断 URL 是否属于微信读书 HTTP(S) 域名，避免相似 host 被误识别为可导入链接。
    static func isSupportedWereadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "weread.qq.com" || host.hasSuffix(".weread.qq.com")
    }

    private static func candidates(from text: String) -> [String] {
        var values = text
            .components(separatedBy: .whitespacesAndNewlines)
            .map(trimmedCandidate)
            .filter { !$0.isEmpty }

        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]{}"']+"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, range: range)
            let urls = matches.compactMap { match -> String? in
                guard let swiftRange = Range(match.range, in: text) else { return nil }
                return trimmedCandidate(String(text[swiftRange]))
            }
            values.insert(contentsOf: urls, at: 0)
        }

        return values
    }

    private static func normalizedWereadLink(from value: String) -> String? {
        let candidate = trimmedCandidate(value)
        guard let url = URL(string: candidate),
              isSupportedWereadURL(url) else {
            return nil
        }
        return url.absoluteString
    }

    private static func trimmedCandidate(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t，。,.<>[]()（）{}【】「」『』“”\"'"))
    }
}
