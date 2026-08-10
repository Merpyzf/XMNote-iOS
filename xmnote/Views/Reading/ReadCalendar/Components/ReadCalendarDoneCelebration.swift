/**
 * [INPUT]: 依赖 ReadCalendarDoneMarkerStyle、ReadCalendarEventRGBA、ReadCalendarHaptics 与 DesignTokens 视觉令牌
 * [OUTPUT]: 对外提供阅读日历页面私有的读完标识按钮与可复用庆祝动效容器
 * [POS]: ReadCalendar 页面私有动效组件，统一月历事件条与封面全屏浮层的读完反馈
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 为任意读完标识附加缩放、上浮、摆动、光晕与粒子反馈，并在减少动态效果时回退为静态内容。
struct ReadCalendarDoneCelebrationEffect<Content: View>: View {
    let trigger: Int
    let badgeSize: CGFloat
    let maximumRotation: CGFloat
    let eventBackground: ReadCalendarEventRGBA
    let eventText: ReadCalendarEventRGBA
    let badgeBackground: ReadCalendarEventRGBA
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    /// 注入标识本体与调色参数，构建不改变外部布局尺寸的庆祝效果。
    init(
        trigger: Int,
        badgeSize: CGFloat,
        maximumRotation: CGFloat,
        eventBackground: ReadCalendarEventRGBA,
        eventText: ReadCalendarEventRGBA,
        badgeBackground: ReadCalendarEventRGBA,
        @ViewBuilder content: () -> Content
    ) {
        self.trigger = trigger
        self.badgeSize = badgeSize
        self.maximumRotation = maximumRotation
        self.eventBackground = eventBackground
        self.eventText = eventText
        self.badgeBackground = badgeBackground
        self.content = content()
    }

    var body: some View {
        if accessibilityReduceMotion {
            content
        } else {
            content
                .keyframeAnimator(
                    initialValue: CGFloat(1),
                    trigger: trigger
                ) { animatedContent, progress in
                    ZStack {
                        ReadCalendarDoneCelebrationOverlay(
                            progress: progress,
                            badgeSize: badgeSize,
                            eventBackground: eventBackground,
                            eventText: eventText,
                            badgeBackground: badgeBackground
                        )
                        .frame(width: 46, height: 46)
                        .allowsHitTesting(false)

                        animatedContent
                            .scaleEffect(ReadCalendarDoneCelebrationMath.scale(for: progress))
                            .offset(y: -3 * ReadCalendarDoneCelebrationMath.lift(for: progress))
                            .rotationEffect(
                                .degrees(
                                    ReadCalendarDoneCelebrationMath.rotation(
                                        for: progress,
                                        maximum: maximumRotation
                                    )
                                )
                            )
                    }
                    .frame(width: badgeSize, height: badgeSize)
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: 0.88)
                    }
                }
        }
    }
}

/// 在封面全屏浮层顶部展示读完状态，并以可重复点击的庆祝反馈承接情感化表达。
struct ReadCalendarDoneMarkerButton: View {
    let markerStyle: ReadCalendarDoneMarkerStyle
    let emojiAssetName: String
    let readDoneBookCount: Int
    let isHapticsEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ScaledMetric(relativeTo: .caption) private var visualWidth: CGFloat = 34
    @ScaledMetric(relativeTo: .caption) private var visualHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var emojiSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var checkmarkSize: CGFloat = 9
    @State private var celebrationTrigger = 0

    var body: some View {
        Button(action: celebrate) {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: CardStyle.borderWidth)
                    }

                ReadCalendarDoneCelebrationEffect(
                    trigger: celebrationTrigger,
                    badgeSize: badgeSize,
                    maximumRotation: markerStyle == .emoji ? 5 : 3,
                    eventBackground: .black,
                    eventText: .white,
                    badgeBackground: .white.withAlpha(0.16)
                ) {
                    marker
                }
            }
            .frame(width: visualWidth, height: visualHeight)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            ReadCalendarDoneMarkerButtonStyle(
                accessibilityReduceMotion: accessibilityReduceMotion
            )
        )
        .accessibilityLabel("当日读完 \(readDoneBookCount) 本")
        .accessibilityHint("轻点播放庆祝动画")
    }

    /// 播放读完庆祝反馈；该操作不修改书籍状态，也不触发页面跳转。
    private func celebrate() {
        if isHapticsEnabled {
            ReadCalendarHaptics.selection()
        }
        guard !accessibilityReduceMotion else { return }
        celebrationTrigger += 1
    }

    /// 绘制与用户设置一致的 emoji 或勾选标识。
    @ViewBuilder
    private var marker: some View {
        Group {
            if markerStyle == .emoji {
                Image(emojiAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: emojiSize, height: emojiSize)
            } else {
                Image(systemName: "checkmark")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: checkmarkSize, height: checkmarkSize)
            }
        }
        .frame(width: badgeSize, height: badgeSize)
    }
}

/// 为读完标识提供克制的按压反馈，并在减少动态效果时只改变透明度。
private struct ReadCalendarDoneMarkerButtonStyle: ButtonStyle {
    let accessibilityReduceMotion: Bool

    /// 根据按压状态返回不改变控件布局的视觉反馈。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !accessibilityReduceMotion ? 0.94 : 1
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// 使用 Canvas 绘制读完标识外的光晕和六颗粒子，保持标识本身的布局尺寸不变。
private struct ReadCalendarDoneCelebrationOverlay: View {
    let progress: CGFloat
    let badgeSize: CGFloat
    let eventBackground: ReadCalendarEventRGBA
    let eventText: ReadCalendarEventRGBA
    let badgeBackground: ReadCalendarEventRGBA

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            drawHalo(in: &context, center: center)
            drawSparkles(in: &context, center: center)
        }
        .accessibilityHidden(true)
    }

    /// 绘制由标识边缘扩散到 22pt 的双层光晕。
    private func drawHalo(in context: inout GraphicsContext, center: CGPoint) {
        let haloProgress = ReadCalendarDoneCelebrationMath.normalized(
            progress,
            from: 0.04,
            to: 0.70
        )
        let easedProgress = ReadCalendarDoneCelebrationMath.easeOutCubic(haloProgress)
        let radius = ReadCalendarDoneCelebrationMath.lerp(
            from: badgeSize / 2 + 2,
            to: 22,
            progress: easedProgress
        )
        let alpha = max(0, min(1, 1 - haloProgress))
        let haloColor = eventBackground.isDark ? ReadCalendarEventRGBA.white : eventText
        let bounds = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.stroke(
            Path(ellipseIn: bounds),
            with: .color(haloColor.withAlpha(0.26 * Double(alpha)).color),
            lineWidth: 1
        )

        let innerRadius = radius * 0.62
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: center.x - innerRadius,
                    y: center.y - innerRadius,
                    width: innerRadius * 2,
                    height: innerRadius * 2
                )
            ),
            with: .color(badgeBackground.withAlpha(0.14 * Double(alpha)).color)
        )
    }

    /// 绘制六颗按 Android 角度、距离和衰减规则扩散的粒子。
    private func drawSparkles(in context: inout GraphicsContext, center: CGPoint) {
        let sparkleProgress = ReadCalendarDoneCelebrationMath.normalized(
            progress,
            from: 0.10,
            to: 0.86
        )
        let easedProgress = ReadCalendarDoneCelebrationMath.easeOutCubic(sparkleProgress)
        let alpha = max(0, min(1, 1 - sparkleProgress))
        let baseColor = eventBackground.isDark ? ReadCalendarEventRGBA.white : eventText
        let angles: [CGFloat] = [-150, -105, -54, 18, 74, 136]

        for (index, angleInDegrees) in angles.enumerated() {
            let angle = angleInDegrees * .pi / 180
            let startRadius = badgeSize / 2 + CGFloat(index % 2) * 0.6
            let travel = (6.5 + CGFloat(index % 3) * 1.6) * easedProgress
            let sparkleCenter = CGPoint(
                x: center.x + cos(angle) * (startRadius + travel),
                y: center.y + sin(angle) * (startRadius + travel * 0.78)
            )
            let radius = ReadCalendarDoneCelebrationMath.lerp(
                from: 1.35,
                to: 0.45,
                progress: easedProgress
            )
            let color = baseColor
                .lerp(to: badgeBackground, amount: index.isMultiple(of: 2) ? 0.18 : 0.38)
                .withAlpha(0.78 * Double(alpha))
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: sparkleCenter.x - radius,
                        y: sparkleCenter.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                ),
                with: .color(color.color)
            )
        }
    }
}

/// 将线性关键帧进度转换为 Android 读完庆祝动画的分段缩放、上浮和旋转参数。
private enum ReadCalendarDoneCelebrationMath {
    /// 返回 Android 四段 ease-out cubic 缩放曲线。
    nonisolated static func scale(for progress: CGFloat) -> CGFloat {
        let value = min(1, max(0, progress))
        switch value {
        case ..<0.18:
            return lerp(from: 1, to: 1.28, progress: easeOutCubic(value / 0.18))
        case ..<0.34:
            return lerp(from: 1.28, to: 0.96, progress: easeOutCubic((value - 0.18) / 0.16))
        case ..<0.54:
            return lerp(from: 0.96, to: 1.08, progress: easeOutCubic((value - 0.34) / 0.20))
        case ..<0.74:
            return lerp(from: 1.08, to: 1, progress: easeOutCubic((value - 0.54) / 0.20))
        default:
            return 1
        }
    }

    /// 返回前 54% 时间内先升后落的正弦位移比例。
    nonisolated static func lift(for progress: CGFloat) -> CGFloat {
        let value = normalized(progress, from: 0, to: 0.54)
        return max(0, min(1, sin(value * .pi)))
    }

    /// 返回随时间衰减的摆动角度。
    nonisolated static func rotation(for progress: CGFloat, maximum: CGFloat) -> CGFloat {
        let value = min(1, max(0, progress))
        return maximum * sin(value * .pi * 3.1) * (1 - value)
    }

    /// 将总进度映射到指定区间的 0…1 值。
    nonisolated static func normalized(
        _ progress: CGFloat,
        from start: CGFloat,
        to end: CGFloat
    ) -> CGFloat {
        guard end > start else { return 1 }
        return min(1, max(0, (progress - start) / (end - start)))
    }

    /// 返回 Android 使用的三次 ease-out 曲线。
    nonisolated static func easeOutCubic(_ progress: CGFloat) -> CGFloat {
        let value = min(1, max(0, progress))
        return 1 - pow(1 - value, 3)
    }

    /// 在线性区间内插值并约束输入进度。
    nonisolated static func lerp(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * min(1, max(0, progress))
    }
}
