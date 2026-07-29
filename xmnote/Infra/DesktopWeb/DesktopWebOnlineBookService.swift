/**
 * [INPUT]: 依赖 URLSession 调用 Android 同一 Wenqu 搜索端点，接收原始 keyword
 * [OUTPUT]: 对外提供 Web 在线书籍搜索结果，并复刻 BookDtoMapper、fuzzywuzzy 排序与目录清洗
 * [POS]: Infra 层 Web 在线书籍能力；与 App 录入搜索的 ISBN/豆瓣兜底策略隔离
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import XMNoteWeb

/// 每次搜索只持有不可变请求状态；URLSession 取消会随调用任务传播，不写入 App 数据。
final class DesktopWebOnlineBookService: DesktopWebOnlineBookPort, @unchecked Sendable {
    private struct Response: Decodable {
        let books: [Book]
    }

    private struct Book: Decodable {
        let title: String?
        let author: String?
        let press: String?
        let pubdate: String?
        let image: String?
        let isbn: String?
        let summary: String?
        let authorIntro: String?
        let catalog: String?
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// 原样传递非空 keyword，不套用 App 搜索的 trim、ISBN 特判或豆瓣兜底。
    func searchOnlineBooks(keyword: String) async throws -> [DesktopWebOnlineBook] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopWebAPIError(code: 40001, message: "搜索关键词不能为空")
        }
        var components = URLComponents(string: "https://wenqu.annatarhe.cn/api/v1/books/search")
        components?.queryItems = [
            .init(name: "page", value: "1"),
            .init(name: "limit", value: "50"),
            .init(name: "query", value: keyword)
        ]
        guard let url = components?.url else {
            throw DesktopWebAPIError(code: 50001, message: "Wenqu 请求地址无效")
        }
        var request = URLRequest(url: url)
        request.setValue(
            "500ae25e22b5de1b6c44a7d78908e7b7cc63f97b55ea9cdc50aa8fcd84b1fcba",
            forHTTPHeaderField: "X-Simple-Check"
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DesktopWebAPIError(code: 50001, message: "Wenqu 请求失败: HTTP \(status)")
        }
        let books = try JSONDecoder().decode(Response.self, from: data).books
        return books.enumerated().sorted { left, right in
            let leftScore = Self.fuzzyRatio(left.element.title ?? "", keyword)
                + Self.fuzzyRatio(left.element.author ?? "", keyword)
            let rightScore = Self.fuzzyRatio(right.element.title ?? "", keyword)
                + Self.fuzzyRatio(right.element.author ?? "", keyword)
            return leftScore == rightScore ? left.offset < right.offset : leftScore > rightScore
        }.map { _, book in
            DesktopWebOnlineBook(
                title: book.title ?? "",
                author: book.author ?? "",
                publisher: book.press ?? "",
                pubDate: Self.androidDate(book.pubdate ?? ""),
                cover: book.image ?? "",
                isbn: book.isbn ?? "",
                summary: book.summary ?? "",
                authorIntro: book.authorIntro ?? "",
                catalog: Self.normalizeCatalog(book.catalog ?? "")
            )
        }
    }

    private static func androidDate(_ value: String) -> String {
        guard !value.isEmpty else { return value }
        let segments = value.components(separatedBy: "T")
        let dateValue = segments.count == 2 ? segments[0] : value
        let parser = DateFormatter()
        parser.locale = .current
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = true
        guard let date = parser.date(from: dateValue) else {
            return dateValue
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM"
        // NOTE(ANDROID-WEB-095): Book.pubDate 的共享 setter 会丢失在线结果的“日”精度；正式合同按月复刻。
        return formatter.string(from: date)
    }

    private static func normalizeCatalog(_ value: String) -> String {
        value.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{00A0}", with: " ")
                .replacingOccurrences(of: "\u{200B}", with: "")
                .replacingOccurrences(of: "\u{200C}", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 复刻 java fuzzywuzzy ratio 使用的 Levenshtein 归一化百分比。
    private static func fuzzyRatio(_ lhs: String, _ rhs: String) -> Int {
        // Java String.length/charAt 以 UTF-16 code unit 计数；不能使用 Swift Character 的 grapheme cluster。
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        let total = left.count + right.count
        // fuzzywuzzy 对空串比空串的 NaN 最终经 Math.round 归零。
        guard total > 0 else { return 0 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    // java fuzzywuzzy 的 ratio 把替换视为一次删除加一次插入，成本为 2。
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 2)
                )
            }
            previous = current
        }
        return Int((Double(total - previous[right.count]) / Double(total) * 100).rounded())
    }
}
