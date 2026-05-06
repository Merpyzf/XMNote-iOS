/**
 * [INPUT]: 依赖 SwiftUI ScrollPosition/ScrollGeometry 与 BookshelfReorderOverlayState 驱动默认书架拖拽排序滚动容器
 * [OUTPUT]: 对外提供 BookshelfReorderContainer 和统一坐标空间，封装跟手浮层、ScrollView 几何采集与自动滚动所需状态
 * [POS]: Book 模块页面私有拖拽排序容器，被 BookGridView 的默认书架 Grid/List 共用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 默认书架拖拽排序坐标空间，统一 item frame、手势位置和 overlay 定位。
enum BookshelfReorderCoordinateSpace {
    static let name = "bookshelf-reorder-viewport-space"
}

/// 默认书架拖拽排序容器，承载 ScrollView、滚动几何状态和拖拽项跟手浮层。
struct BookshelfReorderContainer<Content: View, Overlay: View>: View {
    @Binding private var scrollPosition: ScrollPosition
    @Binding private var scrollSnapshot: BookshelfReorderScrollSnapshot

    private let overlayState: BookshelfReorderOverlayState?
    private let content: Content
    private let overlay: Overlay

    /// 构建排序容器，content 负责真实列表布局，overlay 负责拖拽项的浮层渲染。
    init(
        scrollPosition: Binding<ScrollPosition>,
        scrollSnapshot: Binding<BookshelfReorderScrollSnapshot>,
        overlayState: BookshelfReorderOverlayState?,
        @ViewBuilder content: () -> Content,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self._scrollPosition = scrollPosition
        self._scrollSnapshot = scrollSnapshot
        self.overlayState = overlayState
        self.content = content()
        self.overlay = overlay()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ScrollView {
                    content
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(
                    for: BookshelfReorderScrollSnapshot.self,
                    of: { geometry in
                        BookshelfReorderScrollSnapshot(
                            contentOffsetY: max(0, geometry.contentOffset.y),
                            contentHeight: geometry.contentSize.height,
                            viewportHeight: geometry.containerSize.height
                        )
                    },
                    action: { _, newValue in
                        if scrollSnapshot != newValue {
                            scrollSnapshot = newValue
                        }
                    }
                )

                if let overlayState {
                    overlay
                        .frame(width: overlayState.size.width, height: overlayState.size.height)
                        .position(overlayState.center)
                        .scaleEffect(1.035)
                        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 8)
                        .allowsHitTesting(false)
                        .zIndex(20)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: BookshelfReorderCoordinateSpace.name)
        }
    }
}

/// 默认书架编辑态触摸桥，使用 UIKit 手势显式允许长按识别与父级滚动手势共存。
struct BookshelfReorderTouchSurface: UIViewRepresentable {
    var isReorderEnabled: Bool
    var onTap: () -> Void
    var onReorderBegan: (CGPoint) -> Bool
    var onReorderChanged: (CGPoint) -> Void
    var onReorderEnded: (CGPoint) -> Void
    var onReorderCancelled: () -> Void

    /// 创建手势协调器；闭包始终由 SwiftUI update 阶段同步，避免复用旧状态。
    func makeCoordinator() -> Coordinator {
        Coordinator(
            isReorderEnabled: isReorderEnabled,
            onTap: onTap,
            onReorderBegan: onReorderBegan,
            onReorderChanged: onReorderChanged,
            onReorderEnded: onReorderEnded,
            onReorderCancelled: onReorderCancelled
        )
    }

    /// 创建透明命中层，并安装点击与长按识别器。
    func makeUIView(context: Context) -> UIView {
        let view = TouchSurfaceView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapGesture.cancelsTouchesInView = false
        tapGesture.delaysTouchesBegan = false
        tapGesture.delaysTouchesEnded = false
        tapGesture.delegate = context.coordinator

        let longPressGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPressGesture.minimumPressDuration = 0.22
        longPressGesture.allowableMovement = 10
        longPressGesture.cancelsTouchesInView = false
        longPressGesture.delaysTouchesBegan = false
        longPressGesture.delaysTouchesEnded = false
        longPressGesture.delegate = context.coordinator
        longPressGesture.isEnabled = isReorderEnabled
        tapGesture.require(toFail: longPressGesture)

        view.addGestureRecognizer(tapGesture)
        view.addGestureRecognizer(longPressGesture)
        context.coordinator.longPressGesture = longPressGesture
        return view
    }

    /// 同步当前 item 的可拖拽状态和动作闭包。
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            isReorderEnabled: isReorderEnabled,
            onTap: onTap,
            onReorderBegan: onReorderBegan,
            onReorderChanged: onReorderChanged,
            onReorderEnded: onReorderEnded,
            onReorderCancelled: onReorderCancelled
        )
    }

    /// 视图拆卸时恢复滚动锁并取消未结束的排序会话，覆盖页面切换与复用时序。
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.cancelActiveReorder()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isReorderEnabled: Bool
        var onTap: () -> Void
        var onReorderBegan: (CGPoint) -> Bool
        var onReorderChanged: (CGPoint) -> Void
        var onReorderEnded: (CGPoint) -> Void
        var onReorderCancelled: () -> Void

        weak var longPressGesture: UILongPressGestureRecognizer?

        private var isReordering = false
        private weak var lockedScrollView: UIScrollView?
        private var originalScrollEnabled: Bool?

        init(
            isReorderEnabled: Bool,
            onTap: @escaping () -> Void,
            onReorderBegan: @escaping (CGPoint) -> Bool,
            onReorderChanged: @escaping (CGPoint) -> Void,
            onReorderEnded: @escaping (CGPoint) -> Void,
            onReorderCancelled: @escaping () -> Void
        ) {
            self.isReorderEnabled = isReorderEnabled
            self.onTap = onTap
            self.onReorderBegan = onReorderBegan
            self.onReorderChanged = onReorderChanged
            self.onReorderEnded = onReorderEnded
            self.onReorderCancelled = onReorderCancelled
        }

        func update(
            isReorderEnabled: Bool,
            onTap: @escaping () -> Void,
            onReorderBegan: @escaping (CGPoint) -> Bool,
            onReorderChanged: @escaping (CGPoint) -> Void,
            onReorderEnded: @escaping (CGPoint) -> Void,
            onReorderCancelled: @escaping () -> Void
        ) {
            self.isReorderEnabled = isReorderEnabled
            self.onTap = onTap
            self.onReorderBegan = onReorderBegan
            self.onReorderChanged = onReorderChanged
            self.onReorderEnded = onReorderEnded
            self.onReorderCancelled = onReorderCancelled
            longPressGesture?.isEnabled = isReorderEnabled
            if !isReorderEnabled {
                cancelActiveReorder()
            }
        }

        @objc func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
            guard gestureRecognizer.state == .ended else { return }
            onTap()
        }

        @objc func handleLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
            guard isReorderEnabled,
                  let view = gestureRecognizer.view else {
                cancelActiveReorder()
                return
            }
            let location = gestureRecognizer.location(in: view)

            switch gestureRecognizer.state {
            case .began:
                guard onReorderBegan(location) else { return }
                isReordering = true
                lockEnclosingScrollView(from: view)
            case .changed:
                guard isReordering else { return }
                onReorderChanged(location)
            case .ended:
                guard isReordering else { return }
                onReorderEnded(location)
                finishActiveReorder()
            case .cancelled, .failed:
                cancelActiveReorder()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            isScrollPanGesture(otherGestureRecognizer, relativeTo: gestureRecognizer.view)
                || isScrollPanGesture(gestureRecognizer, relativeTo: otherGestureRecognizer.view)
        }

        func cancelActiveReorder() {
            guard isReordering else {
                restoreScrollView()
                return
            }
            onReorderCancelled()
            finishActiveReorder()
        }

        private func finishActiveReorder() {
            isReordering = false
            restoreScrollView()
        }

        private func lockEnclosingScrollView(from view: UIView) {
            guard lockedScrollView == nil,
                  let scrollView = view.enclosingScrollView() else {
                return
            }
            lockedScrollView = scrollView
            originalScrollEnabled = scrollView.isScrollEnabled
            scrollView.isScrollEnabled = false
        }

        private func restoreScrollView() {
            guard let scrollView = lockedScrollView,
                  let originalScrollEnabled else {
                lockedScrollView = nil
                self.originalScrollEnabled = nil
                return
            }
            scrollView.isScrollEnabled = originalScrollEnabled
            lockedScrollView = nil
            self.originalScrollEnabled = nil
        }

        private func isScrollPanGesture(
            _ gestureRecognizer: UIGestureRecognizer,
            relativeTo view: UIView?
        ) -> Bool {
            guard let scrollView = view?.enclosingScrollView() else { return false }
            return gestureRecognizer === scrollView.panGestureRecognizer
        }
    }

    final class TouchSurfaceView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isOpaque = false
        }
    }
}

private extension UIView {
    func enclosingScrollView() -> UIScrollView? {
        if let scrollView = self as? UIScrollView {
            return scrollView
        }
        return superview?.enclosingScrollView()
    }
}
