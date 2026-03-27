/**
 * [INPUT]: 依赖 SwiftUI 安全区扩展能力与 DesignTokens 颜色、间距令牌
 * [OUTPUT]: 对外提供 ImmersiveBottomChromeMetrics、ImmersiveBottomChromeOverlay 与 ImmersiveBottomChromeIcon，承接查看页底部沉浸渐变与悬浮 chrome
 * [POS]: UIComponents/Foundation 的沉浸式底部表层组件，被书摘查看与通用内容查看复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 沉浸式底部 chrome 的公共尺寸常量，统一控制可视高度与命中目标。
enum ImmersiveBottomChromeStyle {
    static let controlHeight: CGFloat = 50
    static let minimumHitTarget: CGFloat = 44
    static let iconSize: CGFloat = 16
    static let ornamentTopPadding: CGFloat = 6
    static let minimumBottomPadding: CGFloat = 16
}

/// 底部沉浸 chrome 的滚动补偿与视觉尺寸快照。
struct ImmersiveBottomChromeMetrics: Equatable {
    let readableInset: CGFloat
    let scrollIndicatorInset: CGFloat
    let gradientHeight: CGFloat
    let bottomPadding: CGFloat

    /// 根据实测 ornament 高度与底部安全区计算正文可读留白、滚动条避让和渐变高度。
    static func make(
        measuredOrnamentHeight: CGFloat,
        safeAreaBottomInset: CGFloat,
        ornamentMinimumTouchHeight: CGFloat = ImmersiveBottomChromeStyle.controlHeight,
        ornamentTopPadding: CGFloat = ImmersiveBottomChromeStyle.ornamentTopPadding,
        minimumBottomPadding: CGFloat = ImmersiveBottomChromeStyle.minimumBottomPadding,
        readableInsetExtra: CGFloat = Spacing.base,
        scrollIndicatorInsetCompensation: CGFloat = Spacing.cozy,
        gradientMinimumHeight: CGFloat = 120,
        gradientExtraHeight: CGFloat = Spacing.section
    ) -> Self {
        let bottomPadding = max(safeAreaBottomInset, minimumBottomPadding)
        let estimatedOrnamentHeight = ornamentTopPadding + ornamentMinimumTouchHeight + bottomPadding
        let resolvedOrnamentHeight = max(measuredOrnamentHeight, estimatedOrnamentHeight)

        return Self(
            readableInset: resolvedOrnamentHeight + readableInsetExtra,
            scrollIndicatorInset: max(minimumBottomPadding, resolvedOrnamentHeight - scrollIndicatorInsetCompensation),
            gradientHeight: max(gradientMinimumHeight, resolvedOrnamentHeight + gradientExtraHeight),
            bottomPadding: bottomPadding
        )
    }
}

/// 通用底部沉浸 overlay，统一承接渐变托底与悬浮 ornament 的安全区延展。
struct ImmersiveBottomChromeOverlay<Ornament: View>: View {
    let metrics: ImmersiveBottomChromeMetrics
    var surfaceColor: Color = .surfacePage
    var horizontalPadding: CGFloat = Spacing.screenEdge
    var ornamentTopPadding: CGFloat = ImmersiveBottomChromeStyle.ornamentTopPadding
    @ViewBuilder let ornament: Ornament

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    surfaceColor.opacity(0),
                    surfaceColor.opacity(0.82),
                    surfaceColor
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity)
            .frame(height: metrics.gradientHeight)
            .allowsHitTesting(false)

            HStack {
                Spacer(minLength: 0)
                ornament
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, ornamentTopPadding)
            .padding(.bottom, metrics.bottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 沉浸式底部 ornament 的统一图标尺寸与点击热区。
struct ImmersiveBottomChromeIcon: View {
    let systemName: String
    var foregroundStyle: Color = .textPrimary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: ImmersiveBottomChromeStyle.iconSize, weight: .semibold))
            .foregroundStyle(foregroundStyle)
            .frame(
                width: ImmersiveBottomChromeStyle.minimumHitTarget,
                height: ImmersiveBottomChromeStyle.minimumHitTarget
            )
            .contentShape(Circle())
    }
}

/// 底部 ornament 高度偏好键，供页面将测量值回写到滚动补偿计算。
struct ImmersiveBottomChromeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// 封装reduce对应的业务步骤，确保调用方可以稳定复用该能力。
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
