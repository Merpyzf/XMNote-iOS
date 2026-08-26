/**
 * [INPUT]: 依赖 SwiftUI Binding/Gesture 与 XMFluentStarShape，承接 Android FluentRatingBar 的星形、评分步进与浅深色外观语义
 * [OUTPUT]: 对外提供 XMRatingAppearance、XMRatingBar、XMRatingBarStep 与 XMRatingBarPreset，统一只读与交互评分组件
 * [POS]: UIComponents/Controls/Rating 的跨模块评分控件，作为书籍评分展示与评分输入的基础设施
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 评分组件的视觉 owner，保留 Android FluentRatingBar 在浅深色模式下的星级对比。
enum XMRatingAppearance {
    static let active = Color.xmHex(0xFFC500)
    static let inactive = Color.xmAdaptive(
        light: Color.xmHex(0xDFE8F1),
        dark: Color.xmHex(0xDFE8F1, alpha: 0.34)
    )
}

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
        activeColor: Color = XMRatingAppearance.active,
        inactiveColor: Color = XMRatingAppearance.inactive
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
        activeColor: Color = XMRatingAppearance.active,
        inactiveColor: Color = XMRatingAppearance.inactive
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
        activeColor: Color = XMRatingAppearance.active,
        inactiveColor: Color = XMRatingAppearance.inactive,
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
        activeColor: Color = XMRatingAppearance.active,
        inactiveColor: Color = XMRatingAppearance.inactive,
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
        let touchHeight = isIndicator ? visualHeight : max(InteractionMetrics.minimumTouchTarget, visualHeight)

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
        let value = normalizedValue.formatted(
            .number.precision(.fractionLength(1))
        )
        return "\(value) 星"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Spacing.base) {
        XMRatingBar(value: 3.5)
        XMRatingBar(score: 45, preset: .form)
        XMRatingBar(value: .constant(2.5), preset: .dialog)
    }
    .padding()
}
