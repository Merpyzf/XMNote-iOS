/**
 * [INPUT]: 依赖 Domain/Models/BookSearchModels 的搜索结果模型，依赖 XMBookSearchResultCard 统一渲染书籍条目，依赖外部回调承接进入录入页动作
 * [OUTPUT]: 对外提供 BookSearchResultRow，封装在线搜索结果条目的点击行为、按压态与无障碍语义
 * [POS]: Book 模块搜索页的页面私有子视图，服务 BookSearchView 的结果列表渲染，不承担搜索状态与导航编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 在线书籍搜索结果行，负责在不改变业务模型的前提下渲染命中高亮与来源差异化信息。
struct BookSearchResultRow: View {
    static let coverWidth = XMBookSearchResultCard.coverWidth

    let result: BookSearchResult
    let keyword: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            card
        }
        .buttonStyle(BookSearchResultButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilitySummary)
        .accessibilityHint("双击补全书籍信息并进入编辑页")
    }

    private var card: XMBookSearchResultCard {
        XMBookSearchResultCard(result: result, keyword: keyword)
    }
}

private struct BookSearchResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .fill(Color.surfaceNested.opacity(configuration.isPressed ? 1 : 0))
            }
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }
}
