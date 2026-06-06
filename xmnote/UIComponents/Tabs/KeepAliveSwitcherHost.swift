/**
 * [INPUT]: 依赖 SwiftUI 状态系统，接收 selection/tabs/content 构建二级页面常驻容器
 * [OUTPUT]: 对外提供 KeepAliveSwitcherHost（懒激活 + 常驻保活 + 子页显隐硬切）
 * [POS]: UIComponents/Tabs 的通用切换承载组件，被 Reading/Book/Note 容器复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import os

/// 通用 Keep-Alive 容器：已激活子页保持常驻，仅切换可见性与交互。
struct KeepAliveSwitcherHost<Selection: Hashable, Content: View>: View {
    let selection: Selection
    let tabs: [Selection]
    let lazyActivation: Bool
    private let content: (Selection) -> Content

    @State private var activatedTabs: Set<Selection>

    #if DEBUG
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "KeepAliveSwitcherHost"
    )
    #endif

    /// 注入当前选中项与全部分段，构建支持懒激活的常驻容器。
    init(
        selection: Selection,
        tabs: [Selection],
        lazyActivation: Bool = true,
        @ViewBuilder content: @escaping (Selection) -> Content
    ) {
        self.selection = selection
        self.tabs = tabs
        self.lazyActivation = lazyActivation
        self.content = content
        let initialTabs = lazyActivation ? [selection] : tabs
        self._activatedTabs = State(initialValue: Set(initialTabs))
    }

    var body: some View {
        ZStack {
            ForEach(tabs, id: \.self) { tab in
                if activatedTabs.contains(tab) {
                    content(tab)
                        .opacity(selection == tab ? 1 : 0)
                        .allowsHitTesting(selection == tab)
                        .accessibilityHidden(selection != tab)
                        .zIndex(selection == tab ? 1 : 0)
                        // 子页保持常驻，但 selection 驱动的显隐必须硬切，避免顶部分段切换扩散成内容 crossfade。
                        .transaction(value: selection) { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                        .animation(nil, value: selection)
                        .animation(nil, value: activatedTabs)
                }
            }
        }
        .transaction(value: selection) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .transaction(value: activatedTabs) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear {
            activateIfNeeded(selection, reason: "onAppear")
            if !lazyActivation {
                activateAllIfNeeded(reason: "eagerActivation")
            }
            logSwitch(trigger: "onAppear")
        }
        .onChange(of: selection) { _, newSelection in
            activateIfNeeded(newSelection, reason: "selectionChanged")
            logSwitch(trigger: "selectionChanged")
        }
        .onChange(of: tabs) { _, newTabs in
            if !lazyActivation {
                updateActivatedTabsWithoutAnimation {
                    activatedTabs = Set(newTabs)
                }
                logActivation(reason: "tabsChangedEager")
            } else {
                activateIfNeeded(selection, reason: "tabsChangedSelection")
            }
            logSwitch(trigger: "tabsChanged")
        }
    }

    /// 首次命中某个分段时激活并常驻，避免后续切回触发重建。
    private func activateIfNeeded(_ tab: Selection, reason: String) {
        guard !activatedTabs.contains(tab) else { return }
        updateActivatedTabsWithoutAnimation {
            activatedTabs.insert(tab)
        }
        logActivation(reason: reason)
    }

    /// 非懒激活模式下将全部分段一次性常驻。
    private func activateAllIfNeeded(reason: String) {
        let allTabs = Set(tabs)
        guard activatedTabs != allTabs else { return }
        updateActivatedTabsWithoutAnimation {
            activatedTabs = allTabs
        }
        logActivation(reason: reason)
    }

    /// 任何激活集合变化都必须硬切，避免新子页插入继承外层动画事务。
    private func updateActivatedTabsWithoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            update()
        }
    }

    private func logSwitch(trigger: String) {
        #if DEBUG
        logger.notice(
            "[keepalive.switch] trigger=\(trigger, privacy: .public) selection=\(String(describing: selection), privacy: .public) activatedCount=\(self.activatedTabs.count, privacy: .public)"
        )
        #endif
    }

    private func logActivation(reason: String) {
        #if DEBUG
        logger.notice(
            "[keepalive.activate] reason=\(reason, privacy: .public) selection=\(String(describing: selection), privacy: .public) activatedCount=\(self.activatedTabs.count, privacy: .public)"
        )
        #endif
    }
}
