/**
 * [INPUT]: 依赖 NoteViewModel 提供默认书摘分组、用户书摘标签与当前搜索词，依赖外部闭包承接范围导航
 * [OUTPUT]: 对外提供 NoteTagsView，复用 NoteIndexGridItemButton 呈现默认分组与用户标签，并让标签管理使用纯右箭头入口
 * [POS]: Note 模块书摘分类首页内容，被 NoteCollectionView 嵌入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘入口视图以统一等宽中性浅矩形承载系统聚合与个人标签，仅通过区段标题和留白表达分组差异。
struct NoteTagsView: View {
    @Bindable var viewModel: NoteViewModel
    let onOpenScope: (NoteExcerptListContext) -> Void
    let onManageTags: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 注入书摘范围导航回调，默认空实现兼容预览与旧调用点。
    init(
        viewModel: NoteViewModel,
        onOpenScope: @escaping (NoteExcerptListContext) -> Void = { _ in },
        onManageTags: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onOpenScope = onOpenScope
        self.onManageTags = onManageTags
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: NoteTagsLayout.sectionSpacing) {
            if !viewModel.filteredDefaultGroups.isEmpty {
                defaultGroupsSection
            }
            if !viewModel.filteredUserTags.isEmpty {
                userTagsSection
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.double)
    }

    private var defaultGroupsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            NoteIndexSectionHeader(title: "默认分组")

            LazyVGrid(columns: indexColumns, spacing: NoteIndexGridLayout.rowSpacing) {
                ForEach(viewModel.filteredDefaultGroups) { group in
                    indexButton(group)
                }
            }
        }
    }

    private var userTagsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            NoteIndexSectionHeader(title: "我的标签", action: onManageTags)

            LazyVGrid(columns: indexColumns, spacing: NoteIndexGridLayout.rowSpacing) {
                ForEach(viewModel.filteredUserTags) { group in
                    indexButton(group)
                }
            }
        }
    }

    /// 默认范围与用户标签共用完全一致的中性浅矩形、字体和计数尾槽，仅由所在区段表达分组语义。
    private func indexButton(_ group: NoteExcerptGroupItem) -> some View {
        NoteIndexGridItemButton(
            title: group.title,
            count: group.count,
            searchQuery: viewModel.normalizedSearchText(for: .excerpts),
            accessibilityLabel: "\(group.title)，\(group.count)条",
            accessibilityHint: "打开书摘列表"
        ) {
            onOpenScope(
                NoteExcerptListContext(
                    scope: group.scope,
                    displayTitle: group.title
                )
            )
        }
    }

    private var indexColumns: [GridItem] {
        NoteIndexGridLayout.columns(dynamicTypeSize: dynamicTypeSize)
    }
}

private enum NoteTagsLayout {
    static let sectionHeaderMinHeight: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let disclosurePressedOpacity: Double = 0.55
    static let disclosureDisabledOpacity: Double = 0.35
    static let disclosureAnimationDuration: TimeInterval = 0.12
}

/// 书摘索引专用的弱区段标题，不改变星标、相关和书评使用的通用首页标题层级。
private struct NoteIndexSectionHeader: View {
    let title: String
    let action: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    /// 创建弱标题或附带纯右箭头管理入口；视觉保持轻量，点击区扩展到 44pt。
    init(title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.footnoteSemibold)
                .foregroundStyle(Color.textSecondary)

            Spacer(minLength: Spacing.base)

            if let action {
                Button(action: action) {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption2Semibold)
                        .foregroundStyle(Color.textSecondary)
                        .frame(
                            width: Spacing.actionReserved,
                            height: Spacing.actionReserved,
                            alignment: .trailing
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(NoteDisclosureButtonStyle(reduceMotion: reduceMotion))
                .opacity(isEnabled ? 1 : NoteTagsLayout.disclosureDisabledOpacity)
                .padding(.vertical, -Spacing.base)
                .accessibilityLabel("管理标签")
                .accessibilityHint("进入标签管理")
            }
        }
        .frame(minHeight: NoteTagsLayout.sectionHeaderMinHeight)
    }
}

private struct NoteDisclosureButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    /// 右箭头入口仅用透明度确认按下，避免引入新的圆底或位移动效语言。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? NoteTagsLayout.disclosurePressedOpacity : 1)
            .animation(
                reduceMotion ? nil : .smooth(duration: NoteTagsLayout.disclosureAnimationDuration),
                value: configuration.isPressed
            )
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    ScrollView {
        NoteTagsView(viewModel: NoteViewModel(repository: repositories.noteRepository))
    }
    .background(Color.surfacePage)
}
