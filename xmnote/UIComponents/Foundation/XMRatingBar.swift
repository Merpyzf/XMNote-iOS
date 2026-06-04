/**
 * [INPUT]: 依赖 SwiftUI Shape/Binding/Gesture 与 DesignTokens 评分语义色，承接 Android FluentRatingBar 的星形与评分步进语义
 * [OUTPUT]: 对外提供 XMRatingBar、XMRatingBarStep 与 XMRatingBarPreset，统一只读与交互评分组件
 * [POS]: UIComponents/Foundation 跨模块复用组件，作为书籍评分展示与评分输入的基础设施
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 评分条步进粒度，对齐 Android FluentRatingBar 的 StepSize。
enum XMRatingBarStep: Double, CaseIterable, Identifiable {
    case one = 1
    case half = 0.5

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .one:
            return "整星"
        case .half:
            return "半星"
        }
    }
}

/// 评分条常用尺寸预设，覆盖列表、表单和弹窗等业务场景。
enum XMRatingBarPreset: String, CaseIterable, Identifiable {
    case listSmall
    case capsule
    case form
    case dialog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listSmall:
            return "列表小星"
        case .capsule:
            return "胶囊评分"
        case .form:
            return "表单评分"
        case .dialog:
            return "弹窗评分"
        }
    }

    var starSize: CGFloat {
        switch self {
        case .listSmall:
            return 14
        case .capsule:
            return 16
        case .form:
            return 20
        case .dialog:
            return 30
        }
    }

    var spacing: CGFloat {
        switch self {
        case .listSmall:
            return 1
        case .capsule:
            return 3
        case .form:
            return 3
        case .dialog:
            return 2
        }
    }
}

/// Android 对齐的圆润五角星评分条，支持只读展示与半星步进输入。
struct XMRatingBar: View {
    @Binding private var value: Double
    @ScaledMetric(relativeTo: .caption) private var starSize: CGFloat = XMRatingBarPreset.listSmall.starSize
    @ScaledMetric(relativeTo: .caption) private var starSpacing: CGFloat = XMRatingBarPreset.listSmall.spacing

    private let starCount: Int
    private let step: XMRatingBarStep
    private let isIndicator: Bool
    private let activeColor: Color
    private let inactiveColor: Color
    private let onValueChange: (Double) -> Void
    private let onRatingChanged: (Double) -> Void

    /// 构建只读评分条，适用于列表、卡片和详情页展示。
    init(
        value: Double,
        starCount: Int = 5,
        preset: XMRatingBarPreset = .listSmall,
        step: XMRatingBarStep = .half,
        activeColor: Color = .ratingActive,
        inactiveColor: Color = .ratingInactive
    ) {
        self.init(
            value: .constant(value),
            starCount: starCount,
            size: preset.starSize,
            spacing: preset.spacing,
            step: step,
            isIndicator: true,
            activeColor: activeColor,
            inactiveColor: inactiveColor
        )
    }

    /// 直接使用 Android/iOS 业务分数构建只读评分条，分数范围为 0...50。
    init(
        score: Int64,
        starCount: Int = 5,
        preset: XMRatingBarPreset = .listSmall,
        step: XMRatingBarStep = .half,
        activeColor: Color = .ratingActive,
        inactiveColor: Color = .ratingInactive
    ) {
        self.init(
            value: Double(score) / 10.0,
            starCount: starCount,
            preset: preset,
            step: step,
            activeColor: activeColor,
            inactiveColor: inactiveColor
        )
    }

    /// 构建可交互评分条，拖动和点击都会按指定步进写回绑定值。
    init(
        value: Binding<Double>,
        starCount: Int = 5,
        preset: XMRatingBarPreset = .form,
        step: XMRatingBarStep = .half,
        isIndicator: Bool = false,
        activeColor: Color = .ratingActive,
        inactiveColor: Color = .ratingInactive,
        onValueChange: @escaping (Double) -> Void = { _ in },
        onRatingChanged: @escaping (Double) -> Void = { _ in }
    ) {
        self.init(
            value: value,
            starCount: starCount,
            size: preset.starSize,
            spacing: preset.spacing,
            step: step,
            isIndicator: isIndicator,
            activeColor: activeColor,
            inactiveColor: inactiveColor,
            onValueChange: onValueChange,
            onRatingChanged: onRatingChanged
        )
    }

    /// 构建可完全自定义尺寸的评分条，用于调试页和少数特殊容器。
    init(
        value: Binding<Double>,
        starCount: Int = 5,
        size: CGFloat,
        spacing: CGFloat,
        step: XMRatingBarStep = .half,
        isIndicator: Bool = false,
        activeColor: Color = .ratingActive,
        inactiveColor: Color = .ratingInactive,
        onValueChange: @escaping (Double) -> Void = { _ in },
        onRatingChanged: @escaping (Double) -> Void = { _ in }
    ) {
        self._value = value
        self._starSize = ScaledMetric(wrappedValue: size, relativeTo: .caption)
        self._starSpacing = ScaledMetric(wrappedValue: spacing, relativeTo: .caption)
        self.starCount = max(1, starCount)
        self.step = step
        self.isIndicator = isIndicator
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.onValueChange = onValueChange
        self.onRatingChanged = onRatingChanged
    }

    var body: some View {
        ratingContent
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("评分")
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                guard !isIndicator else { return }
                adjustAccessibilityValue(direction)
            }
    }

    @ViewBuilder
    private var ratingContent: some View {
        if isIndicator {
            ratingFrame
        } else {
            ratingFrame
                .gesture(dragGesture)
        }
    }

    private var ratingFrame: some View {
        let visualHeight = starSize
        let touchHeight = isIndicator ? visualHeight : max(44, visualHeight)

        return ZStack {
            stars
                .frame(width: totalWidth, height: visualHeight)
        }
        .frame(width: totalWidth, height: touchHeight)
        .contentShape(Rectangle())
    }

    private var stars: some View {
        HStack(spacing: starSpacing) {
            ForEach(0..<starCount, id: \.self) { index in
                star(fillRatio: fillRatio(at: index))
            }
        }
    }

    private func star(fillRatio: CGFloat) -> some View {
        let clippedWidth = starSize * fillRatio

        return ZStack(alignment: .leading) {
            XMFluentStarShape()
                .fill(inactiveColor)
                .frame(width: starSize, height: starSize)

            XMFluentStarShape()
                .fill(activeColor)
                .frame(width: starSize, height: starSize)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: clippedWidth, height: starSize)
                }
        }
        .frame(width: starSize, height: starSize)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { updateValue(from: $0.location.x, isFinal: false) }
            .onEnded { updateValue(from: $0.location.x, isFinal: true) }
    }

    private func updateValue(from locationX: CGFloat, isFinal: Bool) {
        let nextValue = ratingValue(for: locationX)
        if normalizedValue != nextValue {
            value = nextValue
            onValueChange(nextValue)
        }
        if isFinal {
            onRatingChanged(nextValue)
        }
    }

    private func ratingValue(for locationX: CGFloat) -> Double {
        guard totalWidth > 0 else { return 0 }

        let clampedX = min(max(locationX, 0), totalWidth)
        guard clampedX > 0 else { return 0 }
        guard clampedX < totalWidth else { return Double(starCount) }

        let unitWidth = starSize + starSpacing
        let rawIndex = min(starCount - 1, max(0, Int(clampedX / unitWidth)))
        let starStart = CGFloat(rawIndex) * unitWidth
        let localX = min(max(clampedX - starStart, 0), starSize)
        let rawValue = Double(rawIndex) + Double(localX / starSize)
        return snappedValue(rawValue)
    }

    private func adjustAccessibilityValue(_ direction: AccessibilityAdjustmentDirection) {
        let delta = step.rawValue
        let nextValue: Double
        switch direction {
        case .increment:
            nextValue = min(Double(starCount), normalizedValue + delta)
        case .decrement:
            nextValue = max(0, normalizedValue - delta)
        @unknown default:
            return
        }

        guard nextValue != normalizedValue else { return }
        value = nextValue
        onValueChange(nextValue)
        onRatingChanged(nextValue)
    }

    private func snappedValue(_ rawValue: Double) -> Double {
        let stepValue = step.rawValue
        let steppedValue = ceil(rawValue / stepValue) * stepValue
        return min(max(steppedValue, 0), Double(starCount))
    }

    private func fillRatio(at index: Int) -> CGFloat {
        let remaining = normalizedValue - Double(index)
        return CGFloat(min(max(remaining, 0), 1))
    }

    private var totalWidth: CGFloat {
        CGFloat(starCount) * starSize + CGFloat(max(0, starCount - 1)) * starSpacing
    }

    private var normalizedValue: Double {
        min(max(value, 0), Double(starCount))
    }

    private var accessibilityValue: String {
        String(format: "%.1f 星", normalizedValue)
    }
}

/// Fluent UI 风格的圆润五角星，源路径对齐 Android FluentRatingBar。
private struct XMFluentStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.viewportSize
        let originX = rect.minX + (rect.width - Self.viewportSize * scale) / 2
        let originY = rect.minY + (rect.height - Self.viewportSize * scale) / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(10.7878, 3.10215))
        path.addCurve(
            to: point(13.209, 3.10215),
            control1: point(11.283, 2.09877),
            control2: point(12.7138, 2.09876)
        )
        path.addLine(to: point(15.567, 7.87987))
        path.addLine(to: point(20.8395, 8.64601))
        path.addCurve(
            to: point(21.5877, 10.9487),
            control1: point(21.9468, 8.80691),
            control2: point(22.3889, 10.1677)
        )
        path.addLine(to: point(17.7724, 14.6676))
        path.addLine(to: point(18.6731, 19.9189))
        path.addCurve(
            to: point(16.7143, 21.342),
            control1: point(18.8622, 21.0217),
            control2: point(17.7047, 21.8627)
        )
        path.addLine(to: point(11.9984, 18.8627))
        path.addLine(to: point(7.28252, 21.342))
        path.addCurve(
            to: point(5.32374, 19.9189),
            control1: point(6.29213, 21.8627),
            control2: point(5.13459, 21.0217)
        )
        path.addLine(to: point(6.2244, 14.6676))
        path.addLine(to: point(2.40916, 10.9487))
        path.addCurve(
            to: point(3.15735, 8.64601),
            control1: point(1.60791, 10.1677),
            control2: point(2.05005, 8.80691)
        )
        path.addLine(to: point(8.42988, 7.87987))
        path.addLine(to: point(10.7878, 3.10215))
        path.closeSubpath()
        return path
    }

    private static let viewportSize: CGFloat = 24
}

#Preview {
    VStack(alignment: .leading, spacing: Spacing.base) {
        XMRatingBar(value: 3.5)
        XMRatingBar(score: 45, preset: .form)
        XMRatingBar(value: .constant(2.5), preset: .dialog)
    }
    .padding()
}
