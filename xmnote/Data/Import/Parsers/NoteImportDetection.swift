/**
 * [INPUT]: 依赖 Foundation 与 NoteImportModels，接收文件原始字节和扩展名
 * [OUTPUT]: 对外提供 NoteImportDetection，严格按 Android 当前检测优先级选择 Parser
 * [POS]: Data/Import 的入口识别器，与具体 Parser 内容解析分离并接受独立差分测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated enum NoteImportDetection {
    static func detectWereadClipboard(data: Data) -> NoteImportParserID? {
        guard let content = try? NoteImportTextSupport.decodeUTF8(data) else { return nil }
        if content.range(of: ">[^> ]", options: .regularExpression) != nil { return .wereadOld }
        if content.components(separatedBy: "\n").filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).contains(where: { $0.hasPrefix(">> ") }) { return .wereadPre830 }
        return content.contains("-- 来自微信读书") ? .weread830 : nil
    }

    /// 当前仅开放已迁移且通过 Golden 的来源；新增来源必须先补 Oracle case 再加入优先级。
    static func detect(data: Data, fileExtension: String?) -> NoteImportParserID? {
        guard let content = try? NoteImportTextSupport.decodeUTF8(data) else { return nil }
        if isBoox(content) {
            return isOldBoox(content) ? .booxOld : .booxNew
        }
        if NoteImportTextSupport.contains(pattern: "^#.*的批注与划线", in: content) {
            return .doubanRead
        }
        if content.contains("——来自得到App") {
            return .dedao
        }
        if NoteImportTextSupport.contains(pattern: "\\n\\n(.|\\n)+?\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}", in: content) {
            return .dangdang
        }
        if content.contains("条滴墨书摘") {
            return .dimo
        }
        if content.contains("==========") {
            return .kindle
        }
        if content.contains("<div class=\"bookTitle\">") {
            return .kindleApp
        }
        if fileExtension?.lowercased() == "csv" {
            return .koodo
        }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let array = json as? [[String: Any]], let first = array.first,
               first["bookAuthor"] != nil, first["bookName"] != nil,
               first["bookText"] != nil, first["chapterIndex"] != nil,
               first["chapterName"] != nil, first["chapterPos"] != nil,
               first["content"] != nil, first["time"] != nil
            {
                return .legado
            }
            if let object = json as? [String: Any] {
                if let notes = object["noteList"] as? [[String: Any]], !notes.isEmpty,
                   !(object["bookName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return .neatReader
                }
                if isKOReaderJSON(object) { return .koreader }
                if isReedenJSON(object) { return .reeden }
            }
            if let array = json as? [[String: Any]], let first = array.first, isReedenJSON(first) {
                return .reeden
            }
        }
        return nil
    }

    static func isBoox(_ content: String) -> Bool {
        guard let firstLine = content.components(separatedBy: "\n").first else { return false }
        return NoteImportTextSupport.contains(
            pattern: "^(读书笔记|讀書筆記)[ \\s]*\\|[ \\s]*<<.+?>>",
            in: NoteImportTextSupport.trimmed(firstLine)
        )
    }

    static func isOldBoox(_ content: String) -> Bool {
        content.contains("【页码】") || content.contains("【頁碼】")
    }

    private static func isKOReaderJSON(_ object: [String: Any]) -> Bool {
        if let documents = object["documents"] as? [[String: Any]], !documents.isEmpty {
            return documents.contains { document in
                let hasIdentity = !(document["title"] as? String ?? "").isEmpty
                    || !(document["file"] as? String ?? "").isEmpty
                return hasIdentity && hasValidJSONNotes(document["entries"])
            }
        }
        let hasIdentity = !(object["title"] as? String ?? "").isEmpty
            || !(object["file"] as? String ?? "").isEmpty
        return hasIdentity && hasValidJSONNotes(object["entries"])
    }

    private static func isReedenJSON(_ object: [String: Any]) -> Bool {
        !(object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ((object["notes"] as? [[String: Any]])?.contains {
                !($0["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !($0["comment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false)
    }

    private static func hasValidJSONNotes(_ value: Any?) -> Bool {
        (value as? [[String: Any]])?.contains {
            !($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !($0["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
    }
}
