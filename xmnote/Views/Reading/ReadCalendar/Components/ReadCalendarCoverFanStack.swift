/**
 * [INPUT]: 依赖 XMRemoteImage 与 DesignTokens 视觉令牌，依赖封面列表、稳定随机 Seed 与展示模式参数
 * [OUTPUT]: 对外提供 ReadCalendarCoverFanStack（日历格子内封面非规则堆叠视图，支持折叠态与全屏态）
 * [POS]: ReadCalendar 页面私有子视图，负责封面非规则搓开层次、阴影分离、稳定布局与轻动画过渡
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// ReadCalendarCoverFanStack 用于在日历格子中渲染封面扇形堆叠效果。
struct ReadCalendarCoverFanStack: View {
    /// Item 表示堆叠中的单个封面输入。
    struct Item: Identifiable, Hashable {
        let id: String
        let coverURL: String?

        /// 初始化单个封面条目，供日历格子扇形堆叠渲染使用。
        init(id: String, coverURL: String? = nil) {
            self.id = id
            self.coverURL = coverURL
        }
    }

    /// PresentationMode 表示封面堆叠的展示模式（折叠/全屏）。
    enum PresentationMode: String, Hashable {
        case collapsed
        case fullscreen
    }

    /// LayoutSeed 表示稳定随机布局种子，确保同一天同数据下布局可复现。
    struct LayoutSeed: Hashable {
        let rawValue: UInt64

        init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    private struct FanTransform {
        let rotation: Double
        let offsetX: CGFloat
        let offsetY: CGFloat
        let zIndex: Double
        let scale: CGFloat
        let opacity: CGFloat
    }

    /// Style 表示封面堆叠的几何与阴影视觉参数。
    struct Style: Hashable {
        let secondaryRotation: Double
        let tertiaryRotation: Double
        let secondaryOffsetXRatio: CGFloat
        let tertiaryOffsetXRatio: CGFloat
        let secondaryOffsetYRatio: CGFloat
        let tertiaryOffsetYRatio: CGFloat
        let shadowOpacity: CGFloat
        let shadowRadius: CGFloat
        let shadowX: CGFloat
        let shadowY: CGFloat
        let collapsedVisibleCount: Int
        let jitterDegree: Double
        let jitterOffsetRatio: CGFloat
        let fullscreenMaxRotation: Double

        /// 初始化堆叠视觉参数，供测试页与业务页共用。
        init(
            secondaryRotation: Double,
            tertiaryRotation: Double,
            secondaryOffsetXRatio: CGFloat,
            tertiaryOffsetXRatio: CGFloat,
            secondaryOffsetYRatio: CGFloat,
            tertiaryOffsetYRatio: CGFloat,
            shadowOpacity: CGFloat,
            shadowRadius: CGFloat,
            shadowX: CGFloat,
            shadowY: CGFloat,
            collapsedVisibleCount: Int = 6,
            jitterDegree: Double = 3.2,
            jitterOffsetRatio: CGFloat = 0.09,
            fullscreenMaxRotation: Double = 14
        ) {
            self.secondaryRotation = secondaryRotation
            self.tertiaryRotation = tertiaryRotation
            self.secondaryOffsetXRatio = secondaryOffsetXRatio
            self.tertiaryOffsetXRatio = tertiaryOffsetXRatio
            self.secondaryOffsetYRatio = secondaryOffsetYRatio
            self.tertiaryOffsetYRatio = tertiaryOffsetYRatio
            self.shadowOpacity = shadowOpacity
            self.shadowRadius = shadowRadius
            self.shadowX = shadowX
            self.shadowY = shadowY
            self.collapsedVisibleCount = max(1, collapsedVisibleCount)
            self.jitterDegree = max(0, jitterDegree)
            self.jitterOffsetRatio = max(0, jitterOffsetRatio)
            self.fullscreenMaxRotation = max(0, fullscreenMaxRotation)
        }

        static let editorial = Style(
            secondaryRotation: -12,
            tertiaryRotation: -24,
            secondaryOffsetXRatio: -0.24,
            tertiaryOffsetXRatio: -0.48,
            secondaryOffsetYRatio: -0.08,
            tertiaryOffsetYRatio: 0.06,
            shadowOpacity: 0.24,
            shadowRadius: 5.6,
            shadowX: 1.8,
            shadowY: 3.2,
            collapsedVisibleCount: 6,
            jitterDegree: 3.2,
            jitterOffsetRatio: 0.09,
            fullscreenMaxRotation: 14
        )

        static let standard = editorial
    }

    private enum Layout {
        static let maxCollapsedSupportedCount = 14
        static let maxFullscreenSupportedCount = 120
        static let borderOpacity: CGFloat = 0.45
        static let borderWidth: CGFloat = 0.45
        static let placeholderOpacity: CGFloat = 0.52
        static let animationDuration: CGFloat = 0.22
        static let transitionScale: CGFloat = 0.94
        static let goldenAngle = 2.399963229728653
        static let fullscreenXRadiusUnit: CGFloat = 0.62
        static let fullscreenYRadiusUnit: CGFloat = 0.52
    }

    let items: [Item]
    let maxVisibleCount: Int
    let coverSize: CGSize
    let isAnimated: Bool
    let style: Style
    let presentationMode: PresentationMode
    let layoutSeed: LayoutSeed?
    let showsOverflowTailCue: Bool

    /// 注入封面集合与展示参数，配置日历格子内的扇形封面堆叠效果。
    init(
        items: [Item],
        maxVisibleCount: Int = 3,
        coverSize: CGSize = CGSize(width: 14, height: 20),
        isAnimated: Bool = true,
        style: Style = .standard,
        presentationMode: PresentationMode = .collapsed,
        layoutSeed: LayoutSeed? = nil,
        showsOverflowTailCue: Bool = false
    ) {
        self.items = items
        self.maxVisibleCount = maxVisibleCount
        self.coverSize = coverSize
        self.isAnimated = isAnimated
        self.style = style
        self.presentationMode = presentationMode
        self.layoutSeed = layoutSeed
        self.showsOverflowTailCue = showsOverflowTailCue
    }

    var body: some View {
        ZStack {
            if isOverflowTailCueVisible {
                overflowTailCue
            }
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                let transform = transform(for: index, total: visibleItems.count)
                coverCard(for: item)
                    .frame(width: coverSize.width, height: coverSize.height)
                    .rotationEffect(.degrees(transform.rotation))
                    .offset(x: transform.offsetX, y: transform.offsetY)
                    .zIndex(transform.zIndex)
                    .scaleEffect(transform.scale)
                    .opacity(transform.opacity)
                    .shadow(
                        color: Color.black.opacity(style.shadowOpacity),
                        radius: style.shadowRadius,
                        x: style.shadowX,
                        y: style.shadowY
                    )
                    .transition(.opacity.combined(with: .scale(scale: Layout.transitionScale)))
            }
        }
        .frame(width: coverSize.width, height: coverSize.height, alignment: .center)
        .animation(animationStyle, value: visibleItems.map(\.id))
        .animation(animationStyle, value: style)
        .animation(animationStyle, value: coverSize)
    }
}

private extension ReadCalendarCoverFanStack {
    var isOverflowTailCueVisible: Bool {
        showsOverflowTailCue
            && presentationMode == .collapsed
            && items.count > visibleItems.count
            && !visibleItems.isEmpty
    }

    var visibleItems: [Item] {
        Array(items.prefix(cappedVisibleCount))
    }

    var cappedVisibleCount: Int {
        let clamped = max(0, maxVisibleCount)
        switch presentationMode {
        case .collapsed:
            let styleCapped = min(style.collapsedVisibleCount, Layout.maxCollapsedSupportedCount)
            return min(clamped, styleCapped)
        case .fullscreen:
            return min(clamped, Layout.maxFullscreenSupportedCount)
        }
    }

    var resolvedSeed: LayoutSeed {
        layoutSeed ?? Self.makeLayoutSeed(
            date: Date(timeIntervalSince1970: 0),
            items: items,
            mode: presentationMode
        )
    }

    var animationStyle: Animation? {
        guard isAnimated else { return nil }
        return .snappy(duration: Layout.animationDuration)
    }

    /// 为日历单元封面堆叠渲染单张卡片：有合法封面地址时显示远程图片，否则降级为占位卡片。
    @ViewBuilder
    func coverCard(for item: Item) -> some View {
        if let coverURL = normalizedCoverURL(item.coverURL) {
            XMRemoteImage(urlString: coverURL, contentMode: .fill, priority: .low) {
                coverPlaceholder
            }
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(Color.white.opacity(Layout.borderOpacity), lineWidth: Layout.borderWidth)
            }
        } else {
            coverPlaceholder
        }
    }

    var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(Color.readCalendarSelectionFill.opacity(Layout.placeholderOpacity))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(Color.white.opacity(Layout.borderOpacity), lineWidth: Layout.borderWidth)
            }
    }

    var overflowTailCue: some View {
        ZStack {
            overflowTailCueCard(
                scale: 0.9,
                rotation: -11,
                offsetX: -coverSize.width * 0.58,
                offsetY: coverSize.height * 0.18,
                opacity: 0.34,
                zIndex: 88
            )
            overflowTailCueCard(
                scale: 0.84,
                rotation: -18,
                offsetX: -coverSize.width * 0.86,
                offsetY: coverSize.height * 0.28,
                opacity: 0.24,
                zIndex: 87
            )
        }
        .transition(.opacity.combined(with: .scale(scale: Layout.transitionScale)))
    }

    func overflowTailCueCard(
        scale: CGFloat,
        rotation: Double,
        offsetX: CGFloat,
        offsetY: CGFloat,
        opacity: CGFloat,
        zIndex: Double
    ) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.26),
                        Color.readCalendarSelectionFill.opacity(0.38)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(Color.white.opacity(0.24), lineWidth: Layout.borderWidth)
            }
            .frame(width: coverSize.width, height: coverSize.height)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(x: offsetX, y: offsetY)
            .opacity(opacity)
            .zIndex(zIndex)
            .shadow(color: Color.black.opacity(style.shadowOpacity * 0.58), radius: style.shadowRadius * 0.82, x: style.shadowX, y: style.shadowY)
    }

    /// 归一化封面地址，过滤空白字符串，避免将无效 URL 传给图片加载组件。
    func normalizedCoverURL(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 根据展示模式与层级计算封面变换，形成稳定可复现的非规则堆叠视觉。
    private func transform(for depth: Int, total: Int) -> FanTransform {
        switch presentationMode {
        case .collapsed:
            return collapsedTransform(for: depth)
        case .fullscreen:
            return fullscreenTransform(for: depth, total: total)
        }
    }

    /// 折叠态：在模板基础上叠加稳定抖动，打破规则扇形。
    private func collapsedTransform(for depth: Int) -> FanTransform {
        let template = collapsedTemplate(depth: depth)
        let jitterRotation = Double(jitter(depth: depth, channel: 11)) * style.jitterDegree
        let jitterX = jitter(depth: depth, channel: 23) * style.jitterOffsetRatio * coverSize.width
        let jitterY = jitter(depth: depth, channel: 31) * style.jitterOffsetRatio * coverSize.height

        return FanTransform(
            rotation: template.rotation + jitterRotation,
            offsetX: template.offsetX + jitterX,
            offsetY: template.offsetY + jitterY,
            zIndex: Double(220 - depth),
            scale: max(0.78, template.scale),
            opacity: max(0.78, template.opacity)
        )
    }

    /// 全屏态：采用黄金角扩散布局，优先突出前几本封面。
    private func fullscreenTransform(for depth: Int, total: Int) -> FanTransform {
        if depth == 0 {
            return FanTransform(
                rotation: Double(jitter(depth: 0, channel: 61)) * min(style.fullscreenMaxRotation, 5),
                offsetX: 0,
                offsetY: 0,
                zIndex: 500,
                scale: 1.14,
                opacity: 1
            )
        }

        let spiralIndex = max(1, depth)
        let radialUnit = CGFloat(sqrt(Double(spiralIndex)))
        let angle = Layout.goldenAngle * Double(spiralIndex)
            + Double(jitter(depth: spiralIndex, channel: 67)) * 0.42

        let offsetX = cos(angle) * Double(radialUnit * coverSize.width * Layout.fullscreenXRadiusUnit)
        let offsetY = sin(angle) * Double(radialUnit * coverSize.height * Layout.fullscreenYRadiusUnit)
        let scale = fullscreenScale(for: depth, total: total)

        return FanTransform(
            rotation: Double(jitter(depth: spiralIndex, channel: 73)) * style.fullscreenMaxRotation,
            offsetX: CGFloat(offsetX),
            offsetY: CGFloat(offsetY),
            zIndex: fullscreenZIndex(for: depth, total: total),
            scale: scale,
            opacity: depth < 3 ? 1 : 0.98
        )
    }

    /// 折叠态模板：模拟杂志式随手叠放的非规则轨迹。
    private func collapsedTemplate(depth: Int) -> FanTransform {
        let templates: [(rotation: Double, xRatio: CGFloat, yRatio: CGFloat, scale: CGFloat, opacity: CGFloat)] = [
            (0, 0, 0, 1, 1),
            (style.secondaryRotation, style.secondaryOffsetXRatio, style.secondaryOffsetYRatio, 0.98, 1),
            (style.tertiaryRotation, style.tertiaryOffsetXRatio, style.tertiaryOffsetYRatio, 0.95, 0.99),
            (9, 0.18, -0.16, 0.92, 0.98),
            (-18, -0.62, 0.20, 0.9, 0.97),
            (14, 0.34, -0.24, 0.88, 0.96),
            (-26, -0.78, 0.28, 0.86, 0.95),
            (19, 0.46, -0.32, 0.84, 0.94),
            (-31, -0.9, 0.36, 0.82, 0.93),
            (23, 0.58, -0.36, 0.8, 0.92),
            (-35, -1.02, 0.42, 0.79, 0.91),
            (27, 0.7, -0.4, 0.78, 0.9),
            (-39, -1.1, 0.48, 0.77, 0.89),
            (30, 0.8, -0.44, 0.76, 0.88)
        ]
        let selected = templates[min(depth, templates.count - 1)]
        return FanTransform(
            rotation: selected.rotation,
            offsetX: coverSize.width * selected.xRatio,
            offsetY: coverSize.height * selected.yRatio,
            zIndex: Double(220 - depth),
            scale: selected.scale,
            opacity: selected.opacity
        )
    }

    /// 生成稳定抖动值（-1...1），保证同 Seed 下布局稳定可复现。
    func jitter(depth: Int, channel: UInt64) -> CGFloat {
        let depthValue = UInt64(max(0, depth) + 1)
        var state = resolvedSeed.rawValue
            &+ depthValue &* 0x9E37_79B9_7F4A_7C15
            ^ channel &* 0xBF58_476D_1CE4_E5B9
        state = splitMix64(state)
        let unit = Double(state) / Double(UInt64.max)
        return CGFloat(unit * 2 - 1)
    }

    func splitMix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    func fullscreenScale(for depth: Int, total: Int) -> CGFloat {
        if depth == 0 { return 1.14 }
        if depth == 1 { return 1.08 }
        if depth == 2 { return 1.03 }
        let ratio = CGFloat(depth) / CGFloat(max(1, total))
        return max(0.72, 0.98 - ratio * 0.24)
    }

    func fullscreenZIndex(for depth: Int, total: Int) -> Double {
        if depth < 3 {
            return Double(480 - depth)
        }
        return Double(max(1, total - depth))
    }
}

extension ReadCalendarCoverFanStack {
    /// 基于日期与条目标识生成稳定布局种子，确保同日封面布局一致。
    static func makeLayoutSeed(
        date: Date,
        items: [Item],
        mode: PresentationMode
    ) -> LayoutSeed {
        let dayKey = Int64(floor(date.timeIntervalSince1970 / 86_400))
        let ids = items.map(\.id).joined(separator: "|")
        let source = "\(dayKey)|\(mode.rawValue)|\(ids)"
        return LayoutSeed(rawValue: fnv1a64(source))
    }

    private static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
