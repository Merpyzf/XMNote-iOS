/**
 * [INPUT]: 依赖 UIKit 命中测试、InteractionMetrics 的最小触控目标与共享 XMMinimumHitTargetAnchor
 * [OUTPUT]: 对外提供不改变视觉 bounds 与约束的 XMMinimumHitTargetButton
 * [POS]: UIComponents/Controls/Button 的 UIKit 内部交互基础设施，供紧凑视觉按钮扩展至少 44pt 命中区
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 在不改变按钮视觉尺寸与 Auto Layout 占位的前提下，把命中范围扩展到设计系统最小触控目标。
final class XMMinimumHitTargetButton: UIButton {
    /// 保留既有 UIKit 调用名，并与 SwiftUI 命中区基础设施共享同一锚点语义。
    typealias HitTargetAnchor = XMMinimumHitTargetAnchor

    var minimumHitTargetSize = CGSize(
        width: InteractionMetrics.minimumTouchTarget,
        height: InteractionMetrics.minimumTouchTarget
    )
    var hitTargetAnchor: HitTargetAnchor = .center

    var canParticipateInHitTesting: Bool {
        isEnabled && !isHidden && alpha > 0.01 && isUserInteractionEnabled
    }

    /// 返回至少满足最小触控尺寸的命中矩形；按钮自身 bounds 保持不变。
    var expandedHitBounds: CGRect {
        let horizontalExpansion = max(minimumHitTargetSize.width - bounds.width, 0)
        let verticalExpansion = max(minimumHitTargetSize.height - bounds.height, 0)
        let horizontalOutsets = resolvedHorizontalOutsets(total: horizontalExpansion)
        let verticalOutsets = resolvedVerticalOutsets(total: verticalExpansion)

        return CGRect(
            x: bounds.minX - horizontalOutsets.leading,
            y: bounds.minY - verticalOutsets.top,
            width: bounds.width + horizontalExpansion,
            height: bounds.height + verticalExpansion
        )
    }

    /// 把扩展后的命中范围转换到宿主坐标系，供手势保护区与调试验证复用。
    func expandedHitFrame(in view: UIView) -> CGRect {
        convert(expandedHitBounds, to: view)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard canParticipateInHitTesting else { return false }
        return expandedHitBounds.contains(point)
    }

    private func resolvedHorizontalOutsets(total: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        switch hitTargetAnchor {
        case .center:
            return (total / 2, total / 2)
        case .top, .bottom:
            return (total / 2, total / 2)
        case .leading:
            return isRightToLeft ? (total, 0) : (0, total)
        case .trailing:
            return isRightToLeft ? (0, total) : (total, 0)
        case .topLeading, .bottomLeading:
            return isRightToLeft ? (total, 0) : (0, total)
        case .topTrailing, .bottomTrailing:
            return isRightToLeft ? (0, total) : (total, 0)
        }
    }

    private func resolvedVerticalOutsets(total: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        switch hitTargetAnchor {
        case .center:
            return (total / 2, total / 2)
        case .leading, .trailing:
            return (total / 2, total / 2)
        case .top:
            return (0, total)
        case .bottom:
            return (total, 0)
        case .topLeading, .topTrailing:
            return (0, total)
        case .bottomLeading, .bottomTrailing:
            return (total, 0)
        }
    }
}
