/**
 * [INPUT]: 依赖 Foundation/CoreGraphics，承接书摘回顾 BigUIPaging Core 之上的 XMNote 自定义卡组方向、状态与动效参数
 * [OUTPUT]: 对外提供 NoteReviewPagingState、NoteReviewPagingMotionSpec、NoteReviewPagingLayoutSpec 与 NoteReviewPagingDeckConfiguration
 * [POS]: NoteReviewPaging 的纯状态与动效规格层，被生产回顾页、Debug 页与单元测试共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreGraphics
import Foundation
import SwiftUI

/// 书摘回顾卡组的分页语义；next 对应左滑，previous 对应右滑。
enum NoteReviewPagingNavigation: Hashable {
    case next
    case previous

    var visualProgressSign: CGFloat {
        switch self {
        case .next:
            return 1
        case .previous:
            return -1
        }
    }
}

/// 书摘回顾卡组的纯分页状态，负责把加载数据、当前选中项、循环策略解析成相邻页。
struct NoteReviewPagingState<ID: Hashable>: Equatable {
    private(set) var itemIDs: [ID]
    private(set) var selection: ID?
    private(set) var hasMoreItems: Bool
    var isLoopingEnabled: Bool

    /// 创建分页状态并将无效选中项规整到第一条可用数据。
    init(
        itemIDs: [ID],
        selection: ID?,
        hasMoreItems: Bool,
        isLoopingEnabled: Bool
    ) {
        self.itemIDs = itemIDs
        self.selection = selection
        self.hasMoreItems = hasMoreItems
        self.isLoopingEnabled = isLoopingEnabled
        normalizeSelection()
    }

    var normalizedSelection: ID? {
        guard let selection, itemIDs.contains(selection) else { return itemIDs.first }
        return selection
    }

    var currentIndex: Int? {
        guard let normalizedSelection else { return nil }
        return itemIDs.firstIndex(of: normalizedSelection)
    }

    /// 更新数据源并保留仍然存在的当前选中项，否则回落到第一条。
    mutating func applyItems(_ nextItemIDs: [ID], hasMoreItems: Bool) {
        itemIDs = nextItemIDs
        self.hasMoreItems = hasMoreItems
        normalizeSelection()
    }

    /// 显式选中指定页；无效 ID 会被规整到当前第一条。
    mutating func select(_ id: ID?) {
        selection = id
        normalizeSelection()
    }

    /// 按指定分页语义移动当前选中项。
    mutating func navigate(_ navigation: NoteReviewPagingNavigation) {
        switch navigation {
        case .next:
            selection = nextID()
        case .previous:
            selection = previousID()
        }
        normalizeSelection()
    }

    /// 返回当前选中项之后的下一条；仍有分页数据时不会从尾部循环到首条。
    func nextID() -> ID? {
        guard itemIDs.count > 1,
              let currentIndex,
              itemIDs.indices.contains(currentIndex)
        else { return nil }

        let nextIndex = itemIDs.index(after: currentIndex)
        if itemIDs.indices.contains(nextIndex) {
            return itemIDs[nextIndex]
        }
        return isLoopingEnabled && !hasMoreItems ? itemIDs.first : nil
    }

    /// 返回当前选中项之前的上一条；仍有分页数据时不会从首部循环到尾条。
    func previousID() -> ID? {
        guard itemIDs.count > 1,
              let currentIndex,
              itemIDs.indices.contains(currentIndex)
        else { return nil }

        if currentIndex != itemIDs.startIndex {
            return itemIDs[itemIDs.index(before: currentIndex)]
        }
        return isLoopingEnabled && !hasMoreItems ? itemIDs.last : nil
    }

    private mutating func normalizeSelection() {
        guard !itemIDs.isEmpty else {
            selection = nil
            return
        }
        if let selection, itemIDs.contains(selection) {
            return
        }
        selection = itemIDs.first
    }
}

/// 书摘回顾卡组单张卡内容层的可见度，背景纸面、边框与阴影不受它影响。
struct NoteReviewPagingCardContentVisibility: Equatable {
    let bodyOpacity: Double
    let footerOpacity: Double
    let edgeMaskProgress: Double
    let isReadable: Bool

    static let hidden = NoteReviewPagingCardContentVisibility(
        bodyOpacity: 0,
        footerOpacity: 0,
        edgeMaskProgress: 0,
        isReadable: false
    )
    static let preview = NoteReviewPagingCardContentVisibility(
        bodyOpacity: 1,
        footerOpacity: 1,
        edgeMaskProgress: 1,
        isReadable: false
    )
    static let readable = NoteReviewPagingCardContentVisibility(
        bodyOpacity: 1,
        footerOpacity: 1,
        edgeMaskProgress: 1,
        isReadable: true
    )

    var combinedOpacity: Double {
        max(bodyOpacity, footerOpacity)
    }
}

/// 书摘回顾卡组单张卡的可测试变换结果。
struct NoteReviewPagingCardTransform: Equatable {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let scale: CGFloat
    let rotationDegrees: Double
    let opacity: Double
    let contentVisibility: NoteReviewPagingCardContentVisibility

    var contentOpacity: Double {
        contentVisibility.combinedOpacity
    }
}

/// 书摘回顾后层卡片相对顶层卡片的几何露出量，用于保证露出的只是纸面边缘。
struct NoteReviewPagingStackExposure: Equatable {
    let sidePeek: CGFloat
    let bottomPeek: CGFloat
}

/// 书摘回顾卡组中单个视觉图层承担的职责。
enum NoteReviewPagingLayerRole: Hashable {
    case primary
    case sourceSupportProxy
}

/// 书摘回顾卡组的纯视觉图层计划，供 SwiftUI 层按稳定身份渲染。
struct NoteReviewPagingLayerPlan: Equatable {
    let pageIndex: Int
    let role: NoteReviewPagingLayerRole
    let transform: NoteReviewPagingCardTransform
    let zIndex: Double
    let allowsHitTesting: Bool
    let isAccessibilityHidden: Bool
}

/// 书摘回顾卡组的手势阈值与视觉动效规格。
struct NoteReviewPagingMotionSpec: Equatable {
    var commitDistanceRatio: CGFloat = 0.22
    var predictedCommitDistanceRatio: CGFloat = 0.32
    var horizontalLockMinimumDistance: CGFloat = 16
    var horizontalLockAxisBias: CGFloat = 1.15
    var maxRotationDegrees: Double = 5
    var depthRotationDegrees: Double = 0.35
    var settleDuration: TimeInterval = 0.25
    var resetDuration: TimeInterval = 0.20
    var scaleInterval: CGFloat = 0.98
    var verticalTranslationInterval: CGFloat = 3
    var horizontalPeekRatio: CGFloat = 0.025
    var swingOutMultiplier: CGFloat = 40
    var maximumRestingSidePeek: CGFloat = Spacing.comfortable - 4
    var maximumRestingBottomPeek: CGFloat = 4
    var fallbackStackHeight: CGFloat = 520
    var handoffProgress: CGFloat = 0.5
    var depthOpacityInterval: Double = 0.22
    var sourceContentFadeStartProgress: CGFloat = 0.5
    var sourceContentFadeEndProgress: CGFloat = 0.62
    var targetFooterRevealStartProgress: CGFloat = 0
    var targetFooterRevealEndProgress: CGFloat = 0.12
    var targetBodyRevealStartProgress: CGFloat = 0.62
    var targetBodyReadableProgress: CGFloat = 0.72
    var targetBodyPreviewMinimumOpacity: Double = 0.18
    var supportProxyFadeInEndProgress: CGFloat = 0.18

    static let iOSReviewDefault = NoteReviewPagingMotionSpec()

    /// 判断当前拖拽是否应被识别为横向卡片分页，避免抢走卡内纵向滚动。
    func shouldTrackHorizontalDrag(translation: CGSize) -> Bool {
        abs(translation.width) >= max(horizontalLockMinimumDistance, abs(translation.height) * horizontalLockAxisBias)
    }

    /// 根据实际与预测位移解析释放后的分页目标；左滑为 next，右滑为 previous。
    func navigation(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        containerWidth: CGFloat
    ) -> NoteReviewPagingNavigation? {
        guard containerWidth > 0, shouldTrackHorizontalDrag(translation: translation) else { return nil }

        let distanceThreshold = containerWidth * commitDistanceRatio
        let predictedThreshold = containerWidth * predictedCommitDistanceRatio
        let committedByDistance = abs(translation.width) >= distanceThreshold
        let committedByPrediction = abs(predictedEndTranslation.width) >= predictedThreshold
        guard committedByDistance || committedByPrediction else { return nil }

        let decisiveWidth = abs(predictedEndTranslation.width) > abs(translation.width)
            ? predictedEndTranslation.width
            : translation.width
        return decisiveWidth < 0 ? .next : .previous
    }

    /// 将横向手势位移转换为连续分页进度；左滑为正向 next，右滑为负向 previous。
    func progressOffset(translationWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        return max(-1, min(1, -translationWidth / containerWidth))
    }

    /// 返回当前卡组的连续进度索引；整数位是选中卡，浮点位是正在过渡的拖拽进度。
    func deckProgressIndex(
        sourceIndex: Int,
        visualProgress: CGFloat
    ) -> Double {
        Double(sourceIndex) + Double(visualProgress)
    }

    /// 返回指定页在连续轨道上的位置，0 表示顶层中心，正数在 previous 侧，负数在 next 侧。
    func cardPosition(
        pageIndex: Int,
        progressIndex: Double
    ) -> Double {
        progressIndex - Double(pageIndex)
    }

    /// 返回连续轨道下的层级；采用作者 CardStack 的半程换位语义，避免额外阈值造成硬切。
    func zIndex(
        position: Double,
        pageIndex: Int,
        progressIndex: Double,
        sourceIndex: Int
    ) -> Double {
        let localProgress = max(-1, min(1, progressIndex - Double(sourceIndex)))
        let baseZIndex = 100 - abs(position)
        guard localProgress != 0 else { return pageIndex == sourceIndex ? baseZIndex + 0.001 : baseZIndex }

        let direction = localProgress > 0 ? 1 : -1
        let targetIndex = sourceIndex + direction
        let absoluteProgress = CGFloat(abs(localProgress))
        if pageIndex == sourceIndex {
            return absoluteProgress < handoffProgress ? baseZIndex + 0.001 : baseZIndex
        }
        if pageIndex == targetIndex {
            return absoluteProgress >= handoffProgress ? baseZIndex + 0.001 : baseZIndex
        }
        return baseZIndex
    }

    /// 返回指定连续轨道位置的卡片变换，旧顶卡退回后层，新卡从后层补到顶层。
    func cardTransform(
        position: Double,
        progressIndex: Double,
        sourceIndex: Int,
        pageIndex: Int,
        pageCount: Int,
        containerWidth: CGFloat,
        containerHeight: CGFloat = 0,
        allowsSwingOut: Bool = true
    ) -> NoteReviewPagingCardTransform {
        let boundedPosition = max(-3, min(3, position))
        let distance = CGFloat(min(abs(boundedPosition), 3))
        let width = max(containerWidth, 1)
        let height = resolvedStackHeight(containerWidth: width, containerHeight: containerHeight)
        let baseOffsetX = (CGFloat(pageIndex) - CGFloat(progressIndex)) * width * horizontalPeekRatio
        let localProgress = max(-1, min(1, progressIndex - Double(sourceIndex)))
        let absoluteLocalProgress = CGFloat(abs(localProgress))
        let isOriginalTopCard = pageIndex == sourceIndex
        let canMoveForward = sourceIndex < pageCount - 1
        let canMoveBackward = sourceIndex > 0
        let canSwingOut = allowsSwingOut && isOriginalTopCard
        let isSwingingForward = canSwingOut && localProgress > 0 && canMoveForward
        let isSwingingBackward = canSwingOut && localProgress < 0 && canMoveBackward
        let shouldApplyAuthorSwing = isSwingingForward || isSwingingBackward
        let isActivelySwinging = shouldApplyAuthorSwing && absoluteLocalProgress < 0.995
        let swingWave = CGFloat(abs(sin(Double.pi * progressIndex)))
        let swingMultiplier = shouldApplyAuthorSwing ? max(1, swingWave * swingOutMultiplier) : 1
        let rawOffsetX = baseOffsetX * swingMultiplier
        let rotationStep = isActivelySwinging ? 2 : depthRotationDegrees
        let rawRotation = -boundedPosition * rotationStep
        let rawClampedRotation = max(-maxRotationDegrees, min(maxRotationDegrees, rawRotation))
        let scale = max(0.82, 1 - ((1 - scaleInterval) * distance))
        let rawOffsetY = distance * verticalTranslationInterval
        let constrainedStack = constrainedStackTransform(
            offsetX: rawOffsetX,
            offsetY: rawOffsetY,
            scale: scale,
            rotationDegrees: rawClampedRotation,
            containerWidth: width,
            containerHeight: height,
            isActivelySwinging: isActivelySwinging,
            distance: distance
        )
        let opacity = 1.0
        let contentVisibility = contentVisibility(
            localProgress: localProgress,
            sourceIndex: sourceIndex,
            pageIndex: pageIndex
        )

        return NoteReviewPagingCardTransform(
            offsetX: constrainedStack.offsetX,
            offsetY: constrainedStack.offsetY,
            scale: scale,
            rotationDegrees: constrainedStack.rotationDegrees,
            opacity: opacity,
            contentVisibility: contentVisibility
        )
    }

    /// 按旋转后的包围盒计算后层卡片会从顶层卡片四周露出的纸面范围。
    func stackExposure(
        transform: NoteReviewPagingCardTransform,
        containerWidth: CGFloat,
        containerHeight: CGFloat
    ) -> NoteReviewPagingStackExposure {
        stackExposure(
            offsetX: transform.offsetX,
            offsetY: transform.offsetY,
            scale: transform.scale,
            rotationDegrees: transform.rotationDegrees,
            containerWidth: max(containerWidth, 1),
            containerHeight: resolvedStackHeight(
                containerWidth: max(containerWidth, 1),
                containerHeight: containerHeight
            )
        )
    }

    /// 生成当前过渡帧需要渲染的视觉层；source 支撑层只保留纸面，不参与内容阅读。
    func layerPlans(
        pageCount: Int,
        sourceIndex: Int,
        progressIndex: Double,
        containerWidth: CGFloat,
        containerHeight: CGFloat = 0,
        isSupportProxyEnabled: Bool
    ) -> [NoteReviewPagingLayerPlan] {
        guard pageCount > 0, (0..<pageCount).contains(sourceIndex) else { return [] }

        let primaryPlans = (0..<pageCount).map { pageIndex in
            let position = cardPosition(pageIndex: pageIndex, progressIndex: progressIndex)
            let transform = cardTransform(
                position: position,
                progressIndex: progressIndex,
                sourceIndex: sourceIndex,
                pageIndex: pageIndex,
                pageCount: pageCount,
                containerWidth: containerWidth,
                containerHeight: containerHeight
            )
            return NoteReviewPagingLayerPlan(
                pageIndex: pageIndex,
                role: .primary,
                transform: transform,
                zIndex: zIndex(
                    position: position,
                    pageIndex: pageIndex,
                    progressIndex: progressIndex,
                    sourceIndex: sourceIndex
                ),
                allowsHitTesting: transform.contentVisibility.isReadable,
                isAccessibilityHidden: !transform.contentVisibility.isReadable
            )
        }

        guard let supportProxyPlan = sourceSupportProxyLayerPlan(
            pageCount: pageCount,
            sourceIndex: sourceIndex,
            progressIndex: progressIndex,
            containerWidth: containerWidth,
            containerHeight: containerHeight,
            isSupportProxyEnabled: isSupportProxyEnabled
        ) else {
            return primaryPlans
        }

        return primaryPlans + [supportProxyPlan]
    }

    private func contentVisibility(
        localProgress: Double,
        sourceIndex: Int,
        pageIndex: Int
    ) -> NoteReviewPagingCardContentVisibility {
        guard localProgress != 0 else {
            return pageIndex == sourceIndex ? .readable : .preview
        }

        let direction = localProgress > 0 ? 1 : -1
        let targetIndex = sourceIndex + direction
        let absoluteProgress = CGFloat(abs(localProgress))

        if pageIndex == sourceIndex {
            return NoteReviewPagingCardContentVisibility(
                bodyOpacity: 1,
                footerOpacity: 1,
                edgeMaskProgress: 1,
                isReadable: absoluteProgress < handoffProgress
            )
        }
        if pageIndex == targetIndex {
            let footerOpacity = progressPhase(
                absoluteProgress,
                start: targetFooterRevealStartProgress,
                end: targetFooterRevealEndProgress
            )
            let bodyPhase = progressPhase(
                absoluteProgress,
                start: targetBodyRevealStartProgress,
                end: targetBodyReadableProgress
            )
            let bodyOpacity = max(targetBodyPreviewMinimumOpacity, bodyPhase)
            return NoteReviewPagingCardContentVisibility(
                bodyOpacity: bodyOpacity,
                footerOpacity: max(targetBodyPreviewMinimumOpacity, footerOpacity),
                edgeMaskProgress: 1,
                isReadable: absoluteProgress >= targetBodyReadableProgress
            )
        }
        return .preview
    }

    private func progressPhase(
        _ progress: CGFloat,
        start: CGFloat,
        end: CGFloat
    ) -> Double {
        let clampedStart = max(0, min(0.99, start))
        let clampedEnd = max(clampedStart + 0.001, min(1, end))
        return Double(max(0, min(1, (progress - clampedStart) / (clampedEnd - clampedStart))))
    }

    private func sourceSupportProxyLayerPlan(
        pageCount: Int,
        sourceIndex: Int,
        progressIndex: Double,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        isSupportProxyEnabled: Bool
    ) -> NoteReviewPagingLayerPlan? {
        guard isSupportProxyEnabled else { return nil }

        let localProgress = max(-1, min(1, progressIndex - Double(sourceIndex)))
        let absoluteProgress = CGFloat(abs(localProgress))
        guard absoluteProgress > 0.001, absoluteProgress < 0.995 else { return nil }

        let targetIndex = sourceIndex + (localProgress > 0 ? 1 : -1)
        guard (0..<pageCount).contains(targetIndex) else { return nil }

        let position = cardPosition(pageIndex: sourceIndex, progressIndex: progressIndex)
        let deckTrackTransform = cardTransform(
            position: position,
            progressIndex: progressIndex,
            sourceIndex: sourceIndex,
            pageIndex: sourceIndex,
            pageCount: pageCount,
            containerWidth: containerWidth,
            containerHeight: containerHeight,
            allowsSwingOut: false
        )
        let fadeProgress = min(1, absoluteProgress / max(supportProxyFadeInEndProgress, 0.001))
        let supportTransform = NoteReviewPagingCardTransform(
            offsetX: deckTrackTransform.offsetX,
            offsetY: deckTrackTransform.offsetY,
            scale: deckTrackTransform.scale,
            rotationDegrees: deckTrackTransform.rotationDegrees,
            opacity: deckTrackTransform.opacity * Double(fadeProgress),
            contentVisibility: .preview
        )

        return NoteReviewPagingLayerPlan(
            pageIndex: sourceIndex,
            role: .sourceSupportProxy,
            transform: supportTransform,
            zIndex: supportProxyZIndex(localProgress: localProgress),
            allowsHitTesting: false,
            isAccessibilityHidden: true
        )
    }

    private func supportProxyZIndex(localProgress: Double) -> Double {
        98.9 - min(abs(localProgress), 1) * 0.1
    }

    /// 根据 Reduce Motion 偏好压低位移与旋转，保留状态反馈。
    func applyingReduceMotion(_ isReduceMotionEnabled: Bool) -> NoteReviewPagingMotionSpec {
        guard isReduceMotionEnabled else { return self }
        var copy = self
        copy.maxRotationDegrees = 0
        copy.depthRotationDegrees = 0
        copy.settleDuration = 0.08
        copy.resetDuration = 0.08
        copy.scaleInterval = 1
        copy.verticalTranslationInterval = 0
        copy.horizontalPeekRatio = 0.02
        copy.swingOutMultiplier = 0
        copy.handoffProgress = 0
        copy.depthOpacityInterval = 0.08
        copy.sourceContentFadeStartProgress = 0.12
        copy.sourceContentFadeEndProgress = 0.24
        copy.targetFooterRevealStartProgress = 0
        copy.targetFooterRevealEndProgress = 0.08
        copy.targetBodyRevealStartProgress = 0.06
        copy.targetBodyReadableProgress = 0.24
        copy.targetBodyPreviewMinimumOpacity = 0.24
        copy.supportProxyFadeInEndProgress = 0.08
        return copy
    }

    private func constrainedStackTransform(
        offsetX: CGFloat,
        offsetY: CGFloat,
        scale: CGFloat,
        rotationDegrees: Double,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        isActivelySwinging: Bool,
        distance: CGFloat
    ) -> (offsetX: CGFloat, offsetY: CGFloat, rotationDegrees: Double) {
        guard distance > 0, !isActivelySwinging else {
            return (offsetX, offsetY, rotationDegrees)
        }

        let rotation = reducedStackRotationIfNeeded(
            offsetX: offsetX,
            offsetY: offsetY,
            scale: scale,
            rotationDegrees: rotationDegrees,
            containerWidth: containerWidth,
            containerHeight: containerHeight
        )
        let rotatedSize = rotatedStackSize(
            scale: scale,
            rotationDegrees: rotation,
            containerWidth: containerWidth,
            containerHeight: containerHeight
        )
        let maximumOffsetX = max(0, containerWidth / 2 + maximumRestingSidePeek - rotatedSize.width / 2)
        let maximumOffsetY = max(0, containerHeight / 2 + maximumRestingBottomPeek - rotatedSize.height / 2)

        return (
            offsetX.clampedMagnitude(to: maximumOffsetX),
            offsetY.clampedMagnitude(to: maximumOffsetY),
            rotation
        )
    }

    private func reducedStackRotationIfNeeded(
        offsetX: CGFloat,
        offsetY: CGFloat,
        scale: CGFloat,
        rotationDegrees: Double,
        containerWidth: CGFloat,
        containerHeight: CGFloat
    ) -> Double {
        let exposure = stackExposure(
            offsetX: offsetX,
            offsetY: offsetY,
            scale: scale,
            rotationDegrees: rotationDegrees,
            containerWidth: containerWidth,
            containerHeight: containerHeight
        )
        guard exposure.sidePeek > maximumRestingSidePeek || exposure.bottomPeek > maximumRestingBottomPeek else {
            return rotationDegrees
        }

        let sign = rotationDegrees < 0 ? -1.0 : 1.0
        var candidate = abs(rotationDegrees)
        for _ in 0..<12 {
            candidate *= 0.5
            let signedCandidate = candidate * sign
            let candidateExposure = stackExposure(
                offsetX: offsetX,
                offsetY: offsetY,
                scale: scale,
                rotationDegrees: signedCandidate,
                containerWidth: containerWidth,
                containerHeight: containerHeight
            )
            if candidateExposure.sidePeek <= maximumRestingSidePeek,
               candidateExposure.bottomPeek <= maximumRestingBottomPeek {
                return signedCandidate
            }
        }
        return 0
    }

    private func stackExposure(
        offsetX: CGFloat,
        offsetY: CGFloat,
        scale: CGFloat,
        rotationDegrees: Double,
        containerWidth: CGFloat,
        containerHeight: CGFloat
    ) -> NoteReviewPagingStackExposure {
        let rotatedSize = rotatedStackSize(
            scale: scale,
            rotationDegrees: rotationDegrees,
            containerWidth: containerWidth,
            containerHeight: containerHeight
        )
        return NoteReviewPagingStackExposure(
            sidePeek: max(0, abs(offsetX) + rotatedSize.width / 2 - containerWidth / 2),
            bottomPeek: max(0, offsetY + rotatedSize.height / 2 - containerHeight / 2)
        )
    }

    private func rotatedStackSize(
        scale: CGFloat,
        rotationDegrees: Double,
        containerWidth: CGFloat,
        containerHeight: CGFloat
    ) -> CGSize {
        let radians = CGFloat(abs(rotationDegrees) * .pi / 180)
        let scaledWidth = containerWidth * scale
        let scaledHeight = containerHeight * scale
        return CGSize(
            width: scaledWidth * cos(radians) + scaledHeight * sin(radians),
            height: scaledWidth * sin(radians) + scaledHeight * cos(radians)
        )
    }

    private func resolvedStackHeight(containerWidth: CGFloat, containerHeight: CGFloat) -> CGFloat {
        guard containerHeight > 0 else { return max(fallbackStackHeight, containerWidth) }
        return max(containerHeight, 1)
    }
}

private extension CGFloat {
    func clampedMagnitude(to maximumMagnitude: CGFloat) -> CGFloat {
        guard maximumMagnitude >= 0 else { return 0 }
        if self > maximumMagnitude { return maximumMagnitude }
        if self < -maximumMagnitude { return -maximumMagnitude }
        return self
    }
}

extension EnvironmentValues {
    /// 当前回顾卡片内容层可见度，背景纸面与阴影不受影响。
    @Entry var noteReviewPagingCardContentVisibility: NoteReviewPagingCardContentVisibility = .readable
}

/// 书摘回顾卡组的页面布局规格，用于约束主卡与后卡的可见安全边距。
struct NoteReviewPagingLayoutSpec: Equatable {
    var maxDeckWidth: CGFloat = 430
    var cardHorizontalPadding: CGFloat = Spacing.base
    var cardInsets = EdgeInsets(
        top: Spacing.base,
        leading: Spacing.base,
        bottom: Spacing.screenEdge,
        trailing: Spacing.base
    )
    var minimumRestingStackSideMargin: CGFloat = Spacing.screenEdge

    static let iOSReviewDefault = NoteReviewPagingLayoutSpec()

    /// 返回当前可用宽度下卡组外框的实际宽度。
    func resolvedDeckWidth(for availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 0 }
        return min(availableWidth, maxDeckWidth)
    }

    /// 返回参与 PageView 手势、露出与阈值计算的页面宽度。
    func pagingWidth(for availableWidth: CGFloat) -> CGFloat {
        max(resolvedDeckWidth(for: availableWidth) - cardInsets.leading - cardInsets.trailing, 0)
    }

    /// 返回顶层主卡与屏幕侧边之间的静止态距离。
    func topCardSideMargin(availableWidth: CGFloat) -> CGFloat {
        let deckWidth = resolvedDeckWidth(for: availableWidth)
        return centeredDeckMargin(availableWidth: availableWidth, deckWidth: deckWidth) + cardInsets.leading + cardHorizontalPadding
    }

    /// 返回后卡按默认露出位移偏移后，与屏幕侧边之间剩余的静止态距离。
    func restingStackSideMargin(
        availableWidth: CGFloat,
        motionSpec: NoteReviewPagingMotionSpec
    ) -> CGFloat {
        let deckWidth = resolvedDeckWidth(for: availableWidth)
        let pageWidth = pagingWidth(for: availableWidth)
        guard pageWidth > 0 else { return 0 }

        let transform = motionSpec.cardTransform(
            position: motionSpec.cardPosition(pageIndex: 1, progressIndex: 0),
            progressIndex: 0,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: pageWidth,
            containerHeight: motionSpec.fallbackStackHeight
        )
        let scaledCardEdgeInset = pageWidth * (1 - transform.scale) / 2 + cardHorizontalPadding * transform.scale
        return centeredDeckMargin(availableWidth: availableWidth, deckWidth: deckWidth)
            + cardInsets.leading
            + scaledCardEdgeInset
            - abs(transform.offsetX)
    }

    private func centeredDeckMargin(availableWidth: CGFloat, deckWidth: CGFloat) -> CGFloat {
        max((availableWidth - deckWidth) / 2, 0)
    }
}

/// 书摘回顾卡组手势的轴向锁定状态，避免纵向滚动中途触发横向卡片跳动。
enum NoteReviewPagingDragAxisLock: Equatable {
    case undecided
    case horizontal
    case vertical
}

/// 将 DragGesture 的原始位移转换为稳定的横向分页位移。
struct NoteReviewPagingDragTracker: Equatable {
    private(set) var axisLock = NoteReviewPagingDragAxisLock.undecided
    private(set) var effectiveTranslation = CGSize.zero
    private var lockTranslation = CGSize.zero

    /// 根据最新拖拽位移更新轴向锁定；横向锁定首帧从零开始，避免晚锁定时卡片突然跳动。
    mutating func update(
        translation: CGSize,
        motionSpec: NoteReviewPagingMotionSpec
    ) -> CGSize? {
        switch axisLock {
        case .undecided:
            if motionSpec.shouldTrackHorizontalDrag(translation: translation) {
                axisLock = .horizontal
                lockTranslation = translation
                effectiveTranslation = .zero
                return effectiveTranslation
            }

            let minimumDistance = motionSpec.horizontalLockMinimumDistance
            let verticalDistance = abs(translation.height)
            let horizontalDistance = abs(translation.width)
            if verticalDistance >= minimumDistance,
               verticalDistance > horizontalDistance * motionSpec.horizontalLockAxisBias {
                axisLock = .vertical
            }
            return nil

        case .horizontal:
            effectiveTranslation = CGSize(
                width: translation.width - lockTranslation.width,
                height: translation.height - lockTranslation.height
            )
            return effectiveTranslation

        case .vertical:
            return nil
        }
    }

    /// 将预测终点同步转换到横向锁定后的坐标系。
    func effectivePredictedEndTranslation(_ predictedEndTranslation: CGSize) -> CGSize {
        guard axisLock == .horizontal else { return .zero }
        return CGSize(
            width: predictedEndTranslation.width - lockTranslation.width,
            height: predictedEndTranslation.height - lockTranslation.height
        )
    }

    mutating func reset() {
        axisLock = .undecided
        lockTranslation = .zero
        effectiveTranslation = .zero
    }
}

/// 延迟提交 selection 的轻量状态，保证离场动画完成前当前卡片身份保持稳定。
struct NoteReviewPagingSelectionTransition<Value: Hashable>: Equatable {
    private(set) var visibleSelection: Value
    private(set) var pendingSelection: Value?

    var isSettling: Bool {
        pendingSelection != nil
    }

    init(selection: Value) {
        visibleSelection = selection
    }

    mutating func syncExternalSelection(_ selection: Value) {
        guard !isSettling else { return }
        visibleSelection = selection
    }

    mutating func beginSettle(to destination: Value) {
        pendingSelection = destination
    }

    mutating func completeSettle() -> Value? {
        guard let pendingSelection else { return nil }
        visibleSelection = pendingSelection
        self.pendingSelection = nil
        return visibleSelection
    }

    mutating func cancelSettle() {
        pendingSelection = nil
    }
}

/// 单次拖拽/提交期间冻结的视觉会话，避免动画中途切换卡片身份。
struct NoteReviewPagingVisualSession<Value: Hashable>: Equatable {
    private(set) var sourceSelection: Value
    private(set) var destination: Value?
    private(set) var sourceIndex: Int
    private(set) var targetIndex: Int?
    private(set) var direction: NoteReviewPagingNavigation?
    private(set) var visualProgress: CGFloat
    private(set) var completedSelection: Value?
    private(set) var isCommitting: Bool

    init(sourceSelection: Value, sourceIndex: Int) {
        self.sourceSelection = sourceSelection
        self.sourceIndex = sourceIndex
        destination = nil
        targetIndex = nil
        direction = nil
        visualProgress = 0
        completedSelection = nil
        isCommitting = false
    }

    var progressIndex: Double {
        Double(sourceIndex) + Double(visualProgress)
    }

    mutating func updateDragProgress(_ progress: CGFloat) {
        guard !isCommitting else { return }
        visualProgress = max(-1, min(1, progress))
    }

    mutating func beginCommit(
        to destination: Value,
        targetIndex: Int,
        direction: NoteReviewPagingNavigation
    ) {
        self.destination = destination
        self.targetIndex = targetIndex
        self.direction = direction
        completedSelection = nil
        isCommitting = true
    }

    mutating func animateToCommitBoundary() {
        guard let direction else { return }
        visualProgress = direction.visualProgressSign
    }

    mutating func completeCommit() -> Value? {
        guard isCommitting, let destination else { return nil }
        completedSelection = destination
        return destination
    }

    mutating func cancel() {
        destination = nil
        targetIndex = nil
        direction = nil
        visualProgress = 0
        completedSelection = nil
        isCommitting = false
    }
}

/// 书摘回顾自定义分页卡组的业务配置。
struct NoteReviewPagingDeckConfiguration: Equatable {
    var visibleCount = 3
    var preloadDistance = 6
    var isLoopingEnabled = true
    var isSwipeEnabled = true
    var isTapEnabled = true
    var motionSpec = NoteReviewPagingMotionSpec.iOSReviewDefault
    var cardInsets = EdgeInsets()

    static let iOSReviewDefault = NoteReviewPagingDeckConfiguration()
}
