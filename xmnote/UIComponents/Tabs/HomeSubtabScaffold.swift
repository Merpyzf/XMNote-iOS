/**
 * [INPUT]: 依赖 TopSwitcher、KeepAliveSwitcherHost、HomeTopHeaderGradient 与 DesignTokens，接收首页二级页 selection/tabs/trailing/content/selection 事务策略组装稳定父级壳层
 * [OUTPUT]: 对外提供 HomeSubtabScaffold，统一首页一级 Tab 内二级子页面的顶部切换、保活硬切与稳定顶部高度
 * [POS]: UIComponents/Tabs 的首页二级页基建组件，被 Book/Reading/Note 等首页模块渐进接入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 首页二级页通用壳层，父级只管理顶部切换与保活宿主，页面专属工具栏留在各子页内部。
struct HomeSubtabScaffold<Selection: Hashable, Trailing: View, Content: View>: View {
    @Binding private var selection: Selection
    private let tabs: [Selection]
    private let topBarHeight: CGFloat
    private let lazyActivation: Bool
    private let showsTopSwitcher: Bool
    private let showsHeaderGradient: Bool
    private let selectionTransactionPolicy: TopSwitcherSelectionTransactionPolicy
    private let titleProvider: (Selection) -> String
    private let trailing: (Selection) -> Trailing
    private let content: (Selection) -> Content

    /// 注入二级页选择状态与页面构造闭包，构建稳定高度、保活硬切的首页子页面容器。
    init(
        selection: Binding<Selection>,
        tabs: [Selection],
        topBarHeight: CGFloat = 56,
        lazyActivation: Bool = true,
        showsTopSwitcher: Bool = true,
        showsHeaderGradient: Bool = true,
        selectionTransactionPolicy: TopSwitcherSelectionTransactionPolicy = .hardSwitch,
        titleProvider: @escaping (Selection) -> String,
        @ViewBuilder trailing: @escaping (Selection) -> Trailing,
        @ViewBuilder content: @escaping (Selection) -> Content
    ) {
        self._selection = selection
        self.tabs = tabs
        self.topBarHeight = topBarHeight
        self.lazyActivation = lazyActivation
        self.showsTopSwitcher = showsTopSwitcher
        self.showsHeaderGradient = showsHeaderGradient
        self.selectionTransactionPolicy = selectionTransactionPolicy
        self.titleProvider = titleProvider
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            segmentedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, topBarHeight)
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if showsHeaderGradient {
                HomeTopHeaderGradient()
                    .allowsHitTesting(false)
            }

            if showsTopSwitcher {
                TopSwitcher(
                    selection: $selection,
                    tabs: tabs,
                    selectionTransactionPolicy: selectionTransactionPolicy,
                    titleProvider: titleProvider
                ) {
                    trailing(selection)
                }
                .zIndex(1)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var segmentedContent: some View {
        KeepAliveSwitcherHost(
            selection: selection,
            tabs: tabs,
            lazyActivation: lazyActivation
        ) { tab in
            content(tab)
        }
    }
}
