/**
 * [INPUT]: 依赖 BookSearchResultRow 与占位搜索结果模型生成骨架态，依赖 DesignTokens 保持与真实行一致的节奏
 * [OUTPUT]: 对外提供 BookSearchResultSkeletonRow，承接搜索页加载态的同构占位渲染
 * [POS]: Book 模块搜索页的页面私有骨架组件，服务 BookSearchView 的加载态展示，不承担真实数据展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 搜索结果骨架行，复用真实条目的版式降低加载态和结果态之间的割裂感。
struct BookSearchResultSkeletonRow: View {
    let source: BookSearchSource

    var body: some View {
        BookSearchResultRow(
            result: .skeletonPlaceholder(for: source),
            keyword: "",
            onTap: {}
        )
        .allowsHitTesting(false)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

private extension BookSearchResult {
    static func skeletonPlaceholder(for source: BookSearchSource) -> BookSearchResult {
        return BookSearchResult(
            id: "skeleton-\(source.rawValue)",
            source: source,
            title: "搜索结果标题占位",
            author: source == .douban ? "" : "示例作者",
            coverURL: "",
            subtitle: "[美] 作者 / 出版社 / 2024-08 / 52.00元",
            summary: "",
            translator: source == .douban ? "" : "示例译者",
            press: source == .douban ? "" : "示例出版社",
            isbn: "",
            pubDate: source == .douban ? "" : "2024-08",
            doubanId: nil,
            totalPages: nil,
            totalWordCount: nil,
            seed: nil,
            detailPageURL: nil
        )
    }
}
