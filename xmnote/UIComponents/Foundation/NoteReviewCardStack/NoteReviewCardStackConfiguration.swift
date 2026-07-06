/**
 * [INPUT]: 依赖 UIKit 基础类型与 vendored Shuffle 方向类型，承接 Android 书摘回顾卡堆参数基线
 * [OUTPUT]: 对外提供 NoteReviewCardStackDirection 与 NoteReviewCardStackConfiguration
 * [POS]: NoteReviewCardStack 的配置入口，隔离业务层与底层 UIKit 卡堆实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 书摘回顾卡堆支持的滑动方向；当前四个方向都表示翻到下一条。
enum NoteReviewCardStackDirection: String, CaseIterable, Identifiable, Hashable {
    case left
    case right
    case up
    case down

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left:
            return "左"
        case .right:
            return "右"
        case .up:
            return "上"
        case .down:
            return "下"
        }
    }

    var vendorDirection: XMNoteReviewSwipeDirection {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        case .up:
            return .up
        case .down:
            return .down
        }
    }

    init(vendorDirection: XMNoteReviewSwipeDirection) {
        switch vendorDirection {
        case .left:
            self = .left
        case .right:
            self = .right
        case .up:
            self = .up
        case .down:
            self = .down
        }
    }
}

/// 书摘回顾卡堆配置；提供 iOS 克制动效默认值，并保留 Android CardStackView 参数对照。
struct NoteReviewCardStackConfiguration: Equatable {
    var visibleCount = 3
    var scaleInterval: CGFloat = 0.95
    var translationInterval: CGFloat = 0
    var swipeThreshold: CGFloat = 0.2
    var minimumSwipeSpeed: CGFloat = 900
    var maxRotationDegrees: CGFloat = 10
    var resetSpringDamping: CGFloat = 0.5 {
        didSet {
            resetSpringDamping = max(0, min(resetSpringDamping, 1))
        }
    }
    var allowedDirections = Set(NoteReviewCardStackDirection.allCases)
    var isLoopingEnabled = true
    var isSwipeEnabled = true
    var isTapEnabled = true
    var prefersEmbeddedVerticalScroll = true
    var preloadDistance = 6
    var cardInsets = UIEdgeInsets.zero
    var swipeAnimationDuration: TimeInterval = 0.32
    var resetAnimationDuration: TimeInterval = 0.28
    var undoAnimationDuration: TimeInterval = 0.24
    var stackAnimationDuration: TimeInterval = 0.16
    var showsDirectionOverlay = false

    static let androidReviewDefault = NoteReviewCardStackConfiguration()
    static let iOSReviewDefault: NoteReviewCardStackConfiguration = {
        var configuration = NoteReviewCardStackConfiguration()
        configuration.maxRotationDegrees = 8
        configuration.resetAnimationDuration = 0.36
        configuration.resetSpringDamping = 0.88
        return configuration
    }()

    var maxRotationRadians: CGFloat {
        maxRotationDegrees * .pi / 180
    }

    var sortedVendorDirections: [XMNoteReviewSwipeDirection] {
        NoteReviewCardStackDirection.allCases
            .filter { allowedDirections.contains($0) }
            .map(\.vendorDirection)
    }

    /// 根据系统 Reduce Motion 偏好生成低运动版本，保留状态变化但缩短位移动效。
    func applyingReduceMotion(_ isReduceMotionEnabled: Bool) -> NoteReviewCardStackConfiguration {
        guard isReduceMotionEnabled else { return self }
        var copy = self
        copy.maxRotationDegrees = 0
        copy.resetSpringDamping = 1
        copy.translationInterval = 0
        copy.swipeAnimationDuration = 0.01
        copy.resetAnimationDuration = 0.01
        copy.undoAnimationDuration = 0.01
        copy.stackAnimationDuration = 0.01
        copy.showsDirectionOverlay = false
        return copy
    }
}
