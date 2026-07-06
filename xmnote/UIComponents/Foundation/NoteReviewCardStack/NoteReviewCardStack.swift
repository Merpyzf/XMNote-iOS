/**
 * [INPUT]: 依赖 SwiftUI/UIKit 桥接、NoteReviewCardStackController/Configuration 与 vendored Shuffle 卡堆基座
 * [OUTPUT]: 对外提供 NoteReviewCardStack SwiftUI 组件，支持书摘回顾卡片堆叠、滑动、撤回、重载、三段式刷新与空态承载
 * [POS]: UIComponents/Foundation 的书摘回顾卡堆基础组件，隔离 SwiftUI 业务内容与 UIKit 手势动画核心
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘回顾卡片渲染上下文，供卡片内容判断当前位置与数据规模。
struct NoteReviewCardStackCardContext {
    let index: Int
    let itemCount: Int
    let isTopCard: Bool
}

/// 书摘回顾卡堆组件；使用 UIKit 核心承接滑动手感，并以 SwiftUI 内容构建每张卡片。
struct NoteReviewCardStack<Item: Identifiable, CardContent: View, EmptyContent: View>: View {
    let items: [Item]
    let controller: NoteReviewCardStackController
    var configuration: NoteReviewCardStackConfiguration
    var onCardAppeared: (Item, Int) -> Void
    var onCardDisappeared: (Item, Int) -> Void
    var onSwipeCompleted: (Item, Int, NoteReviewCardStackDirection) -> Void
    var onRewound: (Item, Int) -> Void
    var onReachEnd: () -> Void
    var onNeedsMoreItems: () -> Void
    var onTap: (Item, Int) -> Void
    var onLongPress: (Item, Int) -> Void
    @ViewBuilder let content: (Item, NoteReviewCardStackCardContext) -> CardContent
    @ViewBuilder let emptyContent: () -> EmptyContent

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        items: [Item],
        controller: NoteReviewCardStackController,
        configuration: NoteReviewCardStackConfiguration = .iOSReviewDefault,
        onCardAppeared: @escaping (Item, Int) -> Void = { _, _ in },
        onCardDisappeared: @escaping (Item, Int) -> Void = { _, _ in },
        onSwipeCompleted: @escaping (Item, Int, NoteReviewCardStackDirection) -> Void = { _, _, _ in },
        onRewound: @escaping (Item, Int) -> Void = { _, _ in },
        onReachEnd: @escaping () -> Void = {},
        onNeedsMoreItems: @escaping () -> Void = {},
        onTap: @escaping (Item, Int) -> Void = { _, _ in },
        onLongPress: @escaping (Item, Int) -> Void = { _, _ in },
        @ViewBuilder content: @escaping (Item, NoteReviewCardStackCardContext) -> CardContent,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent
    ) {
        self.items = items
        self.controller = controller
        self.configuration = configuration
        self.onCardAppeared = onCardAppeared
        self.onCardDisappeared = onCardDisappeared
        self.onSwipeCompleted = onSwipeCompleted
        self.onRewound = onRewound
        self.onReachEnd = onReachEnd
        self.onNeedsMoreItems = onNeedsMoreItems
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.content = content
        self.emptyContent = emptyContent
    }

    var body: some View {
        let pendingCommand = controller.pendingCommand
        NoteReviewCardStackRepresentable(
            items: items,
            controller: controller,
            pendingCommand: pendingCommand,
            configuration: configuration.applyingReduceMotion(accessibilityReduceMotion),
            isRefreshing: controller.isRefreshing,
            accessibilityReduceMotion: accessibilityReduceMotion,
            onCardAppeared: onCardAppeared,
            onCardDisappeared: onCardDisappeared,
            onSwipeCompleted: onSwipeCompleted,
            onRewound: onRewound,
            onReachEnd: onReachEnd,
            onNeedsMoreItems: onNeedsMoreItems,
            onTap: onTap,
            onLongPress: onLongPress,
            content: content
        )
        .allowsHitTesting(!controller.isRefreshing)
        .overlay {
            emptyContent()
                .opacity(items.isEmpty ? 1 : 0)
                .allowsHitTesting(items.isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(controller.isRefreshing ? "正在刷新" : "")
    }
}

private struct NoteReviewCardStackRepresentable<Item: Identifiable, CardContent: View>: UIViewRepresentable {
    let items: [Item]
    let controller: NoteReviewCardStackController
    let pendingCommand: NoteReviewCardStackController.Command?
    let configuration: NoteReviewCardStackConfiguration
    let isRefreshing: Bool
    let accessibilityReduceMotion: Bool
    let onCardAppeared: (Item, Int) -> Void
    let onCardDisappeared: (Item, Int) -> Void
    let onSwipeCompleted: (Item, Int, NoteReviewCardStackDirection) -> Void
    let onRewound: (Item, Int) -> Void
    let onReachEnd: () -> Void
    let onNeedsMoreItems: () -> Void
    let onTap: (Item, Int) -> Void
    let onLongPress: (Item, Int) -> Void
    let content: (Item, NoteReviewCardStackCardContext) -> CardContent

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> XMNoteReviewSwipeCardStack {
        let stackView = XMNoteReviewSwipeCardStack()
        context.coordinator.stackView = stackView
        context.coordinator.applyConfiguration(to: stackView)
        stackView.dataSource = context.coordinator
        stackView.delegate = context.coordinator
        context.coordinator.notifyCurrentTopCard(from: stackView)
        return stackView
    }

    func updateUIView(_ uiView: XMNoteReviewSwipeCardStack, context: Context) {
        let reloadReason = context.coordinator.update(parent: self, pendingCommand: pendingCommand)
        context.coordinator.applyConfiguration(to: uiView)
        switch reloadReason {
        case .none:
            break
        case .reset:
            context.coordinator.reload(uiView, keepingPosition: false)
        case .preserveTop:
            context.coordinator.reload(uiView, keepingPosition: true)
        }
        context.coordinator.applyPendingCommand(pendingCommand, to: uiView)
        if !controller.isRefreshing {
            context.coordinator.notifyCurrentTopCard(from: uiView)
        }
    }

    final class Coordinator: NSObject, XMNoteReviewSwipeCardStackDataSource, XMNoteReviewSwipeCardStackDelegate {
        enum ReloadReason {
            case none
            case reset
            case preserveTop
        }

        var items: [Item]
        var configuration: NoteReviewCardStackConfiguration
        var isRefreshing: Bool
        var accessibilityReduceMotion: Bool
        var onCardAppeared: (Item, Int) -> Void
        var onCardDisappeared: (Item, Int) -> Void
        var onSwipeCompleted: (Item, Int, NoteReviewCardStackDirection) -> Void
        var onRewound: (Item, Int) -> Void
        var onReachEnd: () -> Void
        var onNeedsMoreItems: () -> Void
        var onTap: (Item, Int) -> Void
        var onLongPress: (Item, Int) -> Void
        var content: (Item, NoteReviewCardStackCardContext) -> CardContent
        let controller: NoteReviewCardStackController
        weak var stackView: XMNoteReviewSwipeCardStack?

        private var itemIDs: [Item.ID]
        private var lastCommandID: UUID?
        private var lastAppearedIndex: Int?

        init(parent: NoteReviewCardStackRepresentable) {
            self.items = parent.items
            self.configuration = parent.configuration
            self.isRefreshing = parent.isRefreshing
            self.accessibilityReduceMotion = parent.accessibilityReduceMotion
            self.onCardAppeared = parent.onCardAppeared
            self.onCardDisappeared = parent.onCardDisappeared
            self.onSwipeCompleted = parent.onSwipeCompleted
            self.onRewound = parent.onRewound
            self.onReachEnd = parent.onReachEnd
            self.onNeedsMoreItems = parent.onNeedsMoreItems
            self.onTap = parent.onTap
            self.onLongPress = parent.onLongPress
            self.content = parent.content
            self.controller = parent.controller
            self.itemIDs = parent.items.map(\.id)
        }

        func update(
            parent: NoteReviewCardStackRepresentable,
            pendingCommand: NoteReviewCardStackController.Command?
        ) -> ReloadReason {
            let newIDs = parent.items.map(\.id)
            let idsChanged = newIDs != itemIDs
            let configurationChanged = parent.configuration != configuration
            let isRefreshCommandPending: Bool
            if case .refresh = pendingCommand {
                isRefreshCommandPending = true
            } else {
                isRefreshCommandPending = false
            }

            items = parent.items
            configuration = parent.configuration
            isRefreshing = parent.isRefreshing
            accessibilityReduceMotion = parent.accessibilityReduceMotion
            onCardAppeared = parent.onCardAppeared
            onCardDisappeared = parent.onCardDisappeared
            onSwipeCompleted = parent.onSwipeCompleted
            onRewound = parent.onRewound
            onReachEnd = parent.onReachEnd
            onNeedsMoreItems = parent.onNeedsMoreItems
            onTap = parent.onTap
            onLongPress = parent.onLongPress
            content = parent.content
            if idsChanged {
                lastAppearedIndex = nil
            }
            itemIDs = newIDs

            if idsChanged, !isRefreshCommandPending {
                return .preserveTop
            }
            if configurationChanged, !isRefreshCommandPending {
                return .preserveTop
            }
            return .none
        }

        func applyConfiguration(to stackView: XMNoteReviewSwipeCardStack) {
            stackView.cardStackInsets = configuration.cardInsets
            if stackView.numberOfVisibleCards != configuration.visibleCount {
                stackView.numberOfVisibleCards = configuration.visibleCount
            }
            stackView.scaleInterval = configuration.scaleInterval
            stackView.translationInterval = configuration.translationInterval
            stackView.shouldRecognizeHorizontalDrag = configuration.allowedDirections.contains(.left)
                || configuration.allowedDirections.contains(.right)
            stackView.shouldRecognizeVerticalDrag = configuration.allowedDirections.contains(.up)
                || configuration.allowedDirections.contains(.down)
            stackView.prefersEmbeddedVerticalScroll = configuration.prefersEmbeddedVerticalScroll
            stackView.isUserInteractionEnabled = !isRefreshing

            var stackAnimationOptions = XMNoteReviewCardStackAnimationOptions()
            stackAnimationOptions.resetDuration = configuration.resetAnimationDuration
            stackAnimationOptions.swipeDuration = configuration.stackAnimationDuration
            stackAnimationOptions.undoDuration = configuration.stackAnimationDuration
            stackAnimationOptions.shiftDuration = configuration.stackAnimationDuration
            stackView.animationOptions = stackAnimationOptions
        }

        func applyPendingCommand(
            _ pendingCommand: NoteReviewCardStackController.Command?,
            to stackView: XMNoteReviewSwipeCardStack
        ) {
            guard let command = pendingCommand,
                  command.id != lastCommandID else { return }
            lastCommandID = command.id

            switch command {
            case let .swipe(_, direction, animated):
                guard !items.isEmpty else { break }
                stackView.swipe(direction.vendorDirection, animated: animated)
            case let .rewind(_, animated):
                guard !items.isEmpty else { break }
                stackView.undoLastSwipe(animated: animated)
            case let .reload(_, keepingPosition):
                reload(stackView, keepingPosition: keepingPosition)
            case let .refresh(_, mode):
                refresh(stackView, mode: mode)
            case let .scrollToIndex(_, index, animated):
                scroll(stackView, to: index, animated: animated)
            case let .scrollToFirst(_, animated):
                scroll(stackView, to: 0, animated: animated)
            }

            DispatchQueue.main.async { [weak controller] in
                controller?.clearCommand(command.id)
            }
        }

        func refresh(_ stackView: XMNoteReviewSwipeCardStack, mode: NoteReviewCardStackRefreshMode) {
            guard !items.isEmpty else {
                reload(stackView, keepingPosition: false)
                controller.finishRefresh()
                return
            }
            lastAppearedIndex = nil
            controller.update(
                currentIndex: stackView.topCardIndex,
                appearedIndex: stackView.topCardIndex,
                disappearedIndex: controller.disappearedIndex,
                isAnimating: true
            )
            stackView.performRefreshAnimation(mode: mode, reduceMotion: accessibilityReduceMotion) { [weak self, weak stackView] in
                guard let self, let stackView else { return }
                self.notifyCurrentTopCard(from: stackView)
                self.controller.finishRefresh()
            }
        }

        func reload(_ stackView: XMNoteReviewSwipeCardStack, keepingPosition: Bool) {
            let topIndex = keepingPosition ? stackView.topCardIndex : nil
            stackView.reloadData()
            if let topIndex, !items.isEmpty {
                stackView.scrollToIndex(min(topIndex, items.count - 1))
            }
            notifyCurrentTopCard(from: stackView)
        }

        func scroll(_ stackView: XMNoteReviewSwipeCardStack, to index: Int, animated: Bool) {
            guard !items.isEmpty else {
                stackView.reloadData()
                notifyCurrentTopCard(from: stackView)
                return
            }
            let targetIndex = max(0, min(index, items.count - 1))
            let updates = { [weak self, weak stackView] in
                guard let stackView else { return }
                stackView.scrollToIndex(targetIndex)
                self?.notifyCurrentTopCard(from: stackView)
            }
            guard animated else {
                updates()
                return
            }
            UIView.transition(
                with: stackView,
                duration: configuration.stackAnimationDuration,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: updates
            )
        }

        func notifyCurrentTopCard(from stackView: XMNoteReviewSwipeCardStack) {
            let topIndex = stackView.topCardIndex
            controller.update(
                currentIndex: topIndex,
                appearedIndex: topIndex,
                disappearedIndex: controller.disappearedIndex,
                isAnimating: stackView.isAnimating
            )
            guard let topIndex,
                  topIndex != lastAppearedIndex,
                  items.indices.contains(topIndex)
            else { return }
            lastAppearedIndex = topIndex
            onCardAppeared(items[topIndex], topIndex)
        }

        func cardStack(_ cardStack: XMNoteReviewSwipeCardStack, cardForIndexAt index: Int) -> XMNoteReviewSwipeCard {
            let card = NoteReviewHostedSwipeCard<CardContent>()
            card.dataSourceIndex = index
            card.backgroundColor = .clear
            card.footerHeight = 0
            configure(card, for: index)
            return card
        }

        func numberOfCards(in cardStack: XMNoteReviewSwipeCardStack) -> Int {
            items.count
        }

        func cardStack(_ cardStack: XMNoteReviewSwipeCardStack, didSelectCardAt index: Int) {
            guard items.indices.contains(index) else { return }
            onTap(items[index], index)
        }

        func cardStack(
            _ cardStack: XMNoteReviewSwipeCardStack,
            didSwipeCardAt index: Int,
            with direction: XMNoteReviewSwipeDirection
        ) {
            guard items.indices.contains(index) else { return }
            let mappedDirection = NoteReviewCardStackDirection(vendorDirection: direction)
            controller.update(
                currentIndex: cardStack.topCardIndex,
                appearedIndex: cardStack.topCardIndex,
                disappearedIndex: index,
                isAnimating: cardStack.isAnimating
            )
            onCardDisappeared(items[index], index)
            onSwipeCompleted(items[index], index, mappedDirection)
            if index + configuration.preloadDistance >= max(items.count - 1, 0) {
                onNeedsMoreItems()
            }
            notifyCurrentTopCard(from: cardStack)
        }

        func cardStack(
            _ cardStack: XMNoteReviewSwipeCardStack,
            didUndoCardAt index: Int,
            from direction: XMNoteReviewSwipeDirection
        ) {
            guard items.indices.contains(index) else { return }
            onRewound(items[index], index)
            notifyCurrentTopCard(from: cardStack)
        }

        func didSwipeAllCards(_ cardStack: XMNoteReviewSwipeCardStack) {
            onReachEnd()
            controller.update(
                currentIndex: nil,
                appearedIndex: nil,
                disappearedIndex: controller.disappearedIndex,
                isAnimating: cardStack.isAnimating
            )
            guard configuration.isLoopingEnabled, !items.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + configuration.swipeAnimationDuration) { [weak self, weak cardStack] in
                guard let self, let cardStack else { return }
                self.scroll(cardStack, to: 0, animated: true)
            }
        }

        private func configure(_ card: NoteReviewHostedSwipeCard<CardContent>, for index: Int) {
            guard items.indices.contains(index) else { return }
            let context = NoteReviewCardStackCardContext(
                index: index,
                itemCount: items.count,
                isTopCard: index == stackView?.topCardIndex
            )
            let hostingController = UIHostingController(rootView: content(items[index], context))
            hostingController.view.backgroundColor = .clear
            hostingController.view.isOpaque = false
            card.hostingController = hostingController
            card.content = hostingController.view
            card.swipeDirections = configuration.sortedVendorDirections
            card.minimumSwipeDistanceRatio = configuration.swipeThreshold
            card.minimumSwipeSpeedThreshold = configuration.minimumSwipeSpeed
            card.isTapEnabled = configuration.isTapEnabled
            card.tapGestureRecognizer.isEnabled = configuration.isTapEnabled
            card.panGestureRecognizer.isEnabled = configuration.isSwipeEnabled && !configuration.allowedDirections.isEmpty

            var cardAnimationOptions = XMNoteReviewCardAnimationOptions()
            cardAnimationOptions.maximumRotationAngle = configuration.maxRotationRadians
            cardAnimationOptions.totalSwipeDuration = configuration.swipeAnimationDuration
            cardAnimationOptions.totalResetDuration = configuration.resetAnimationDuration
            cardAnimationOptions.resetSpringDamping = configuration.resetSpringDamping
            cardAnimationOptions.totalReverseSwipeDuration = configuration.undoAnimationDuration
            card.animationOptions = cardAnimationOptions

            if configuration.showsDirectionOverlay {
                card.setOverlays(Dictionary(uniqueKeysWithValues: NoteReviewCardStackDirection.allCases.map {
                    ($0.vendorDirection, NoteReviewDirectionOverlayView(direction: $0))
                }))
            }

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.cancelsTouchesInView = false
            card.addGestureRecognizer(longPress)
        }

        @objc
        private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let card = recognizer.view as? NoteReviewHostedSwipeCard<CardContent>,
                  items.indices.contains(card.dataSourceIndex)
            else { return }
            onLongPress(items[card.dataSourceIndex], card.dataSourceIndex)
        }
    }
}

private final class NoteReviewHostedSwipeCard<Content: View>: XMNoteReviewSwipeCard {
    var hostingController: UIHostingController<Content>?
    var dataSourceIndex = 0
}

private final class NoteReviewDirectionOverlayView: UIView {
    private let label = UILabel()

    init(direction: NoteReviewCardStackDirection) {
        super.init(frame: .zero)
        backgroundColor = UIColor.systemGreen.withAlphaComponent(0.14)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        label.text = direction.title
        label.textAlignment = .center
        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.textColor = UIColor.label.withAlphaComponent(0.72)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        nil
    }
}
