/**
 * [INPUT]: 依赖 Domain/Models/BookSearchModels 的搜索结果模型，依赖 XMBookSearchResultCard 统一渲染书籍条目，依赖外部回调承接进入录入页或切换选择动作
 * [OUTPUT]: 对外提供 BookSearchResultRow，封装在线搜索结果条目的点击行为、独立/分组按压态、多选指示器与无障碍语义
 * [POS]: Book 模块搜索页的页面私有子视图，服务 BookSearchView 的结果列表渲染，不承担搜索状态与导航编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 在线搜索结果的尾部指示器语义，兼容直接消费与多选模式。
enum BookSearchResultRowAccessory: Hashable {
    case none
    case multiple(isSelected: Bool)
}

/// 在线结果行的容器语义；独立搜索页保留原样，BookPicker 可接入连续分组表面。
enum BookSearchResultRowPresentation: Hashable {
    case standalone
    case grouped
}

/// 在线书籍搜索结果行，负责在不改变业务模型的前提下渲染命中高亮与来源差异化信息。
struct BookSearchResultRow: View {
    static let coverWidth = XMBookSearchResultCard.coverWidth

    let result: BookSearchResult
    let keyword: String
    let accessory: BookSearchResultRowAccessory
    let presentation: BookSearchResultRowPresentation
    let accessibilityHint: String
    let onTap: () -> Void

    init(
        result: BookSearchResult,
        keyword: String,
        accessory: BookSearchResultRowAccessory = .none,
        presentation: BookSearchResultRowPresentation = .standalone,
        accessibilityHint: String = "双击补全书籍信息并进入编辑页",
        onTap: @escaping () -> Void
    ) {
        self.result = result
        self.keyword = keyword
        self.accessory = accessory
        self.presentation = presentation
        self.accessibilityHint = accessibilityHint
        self.onTap = onTap
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.cozy) {
                card

                if case .multiple(let isSelected) = accessory {
                    XMSelectionIndicator(
                        style: .checkbox,
                        isSelected: isSelected,
                        font: AppTypography.title3
                    )
                        .padding(.trailing, Spacing.contentEdge)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(BookSearchResultButtonStyle(presentation: presentation))
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
    let presentation: BookSearchResultRowPresentation

    /// 分组模式仅使用中性整行高亮，独立模式继续沿用搜索页原有圆角反馈。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                pressedBackground(isPressed: configuration.isPressed)
            }
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }

    @ViewBuilder
    private func pressedBackground(isPressed: Bool) -> some View {
        switch presentation {
        case .standalone:
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .fill(Color.surfaceNested.opacity(isPressed ? 1 : 0))
        case .grouped:
            Rectangle()
                .fill(Color.controlFillSecondary.opacity(isPressed ? 1 : 0))
        }
    }
}
