/**
 * [INPUT]: 依赖 Domain/Models/BookSearchModels 的搜索结果模型，依赖 XMBookSearchResultCard 统一渲染书籍条目，依赖外部回调承接进入录入页或切换选择动作
 * [OUTPUT]: 对外提供 BookSearchResultRow，封装在线搜索结果条目的点击行为、按压态、多选指示器与无障碍语义
 * [POS]: Book 模块搜索页的页面私有子视图，服务 BookSearchView 的结果列表渲染，不承担搜索状态与导航编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 在线搜索结果的尾部指示器语义，兼容直接消费与多选模式。
enum BookSearchResultRowAccessory: Hashable {
    case none
    case multiple(isSelected: Bool)
}

/// 在线书籍搜索结果行，负责在不改变业务模型的前提下渲染命中高亮与来源差异化信息。
struct BookSearchResultRow: View {
    static let coverWidth = XMBookSearchResultCard.coverWidth

    let result: BookSearchResult
    let keyword: String
    let accessory: BookSearchResultRowAccessory
    let accessibilityHint: String
    let onTap: () -> Void

    init(
        result: BookSearchResult,
        keyword: String,
        accessory: BookSearchResultRowAccessory = .none,
        accessibilityHint: String = "双击补全书籍信息并进入编辑页",
        onTap: @escaping () -> Void
    ) {
        self.result = result
        self.keyword = keyword
        self.accessory = accessory
        self.accessibilityHint = accessibilityHint
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.cozy) {
                card

                if case .multiple(let isSelected) = accessory {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.brand : Color.textHint)
                        .padding(.trailing, Spacing.contentEdge)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(BookSearchResultButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilitySummary)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var card: XMBookSearchResultCard {
        XMBookSearchResultCard(result: result, keyword: keyword)
    }

    private var isSelected: Bool {
        if case .multiple(let isSelected) = accessory {
            return isSelected
        }
        return false
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
