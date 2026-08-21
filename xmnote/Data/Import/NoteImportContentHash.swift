/**
 * [INPUT]: 依赖 CryptoKit 与 Foundation，接收落库前的书摘正文、想法和有序附件摘要
 * [OUTPUT]: 对外提供与 Android NoteContentHashHelper 字节格式一致的 SHA-256 内容身份
 * [POS]: Data/Import 的纯值 Hash 基础设施，被导入仓储与收敛测试共同使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Foundation

/// 书摘导入内容身份；文本优先使用 v1，纯图片书摘使用保持附件顺序的 v2。
nonisolated enum NoteImportContentHash {
    /// 生成 Android 兼容 Hash；无文本且无有效附件摘要时返回 nil，表示该 Draft 不可导入。
    static func calculate(
        content: String,
        idea: String,
        attachmentDigests: [String] = []
    ) -> String? {
        let canonicalContent = canonicalize(content)
        let canonicalIdea = canonicalize(idea)
        if !NoteImportTextSupport.isBlank(canonicalContent) || !NoteImportTextSupport.isBlank(canonicalIdea) {
            return hash(version: 1, fields: [Data(canonicalContent.utf8), Data(canonicalIdea.utf8)])
        }

        let digests = attachmentDigests
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !digests.isEmpty else { return nil }
        var payload = Data([2])
        appendLength(digests.count, to: &payload)
        for digest in digests {
            let bytes = Data(digest.utf8)
            appendLength(bytes.count, to: &payload)
            payload.append(bytes)
        }
        return sha256(payload)
    }

    private static func hash(version: UInt8, fields: [Data]) -> String {
        var payload = Data([version])
        for field in fields {
            appendLength(field.count, to: &payload)
            payload.append(field)
        }
        return sha256(payload)
    }

    private static func appendLength(_ length: Int, to data: inout Data) {
        let value = UInt32(truncatingIfNeeded: length).bigEndian
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
