/**
 * [INPUT]: 依赖 SwiftUI 文本排版、Dynamic Type、Reduce Motion 与 DesignTokens 间距/颜色语义
 * [OUTPUT]: 对外提供 XMMarqueeText 与 XMMarqueeTextStyle，统一单行溢出文本的无缝连续跑马灯能力
 * [POS]: UIComponents/Foundation 的跨模块文本基础组件，供需要保留完整单行文本语义的紧凑标题场景复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 跑马灯文本的节奏规格；业务层只配置速度、间距、首次停留与边缘渐隐。
struct XMMarqueeTextStyle: Equatable {
    static let standard = XMMarqueeTextStyle(
        pointsPerSecond: 24,
        gap: 32,
        initialDelay: 1.2,
        edgeFadeWidth: Spacing.base
    )

    let pointsPerSecond: CGFloat
    let gap: CGFloat
    let initialDelay: TimeInterval
    let edgeFadeWidth: CGFloat

    /// 构建跑马灯节奏规格；无效负值会在初始化时收敛到安全下限。
    init(
        pointsPerSecond: CGFloat,
        gap: CGFloat,
        initialDelay: TimeInterval,
        edgeFadeWidth: CGFloat
    ) {
        self.pointsPerSecond = max(pointsPerSecond, 1)
        self.gap = max(gap, Spacing.cozy)
        self.initialDelay = max(initialDelay, 0)
        self.edgeFadeWidth = max(edgeFadeWidth, 0)
    }
}

/// 单行文本基础组件：静止时尾部省略，溢出时以时间相位闭环连续滚动。
struct XMMarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let lineHeight: CGFloat
    let style: XMMarqueeTextStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var renderedTextWidth: CGFloat = 0
    @State private var lastContainerWidth: CGFloat = 0
    @State private var animationStartDate = Date()
    @State private var wasOverflowing = false

    /// 构建文本跑马灯；字体、颜色和行高由调用场景的排版令牌提供。
    init(
        _ text: String,
        font: Font,
        color: Color = .textPrimary,
        lineHeight: CGFloat,
        style: XMMarqueeTextStyle = .standard
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.lineHeight = max(lineHeight, 0)
        self.style = style
    }

    var body: some View {
        GeometryReader { proxy in
            let containerWidth = max(proxy.size.width, 0)
            let tolerance = halfPhysicalPixel
            let shouldScroll = !reduceMotion
                && renderedTextWidth > containerWidth + tolerance

            Group {
                if shouldScroll {
                    scrollingText(
                        textWidth: renderedTextWidth,
                        containerWidth: containerWidth
                    )
                } else {
                    staticText(containerWidth: containerWidth)
                }
            }
            .clipped()
            .overlay(alignment: .leading) {
                measurementText
            }
            .onChange(of: text) {
                restartInitialDelay()
            }
            .onChange(of: style) {
                restartInitialDelay()
            }
            .onChange(of: lineHeight) {
                restartInitialDelay()
            }
            .onChange(of: containerWidth, initial: true) { _, newWidth in
                let hadMeasuredContainer = lastContainerWidth > 0
                guard newWidth > 0,
                      abs(newWidth - lastContainerWidth) >= halfPhysicalPixel else { return }
                lastContainerWidth = newWidth
                if hadMeasuredContainer {
                    restartInitialDelay()
                }
            }
            .onChange(of: shouldScroll, initial: true) { _, isOverflowing in
                if isOverflowing && !wasOverflowing {
                    restartInitialDelay()
                }
                wasOverflowing = isOverflowing
            }
        }
        .frame(height: lineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// 只在溢出路径建立动画时间线，使用固定节距的三个文本副本形成闭环。
    private func scrollingText(textWidth: CGFloat, containerWidth: CGFloat) -> some View {
        let edgeWidth = min(style.edgeFadeWidth, max(containerWidth / 4, 0))
        let gap = resolvedGap(for: containerWidth)
        let pitch = textWidth + gap

        return TimelineView(.animation) { context in
            let elapsed = max(
                context.date.timeIntervalSince(animationStartDate) - style.initialDelay,
                0
            )
            let travelledDistance = CGFloat(elapsed) * style.pointsPerSecond
            let phase = travelledDistance.truncatingRemainder(dividingBy: pitch)
            let directionalPhase = layoutDirection == .rightToLeft ? phase : -phase

            HStack(spacing: gap) {
                renderedText
                    .fixedSize(horizontal: true, vertical: false)
                renderedText
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
                renderedText
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: directionalPhase)
            .frame(width: containerWidth, height: lineHeight, alignment: .leading)
            .clipped()
            .mask {
                marqueeMask(edgeWidth: edgeWidth, isMoving: elapsed > 0)
            }
        }
    }

    /// Reduce Motion 或未溢出时保持系统单行尾部截断，不创建时间刷新。
    private func staticText(containerWidth: CGFloat) -> some View {
        renderedText
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: containerWidth, alignment: .leading)
    }

    /// 普通视窗使用样式间距；极窄视窗把间距限制到视窗四分之一且不低于 8pt。
    private func resolvedGap(for containerWidth: CGFloat) -> CGFloat {
        min(style.gap, max(Spacing.cozy, containerWidth * 0.25))
    }

    /// 首次停留只渐隐语义尾部；移动后固定渐隐两侧，周期换相不改变遮罩。
    private func marqueeMask(edgeWidth: CGFloat, isMoving: Bool) -> some View {
        let fadesLeftEdge = isMoving || layoutDirection == .rightToLeft
        let fadesRightEdge = isMoving || layoutDirection == .leftToRight

        return HStack(spacing: Spacing.none) {
            Group {
                if fadesLeftEdge {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .frame(width: edgeWidth)

            Color.black

            Group {
                if fadesRightEdge {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .frame(width: edgeWidth)
        }
    }

    private var renderedText: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }

    /// 通过不可见的同源 SwiftUI 文本读取真实排版宽度，跨过半个物理像素才写入状态。
    private var measurementText: some View {
        let scale = max(displayScale, 1)
        return renderedText
            .fixedSize(horizontal: true, vertical: false)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { geometry in
                xmMarqueePixelAligned(geometry.size.width, scale: scale)
            } action: { newWidth in
                guard newWidth > 0,
                      abs(newWidth - renderedTextWidth) >= halfPhysicalPixel else { return }
                renderedTextWidth = newWidth
                restartInitialDelay()
            }
    }

    private var halfPhysicalPixel: CGFloat {
        0.5 / max(displayScale, 1)
    }

    /// 为新的文本或真实布局边界重新建立一次首次停留，不参与正常循环换相。
    private func restartInitialDelay() {
        animationStartDate = Date()
    }
}

/// 将测量结果吸附到最近物理像素，屏蔽亚像素抖动造成的重复相位重置。
private func xmMarqueePixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    guard value.isFinite, scale.isFinite, scale > 0 else { return value }
    return (value * scale).rounded() / scale
}
