/**
 * [INPUT]: 依赖 SwiftUI 状态与 Reduce Motion 环境，接收 selection/tabs/content/transitionPolicy 构建二级页面常驻容器，并保证新 selection 首帧同帧入树
 * [OUTPUT]: 对外提供 KeepAliveSwitcherHost（懒激活 + 同帧首显 + 常驻保活 + 默认硬切/可选上下文短过渡）
 * [POS]: UIComponents/Navigation/Tabs 的通用切换承载组件，被 Reading/Book/Note 容器复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import os

/// 常驻页面显隐策略；默认硬切维持既有首页行为，需要结构反馈的场景可显式启用短过渡。
enum KeepAliveSwitcherTransitionPolicy: Equatable {
    case hardSwitch
    case contextual
}

/// 通用 Keep-Alive 容器：已激活子页保持常驻，仅切换可见性与交互。
struct KeepAliveSwitcherHost<Selection: Hashable, Content: View>: View {
    let selection: Selection
    let tabs: [Selection]
    let lazyActivation: Bool
    let transitionPolicy: KeepAliveSwitcherTransitionPolicy
    private let content: (Selection) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activatedTabs: Set<Selection>
    @State private var visualSelection: Selection

    private var displayedSelection: Selection {
        transitionPolicy == .hardSwitch ? selection : visualSelection
    }

    private var renderedTabs: [Selection] {
        guard lazyActivation else {
            return tabs
        }
        return tabs.filter {
            activatedTabs.contains($0) || $0 == selection || $0 == displayedSelection
        }
    }

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
        transitionPolicy: KeepAliveSwitcherTransitionPolicy = .hardSwitch,
        @ViewBuilder content: @escaping (Selection) -> Content
    ) {
        self.selection = selection
        self.tabs = tabs
        self.lazyActivation = lazyActivation
        self.transitionPolicy = transitionPolicy
        self.content = content
        let initialTabs = lazyActivation ? [selection] : tabs
        self._activatedTabs = State(initialValue: Set(initialTabs))
        self._visualSelection = State(initialValue: selection)
    }

    var body: some View {
        ZStack {
            ForEach(renderedTabs, id: \.self) { tab in
                content(tab)
                    .opacity(displayedSelection == tab ? 1 : 0)
                    .offset(y: pageOffset(for: tab))
                    .allowsHitTesting(displayedSelection == tab)
                    .accessibilityHidden(displayedSelection != tab)
                    .zIndex(displayedSelection == tab ? 1 : 0)
                    .transaction(value: selection) { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                    .animation(nil, value: activatedTabs)
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
            updateVisualSelection(selection, animated: false)
            activateIfNeeded(selection, reason: "onAppear")
            if !lazyActivation {
                activateAllIfNeeded(reason: "eagerActivation")
            }
            logSwitch(trigger: "onAppear")
        }
        .onChange(of: selection) { _, newSelection in
            activateIfNeeded(newSelection, reason: "selectionChanged")
            updateVisualSelection(newSelection, animated: true)
            logSwitch(trigger: "selectionChanged")
        }
        .onChange(of: tabs) { _, newTabs in
            if !lazyActivation {
                updateWithoutAnimation {
                    activatedTabs = Set(newTabs)
                }
                logActivation(reason: "tabsChangedEager")
            } else {
                activateIfNeeded(selection, reason: "tabsChangedSelection")
            }
            logSwitch(trigger: "tabsChanged")
        }
    }

    /// 上下文过渡只改变页面整体透明度与轻微位移；Reduce Motion 保留短淡入淡出。
    private var selectionAnimation: Animation? {
        switch transitionPolicy {
        case .hardSwitch:
            nil
        case .contextual:
            reduceMotion ? .smooth(duration: 0.14) : .smooth(duration: 0.2)
        }
    }

    /// 已激活但未选中的页面仅保留极小位移作为上下文线索，不改变布局尺寸或页面身份。
    private func pageOffset(for tab: Selection) -> CGFloat {
        guard transitionPolicy == .contextual, !reduceMotion, displayedSelection != tab else {
            return 0
        }
        return 4
    }

    /// 路由 selection 始终保持同帧硬写入；仅显式策略用局部视觉 selection 驱动可中断过渡。
    private func updateVisualSelection(_ tab: Selection, animated: Bool) {
        guard visualSelection != tab else { return }
        guard animated,
              transitionPolicy == .contextual,
              let selectionAnimation else {
            updateWithoutAnimation {
                visualSelection = tab
            }
            return
        }

        withAnimation(selectionAnimation) {
            visualSelection = tab
        }
    }

    /// 首次命中某个分段时激活并常驻，避免后续切回触发重建。
    private func activateIfNeeded(_ tab: Selection, reason: String) {
        guard !activatedTabs.contains(tab) else { return }
        updateWithoutAnimation {
            activatedTabs.insert(tab)
        }
        logActivation(reason: reason)
    }

    /// 非懒激活模式下将全部分段一次性常驻。
    private func activateAllIfNeeded(reason: String) {
        let allTabs = Set(tabs)
        guard activatedTabs != allTabs else { return }
        updateWithoutAnimation {
            activatedTabs = allTabs
        }
        logActivation(reason: reason)
    }

    /// 激活集合与非动画视觉同步必须隔离外层事务，避免新子页插入继承无关动画。
    private func updateWithoutAnimation(_ update: () -> Void) {
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
