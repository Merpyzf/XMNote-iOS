/**
 * [INPUT]: 依赖单书阅读详情领域快照、CalendarHeatmap、MonthlyReadingChart、ReadingStatusTimeline、ReadingStatusPresentation、ReadingSummaryTypography、XMBookCover、XMRatingBar 与 InteractionMetrics
 * [OUTPUT]: 对外提供一次计算的 BookReadingDetailTheme、单向沉浸背景、Android 同源半透明内容表面、BookReadingDetailContent 与内容模式
 * [POS]: Views/Book/Components 阅读详情页面私有内容组件，不拥有数据查询、写入或导航状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 页面私有视觉主题，把封面颜色种子映射为单向沉浸画布、半透明内容表面和可读图表色阶。
struct BookReadingDetailTheme {
    let isCoverDerived: Bool
    let neutralBackground: Color
    let gradientStartColor: Color
    let gradientEndColor: Color
    let cardSurface: Color
    let onCardPrimary: Color
    let onCardSecondary: Color
    let onCardPrimaryUIColor: UIColor
    let nestedBackground: Color
    let attributeBackground: Color
    let accent: Color
    let onAccent: Color
    let colorScheme: ColorScheme
    let reducesTransparency: Bool

    private let accentVeryLess: Color
    private let accentLess: Color
    private let accentMore: Color
    private let monthTrackColor: Color
    private let monthBarColors: [Color]
    private let monthBarForeground: Color
    private let dailyBarColors: [Color]
    private let dailyBarForeground: Color

    /// 仅在真实封面取色成功且用户开启渐变时启用主题；失败结果不使用哈希色伪造封面氛围。
    init(
        coverColor: BookCoverThemeColor,
        isEnabled: Bool,
        colorScheme: ColorScheme,
        reducesTransparency: Bool
    ) {
        let isResolved = isEnabled
            && coverColor.state == .resolved
            && coverColor.backgroundRGBAHex != 0
            && coverColor.backgroundRGBAHex & 0xFF > 0
        let systemPalette = SystemPalette(colorScheme: colorScheme)
        let immersivePalette = ImmersivePalette(
            tintRGBAHex: isResolved ? coverColor.backgroundRGBAHex : nil,
            colorScheme: colorScheme,
            reducesTransparency: reducesTransparency,
            systemPalette: systemPalette
        )
        let fallbackAccentRGBAHex: UInt32 = colorScheme == .dark ? 0x8C929BFF : 0x666666FF
        let resolvedAccentRGBAHex = isResolved
            ? coverColor.accentRGBAHex
            : fallbackAccentRGBAHex
        let accentPalette = AccentPalette(
            rgbaHex: resolvedAccentRGBAHex
        )
        let readingChartPalette = ReadingChartPalette(
            rgbaHex: resolvedAccentRGBAHex,
            surface: systemPalette.card,
            preferredForegroundRGBAHex: isResolved && coverColor.onRepresentativeRGBAHex != 0
                ? coverColor.onRepresentativeRGBAHex
                : nil
        )
        self.isCoverDerived = isResolved
        self.neutralBackground = immersivePalette.neutralBackground
        self.gradientStartColor = immersivePalette.gradientStartColor
        self.gradientEndColor = immersivePalette.gradientEndColor
        self.cardSurface = immersivePalette.cardSurface
        self.onCardPrimary = immersivePalette.onCardPrimary
        self.onCardSecondary = immersivePalette.onCardSecondary
        self.onCardPrimaryUIColor = immersivePalette.onCardPrimaryUIColor
        self.nestedBackground = immersivePalette.nestedBackground
        self.attributeBackground = immersivePalette.attributeBackground
        self.accent = accentPalette.strong
        self.onAccent = accentPalette.foreground
        self.colorScheme = colorScheme
        self.reducesTransparency = reducesTransparency
        self.accentVeryLess = accentPalette.veryLess
        self.accentLess = accentPalette.less
        self.accentMore = accentPalette.more
        self.monthTrackColor = readingChartPalette.monthTrack
        self.monthBarColors = readingChartPalette.monthColors
        self.monthBarForeground = readingChartPalette.monthForeground
        self.dailyBarColors = readingChartPalette.dailyColors
        self.dailyBarForeground = readingChartPalette.dailyForeground
    }

    var border: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
    }

    var heatmapPalette: HeatmapColorPalette {
        HeatmapColorPalette(
            none: nestedBackground,
            veryLess: accentVeryLess,
            less: accentLess,
            more: accentMore,
            veryMore: accent
        )
    }

    var calendarStyle: CalendarHeatmapStyle {
        CalendarHeatmapStyle(
            palette: heatmapPalette,
            monthTitleColor: onCardSecondary,
            emptyDayTextColor: onCardSecondary,
            activeDayTextColor: onAccent
        )
    }

    var heatmapLegendStyle: HeatmapLegendStyle {
        .calendarReadingDetail.replacing(textColor: onCardSecondary)
    }

    var monthlyChartStyle: MonthlyReadingChartStyle {
        MonthlyReadingChartStyle(
            monthTrackColor: monthTrackColor,
            monthBarColors: monthBarColors,
            collapsedSummaryColor: monthBarForeground,
            expandedSummaryColor: onCardSecondary,
            collapsedArrowColor: monthBarForeground,
            expandedArrowColor: onCardSecondary,
            dailyBarColors: dailyBarColors,
            dailyDateColor: dailyBarForeground,
            dailyDurationColor: dailyBarForeground
        )
    }

    var timelineStyle: ReadingStatusTimeline.Style {
        ReadingStatusTimeline.Style(
            primaryTextColor: onCardPrimary,
            secondaryTextColor: onCardSecondary
        )
    }

    /// 阅读详情专用沉浸色板；Android 同源背景色负责单向画布，系统语义色负责半透明内容表面。
    private struct ImmersivePalette {
        let neutralBackground: Color
        let gradientStartColor: Color
        let gradientEndColor: Color
        let cardSurface: Color
        let onCardPrimary: Color
        let onCardSecondary: Color
        let onCardPrimaryUIColor: UIColor
        let nestedBackground: Color
        let attributeBackground: Color

        /// 将封面色映射为整页渐变，并以 Android 的 30% 卡面为起点完成 AA 可读性校准。
        init(
            tintRGBAHex: UInt32?,
            colorScheme: ColorScheme,
            reducesTransparency: Bool,
            systemPalette: SystemPalette
        ) {
            let isDark = colorScheme == .dark
            let source: RGBComponents?
            if let tintRGBAHex {
                source = RGBComponents(rgbaHex: tintRGBAHex)
            } else {
                source = nil
            }
            let canvas = source.map {
                isDark ? $0.blended(toward: .black, amount: 0.30) : $0
            } ?? systemPalette.page
            let gradientStart = source.map {
                Self.accessibleTint(
                    source: $0,
                    base: systemPalette.page,
                    maximumStrength: isDark ? 0.14 : 0.18,
                    primaryText: systemPalette.primaryText
                )
            } ?? systemPalette.page
            let usesTransparentTheme = source != nil && !reducesTransparency
            neutralBackground = systemPalette.page.color
            gradientStartColor = gradientStart.color
            gradientEndColor = canvas.color
            if usesTransparentTheme {
                let cardPresentation = Self.readableCardPresentation(
                    overlay: systemPalette.card,
                    substrates: [gradientStart, canvas],
                    colorScheme: colorScheme,
                    secondaryTextPole: systemPalette.primaryText
                )
                cardSurface = systemPalette.card.color(opacity: cardPresentation.surfaceOpacity)
                onCardPrimary = cardPresentation.primary.color
                onCardSecondary = cardPresentation.secondaryPole.color(
                    opacity: cardPresentation.secondaryOpacity
                )
                onCardPrimaryUIColor = cardPresentation.primary.uiColor
                nestedBackground = isDark
                    ? RGBComponents.white.color(opacity: 0.05)
                    : systemPalette.nested.color(opacity: 0.30)
                attributeBackground = systemPalette.card.color(opacity: 0.45)
            } else {
                cardSurface = systemPalette.card.color
                onCardPrimary = systemPalette.primaryText.color
                onCardSecondary = systemPalette.secondaryText.color
                onCardPrimaryUIColor = systemPalette.primaryText.uiColor
                nestedBackground = systemPalette.nested.color
                attributeBackground = systemPalette.nested.color
            }
        }

        private struct CardPresentation {
            let surfaceOpacity: Double
            let primary: RGBComponents
            let secondaryPole: RGBComponents
            let secondaryOpacity: Double
        }

        /// 先增强卡内文字，再以 0.5% 步进增强卡面；卡面强度被硬性限制在 60%。
        private static func readableCardPresentation(
            overlay: RGBComponents,
            substrates: [RGBComponents],
            colorScheme: ColorScheme,
            secondaryTextPole: RGBComponents
        ) -> CardPresentation {
            let textPole: RGBComponents = colorScheme == .dark ? .white : .black
            var surfaceOpacity = 0.30
            while surfaceOpacity <= 0.600_001 {
                let composites = substrates.map {
                    $0.blended(toward: overlay, amount: surfaceOpacity)
                }
                let hasPrimaryContrast = composites.allSatisfy {
                    textPole.contrastRatio(with: $0) >= 4.5
                }
                if hasPrimaryContrast,
                   let secondaryOpacity = readableSecondaryOpacity(
                       pole: secondaryTextPole,
                       surfaces: composites
                   ) {
                    return CardPresentation(
                        surfaceOpacity: surfaceOpacity,
                        primary: textPole,
                        secondaryPole: secondaryTextPole,
                        secondaryOpacity: secondaryOpacity
                    )
                }
                surfaceOpacity += 0.005
            }

            return CardPresentation(
                surfaceOpacity: 0.60,
                primary: textPole,
                secondaryPole: secondaryTextPole,
                secondaryOpacity: 1
            )
        }

        /// 从 Android 的 60% 次要文字强度开始，仅提高前景强度直到普通文字达到 AA。
        private static func readableSecondaryOpacity(
            pole: RGBComponents,
            surfaces: [RGBComponents]
        ) -> Double? {
            var opacity = 0.60
            while opacity <= 1.000_001 {
                let isReadable = surfaces.allSatisfy { surface in
                    let renderedText = surface.blended(toward: pole, amount: opacity)
                    return renderedText.contrastRatio(with: surface) >= 4.5
                }
                if isReadable {
                    return min(opacity, 1)
                }
                opacity += 0.005
            }
            return nil
        }

        /// 在顶部允许的弱主题占比内寻找满足主要文字对比度的最大混色。
        private static func accessibleTint(
            source: RGBComponents,
            base: RGBComponents,
            maximumStrength: Double,
            primaryText: RGBComponents
        ) -> RGBComponents {
            var strength = maximumStrength
            while strength > 0 {
                let candidate = base.blended(toward: source, amount: strength)
                let hasPrimaryContrast = primaryText.contrastRatio(with: candidate) >= 7
                if hasPrimaryContrast {
                    return candidate
                }
                strength -= 0.005
            }
            return base
        }
    }

    /// 按当前外观解析系统语义表面和项目文字色，供不透明混色与对比度计算使用。
    private struct SystemPalette {
        let page: RGBComponents
        let card: RGBComponents
        let nested: RGBComponents
        let primaryText: RGBComponents
        let secondaryText: RGBComponents

        /// 将 UIKit 动态语义色解析到指定浅深色外观，避免渲染时再次叠加透明度。
        init(colorScheme: ColorScheme) {
            let isDark = colorScheme == .dark
            let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
            let fallbackPage = isDark
                ? RGBComponents(red8: 0x1C, green8: 0x1C, blue8: 0x1E)
                : RGBComponents(red8: 0xF2, green8: 0xF2, blue8: 0xF7)
            let fallbackCard = isDark
                ? RGBComponents(red8: 0x1C, green8: 0x1C, blue8: 0x1E)
                : .white
            let fallbackNested = isDark
                ? RGBComponents(red8: 0x2C, green8: 0x2C, blue8: 0x2E)
                : RGBComponents(red8: 0xF2, green8: 0xF2, blue8: 0xF7)

            page = RGBComponents(
                uiColor: UIColor.systemGroupedBackground.resolvedColor(with: traits)
            ) ?? fallbackPage
            card = RGBComponents(
                uiColor: UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits)
            ) ?? fallbackCard
            nested = RGBComponents(
                uiColor: UIColor.tertiarySystemGroupedBackground.resolvedColor(with: traits)
            ) ?? fallbackNested
            primaryText = isDark
                ? RGBComponents(red8: 0xC6, green8: 0xC8, blue8: 0xCB)
                : RGBComponents(red8: 0x33, green8: 0x33, blue8: 0x33)
            secondaryText = isDark
                ? RGBComponents(red8: 0x8C, green8: 0x92, blue8: 0x9B)
                : RGBComponents(red8: 0x66, green8: 0x66, blue8: 0x66)
        }
    }

    /// 把图表强调色转换为同一前景下均可读的四级色阶，避免低透明色块再次透出页面底色。
    private struct AccentPalette {
        let strong: Color
        let veryLess: Color
        let less: Color
        let more: Color
        let foreground: Color

        /// 选择黑白中对比度更高的一侧，并朝该侧的对立底色生成不透明色阶。
        init(rgbaHex: UInt32) {
            let source = RGBComponents(rgbaHex: rgbaHex)
            let blackContrast = source.contrastRatio(with: .black)
            let whiteContrast = source.contrastRatio(with: .white)
            let usesDarkForeground = blackContrast >= whiteContrast
            let contrastPole: RGBComponents = usesDarkForeground ? .white : .black

            strong = source.color
            veryLess = source.blended(toward: contrastPole, amount: 0.34).color
            less = source.blended(toward: contrastPole, amount: 0.22).color
            more = source.blended(toward: contrastPole, amount: 0.10).color
            foreground = usesDarkForeground ? .black : .white
        }
    }

    /// 月度与每日 Bar 使用独立柔化色板，避免热力图色阶的高识别度直接污染长条图。
    private struct ReadingChartPalette {
        let monthTrack: Color
        let monthColors: [Color]
        let monthForeground: Color
        let dailyColors: [Color]
        let dailyForeground: Color

        /// 复刻 Android 的 HSL 去饱和与不透明卡面混色参数，并优先使用 Android Palette 产出的图表前景色。
        init(
            rgbaHex: UInt32,
            surface: RGBComponents,
            preferredForegroundRGBAHex: UInt32?
        ) {
            let source = RGBComponents(rgbaHex: rgbaHex)
            let preferredForeground = preferredForegroundRGBAHex.map {
                RGBComponents(rgbaHex: $0)
            }
            let monthEnd = source
                .desaturated(by: 0.14)
                .blended(toward: surface, amount: 0.16)
            let monthStart = monthEnd.blended(toward: surface, amount: 0.42)
            let dailyEnd = source
                .desaturated(by: 0.18)
                .blended(toward: surface, amount: 0.22)
            let dailyStart = dailyEnd.blended(toward: surface, amount: 0.48)

            monthTrack = source.blended(toward: surface, amount: 0.84).color
            monthColors = [monthStart.color, monthEnd.color]
            monthForeground = Self.readableForeground(
                preferred: preferredForeground,
                for: [monthStart, monthEnd]
            )
            dailyColors = [dailyStart.color, dailyEnd.color]
            dailyForeground = Self.readableForeground(
                preferred: preferredForeground,
                for: [dailyStart, dailyEnd]
            )
        }

        /// 优先复用 Android 的前景色；失去可读性时回退到当前 iOS 的黑白对比度策略。
        private static func readableForeground(
            preferred: RGBComponents?,
            for backgrounds: [RGBComponents]
        ) -> Color {
            if let preferred,
               backgrounds.allSatisfy({ preferred.contrastRatio(with: $0) >= 3.2 }) {
                return preferred.color
            }

            let minimumBlackContrast = backgrounds
                .map { RGBComponents.black.contrastRatio(with: $0) }
                .min() ?? 1
            let minimumWhiteContrast = backgrounds
                .map { RGBComponents.white.contrastRatio(with: $0) }
                .min() ?? 1

            if minimumBlackContrast >= 4.5 {
                return .black
            }
            if minimumWhiteContrast >= 4.5 {
                return .white
            }
            return minimumBlackContrast >= minimumWhiteContrast ? .black : .white
        }
    }

    /// 页面私有的不透明 sRGB 分量，负责图表色阶混合与 WCAG 相对亮度计算。
    private struct RGBComponents {
        let red: Double
        let green: Double
        let blue: Double

        static let black = RGBComponents(red: 0, green: 0, blue: 0)
        static let white = RGBComponents(red: 1, green: 1, blue: 1)

        /// 忽略领域值中的 alpha，只读取封面算法已经归一化的 RGB。
        init(rgbaHex: UInt32) {
            red = Double((rgbaHex >> 24) & 0xFF) / 255
            green = Double((rgbaHex >> 16) & 0xFF) / 255
            blue = Double((rgbaHex >> 8) & 0xFF) / 255
        }

        /// 从已按外观解析的 UIKit 语义色读取不透明 sRGB 分量。
        init?(uiColor: UIColor) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return nil
            }
            self.init(red: Double(red), green: Double(green), blue: Double(blue))
        }

        /// 从标准化 RGB 分量构造颜色组件。
        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// 从 8bit 分量构造颜色，和项目固定文字语义色保持同源。
        init(red8: UInt8, green8: UInt8, blue8: UInt8) {
            self.init(
                red: Double(red8) / 255,
                green: Double(green8) / 255,
                blue: Double(blue8) / 255
            )
        }

        var color: Color {
            color(opacity: 1)
        }

        /// 以当前 RGB 和指定透明度生成 SwiftUI 颜色，供半透明卡面与嵌套表面复用。
        func color(opacity: Double) -> Color {
            Color.xmSRGB(
                red: red,
                green: green,
                blue: blue,
                opacity: min(max(opacity, 0), 1)
            )
        }

        var uiColor: UIColor {
            UIColor.xmSRGB(
                red: CGFloat(red),
                green: CGFloat(green),
                blue: CGFloat(blue),
                alpha: 1
            )
        }

        var relativeLuminance: Double {
            0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
        }

        /// 沿 sRGB 分量向对比度安全极点混合，保持生成色完全不透明。
        func blended(toward target: RGBComponents, amount: Double) -> RGBComponents {
            let clampedAmount = min(max(amount, 0), 1)
            return RGBComponents(
                red: red + (target.red - red) * clampedAmount,
                green: green + (target.green - green) * clampedAmount,
                blue: blue + (target.blue - blue) * clampedAmount
            )
        }

        /// 按 Android ColorUtils 的 HSL 规则降低饱和度，同时保持色相与明度不变。
        func desaturated(by amount: Double) -> RGBComponents {
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            guard delta > 0 else { return self }

            let lightness = (maximum + minimum) / 2
            let saturation = delta / (1 - abs(2 * lightness - 1))
            let reducedSaturation = saturation * (1 - min(max(amount, 0), 1))
            let hueSector: Double
            if maximum == red {
                hueSector = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hueSector = ((blue - red) / delta) + 2
            } else {
                hueSector = ((red - green) / delta) + 4
            }
            let normalizedHueSector = hueSector < 0 ? hueSector + 6 : hueSector
            let chroma = (1 - abs(2 * lightness - 1)) * reducedSaturation
            let secondary = chroma * (1 - abs(normalizedHueSector.truncatingRemainder(dividingBy: 2) - 1))
            let matched = lightness - chroma / 2
            let components: (Double, Double, Double)

            switch normalizedHueSector {
            case 0..<1:
                components = (chroma, secondary, 0)
            case 1..<2:
                components = (secondary, chroma, 0)
            case 2..<3:
                components = (0, chroma, secondary)
            case 3..<4:
                components = (0, secondary, chroma)
            case 4..<5:
                components = (secondary, 0, chroma)
            default:
                components = (chroma, 0, secondary)
            }

            return RGBComponents(
                red: components.0 + matched,
                green: components.1 + matched,
                blue: components.2 + matched
            )
        }

        /// 返回当前颜色与另一不透明颜色的 WCAG 对比度。
        func contrastRatio(with other: RGBComponents) -> Double {
            let lighter = max(relativeLuminance, other.relativeLuminance)
            let darker = min(relativeLuminance, other.relativeLuminance)
            return (lighter + 0.05) / (darker + 0.05)
        }

        /// 把 sRGB 分量转换为 WCAG 相对亮度使用的线性分量。
        private func linearized(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
    }
}

/// 以内容完整高度承载同一次主题状态提交产生的单向封面渐变。
struct BookReadingDetailAtmosphere: View {
    let theme: BookReadingDetailTheme

    var body: some View {
        ZStack {
            theme.neutralBackground

            if theme.isCoverDerived {
                LinearGradient(
                    colors: [theme.gradientStartColor, theme.gradientEndColor],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }
}

/// 区分可交互页面与只读长图，确保两种载体复用同一内容树且只在动作入口上产生差异。
enum BookReadingDetailContentMode {
    case interactive
    case share(BookReadingDetailShareSetting)

    var isInteractive: Bool {
        if case .interactive = self { return true }
        return false
    }

    var shareSetting: BookReadingDetailShareSetting? {
        if case let .share(setting) = self { return setting }
        return nil
    }
}

/// Android 对齐的单书阅读内容：居中书头、属性徽章、简介、统一阅读数据卡、历程卡与可选应用标识。
struct BookReadingDetailContent: View {
    let snapshot: BookReadingDetailSnapshot
    let mode: BookReadingDetailContentMode
    let theme: BookReadingDetailTheme
    @Binding var ratingValue: Double
    @Binding var expandedMonthIDs: Set<MonthlyReadingChart.MonthID>
    var onOpenCover: (() -> Void)?
    var onOpenBookInfo: (() -> Void)?
    var onRatingChanged: ((Double) -> Void)?
    var onChangeReadingStatus: (() -> Void)?
    var onEditReadingStatus: ((BookReadingStatusHistoryItem) -> Void)?
    var onUpdateReadingProgress: (() -> Void)?

    var body: some View {
        VStack(alignment: .center, spacing: Spacing.contentEdge) {
            bookHero

            if shouldShowSummary,
               TimelineMeaningfulText.hasMeaningfulHTML(snapshot.book.summary) {
                summaryCard
            }

            if shouldShowReadingData {
                readingDataCard
            }

            if shouldShowTimeline {
                timelineCard
            }

            if shouldShowAppIdentity {
                appIdentityCard
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private extension BookReadingDetailContent {
    var shouldShowBookAttributes: Bool {
        mode.shareSetting?.showsBookAttributes ?? true
    }

    var shouldShowSummary: Bool {
        mode.shareSetting?.showsBookSummary ?? true
    }

    var shouldShowHeatmap: Bool {
        mode.shareSetting?.showsHeatmap ?? true
    }

    var shouldShowAnalytics: Bool {
        mode.shareSetting?.showsReadingAnalytics ?? true
    }

    var shouldShowMonthlyChart: Bool {
        (mode.shareSetting?.showsMonthlyChart ?? true) && !snapshot.monthlyDurations.isEmpty
    }

    var shouldShowReadingData: Bool {
        shouldShowHeatmap || shouldShowAnalytics || shouldShowMonthlyChart
    }

    var shouldShowTimeline: Bool {
        mode.shareSetting?.showsReadingTimeline ?? true
    }

    var shouldShowAppIdentity: Bool {
        mode.shareSetting?.showsAppIdentity ?? false
    }

    var bookHero: some View {
        VStack(spacing: Spacing.none) {
            actionContainer(action: mode.isInteractive ? onOpenCover : nil) {
                XMBookCover.fixedWidth(
                    120,
                    urlString: snapshot.book.coverURL,
                    cornerRadius: CornerRadius.inlayMedium,
                    border: .init(color: theme.border, width: StrokeWidth.hairline)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 5)
            }
            .accessibilityLabel("预览《\(snapshot.book.name)》封面")

            Spacer()
                .frame(height: Spacing.contentEdge)

            Text(snapshot.book.name)
                .font(BookReadingDetailTypography.heroTitle)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.contentEdge)

            Spacer()
                .frame(height: Spacing.compact)

            BookReadingDetailRatingCapsule(
                value: $ratingValue,
                score: snapshot.book.score,
                isInteractive: mode.isInteractive,
                background: theme.attributeBackground,
                border: theme.border,
                onRatingChanged: onRatingChanged
            )

            if !bookInformation.isEmpty {
                Spacer()
                    .frame(height: Spacing.compact)

                actionContainer(action: mode.isInteractive ? onOpenBookInfo : nil) {
                    HStack(spacing: Spacing.compact) {
                        Text(bookInformation)
                            .font(BookReadingDetailTypography.bookInformation)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.center)
                        if mode.isInteractive, onOpenBookInfo != nil {
                            Image(systemName: "chevron.right")
                                .font(BookReadingDetailTypography.attributeIcon)
                                .foregroundStyle(Color.iconSecondary)
                        }
                    }
                    .padding(.horizontal, Spacing.half)
                }
                .accessibilityLabel("查看书籍资料")
            }

            if shouldShowBookAttributes {
                Spacer()
                    .frame(height: bookInformation.isEmpty ? Spacing.compact : Spacing.base)
                attributeBadges
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.compact)
    }

    var attributeBadges: some View {
        BookReadingAttributeFlowLayout(spacing: Spacing.half) {
            readingStatusBadge
            if let groupName = snapshot.book.groupNames.first, !groupName.isEmpty {
                attributeBadge(icon: "folder", text: groupName)
            }
            if !snapshot.book.sourceName.isEmpty {
                attributeBadge(icon: "safari", text: snapshot.book.sourceName)
            }
            attributeBadge(icon: "book.closed", text: bookTypeText)
            if let wordCountText {
                wordCountBadge(text: wordCountText)
            }
            if Int(snapshot.book.price) != 0 {
                attributeBadge(
                    icon: "yensign.circle",
                    text: "\(snapshot.book.price.formatted(.number.precision(.fractionLength(0...2)))) 元"
                )
            }
            ForEach(snapshot.book.tagNames, id: \.self) { tag in
                attributeBadge(icon: "tag", text: tag)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.double)
    }

    var readingStatusBadge: some View {
        actionContainer(action: mode.isInteractive ? onChangeReadingStatus : nil) {
            BookReadingDetailAttributeBadge(
                icon: .system(statusSymbol(snapshot.book.readStatusID)),
                text: snapshot.book.readStatusName,
                foreground: .white,
                background: statusColor(snapshot.book.readStatusID),
                border: theme.border
            )
        }
        .accessibilityLabel("阅读状态：\(snapshot.book.readStatusName)")
    }

    func attributeBadge(icon: String, text: String) -> some View {
        BookReadingDetailAttributeBadge(
            icon: .system(icon),
            text: text,
            foreground: .textPrimary,
            background: theme.attributeBackground,
            border: theme.border
        )
    }

    /// 使用 Android 同款单字母 A 表达字数，避免 `textformat.abc` 在中文环境中本地化成“甲乙丙”。
    func wordCountBadge(text: String) -> some View {
        BookReadingDetailAttributeBadge(
            icon: .monogram("A"),
            text: text,
            foreground: .textPrimary,
            background: theme.attributeBackground,
            border: theme.border
        )
    }

    var summaryCard: some View {
        themedCard {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("书籍简介")
                    .font(BookReadingDetailTypography.summaryTitle)
                    .foregroundStyle(theme.onCardPrimary)

                summaryContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.top, Spacing.contentEdge)
            .padding(.bottom, Spacing.half)
        }
    }

    @ViewBuilder
    var summaryContent: some View {
        if mode.isInteractive {
            ExpandableRichText(
                html: snapshot.book.summary,
                baseFont: BookReadingDetailTypography.summaryBodyUIFont,
                textColor: theme.onCardPrimaryUIColor,
                lineSpacing: Spacing.half,
                actionColor: theme.onCardSecondary
            )
            .equatable()
        } else {
            Text(TimelineMeaningfulText.strippedHTML(snapshot.book.summary))
                .font(BookReadingDetailTypography.summaryBody)
                .foregroundStyle(theme.onCardPrimary)
                .lineLimit(3)
                .truncationMode(.tail)
        }
    }

    var readingDataCard: some View {
        detailCard(title: "阅读数据") {
            VStack(alignment: .leading, spacing: Spacing.none) {
                if shouldShowHeatmap {
                    VStack(alignment: .trailing, spacing: Spacing.cozy) {
                        CalendarHeatmap(
                            months: calendarHeatmapMonths,
                            statisticsDataType: .all,
                            style: theme.calendarStyle,
                            isScrollEnabled: mode.isInteractive
                        )
                        HeatmapLegend(
                            palette: theme.heatmapPalette,
                            style: theme.heatmapLegendStyle
                        )
                    }
                    .dynamicTypeSize(.large)
                    .padding(Spacing.base)
                    .background(theme.nestedBackground, in: RoundedRectangle(
                        cornerRadius: CornerRadius.blockLarge,
                        style: .continuous
                    ))
                }

                if shouldShowAnalytics {
                    if shouldShowHeatmap {
                        Spacer()
                            .frame(height: Spacing.base)
                    }
                    analyticsGrid
                }

                if shouldShowMonthlyChart {
                    if shouldShowHeatmap || shouldShowAnalytics {
                        Spacer()
                            .frame(height: Spacing.contentEdge)
                    }
                    MonthlyReadingChart(
                        months: monthlyChartMonths,
                        expandedMonthIDs: $expandedMonthIDs,
                        style: theme.monthlyChartStyle
                    )
                }
            }
        }
    }

    var analyticsGrid: some View {
        BookReadingDetailAnalyticsGrid(
            metrics: analyticsMetrics,
            primaryTextColor: theme.onCardPrimary,
            secondaryTextColor: theme.onCardSecondary,
            onSelectProgress: mode.isInteractive ? onUpdateReadingProgress : nil
        )
        .padding(.horizontal, Spacing.base)
    }

    var analyticsMetrics: [BookReadingDetailAnalyticsMetric] {
        let referenceDate = Date()
        let analytics = snapshot.analytics
        let readingDayMetric = BookReadingDetailAnalyticsMetric(
            id: .readingDays,
            title: "阅读天数",
            valueParts: analytics.readingDayCount == 0
                ? [.empty]
                : [.number(analytics.readingDayCount), .unit("天")],
            subtitle: analytics.readingDayCount == 0
                ? "还没开始阅读"
                : "\(smartDate(analytics.lastReadingAt, relativeTo: referenceDate)) · 上次阅读"
        )
        let progressMetric = BookReadingDetailAnalyticsMetric(
            id: .progress,
            title: "阅读进度",
            valueParts: progressPercentageText == "--"
                ? [.empty]
                : [.number(progressPercentageText), .unit("%")],
            subtitle: progressPositionText
        )
        let durationMetric = BookReadingDetailAnalyticsMetric(
            id: .duration,
            title: "阅读时长",
            valueParts: analytics.totalReadingSeconds == 0
                ? [.empty]
                : BookReadingDetailFormatting.compactDurationParts(analytics.totalReadingSeconds).map {
                    $0.role == .number ? .number($0.text) : .unit($0.text)
                },
            subtitle: analytics.totalReadingSeconds == 0 || analytics.actualStartAt == nil
                ? "暂无累计时长"
                : "\(smartDate(analytics.actualStartAt, relativeTo: referenceDate)) · 开始阅读"
        )
        let noteMetric = BookReadingDetailAnalyticsMetric(
            id: .notes,
            title: "书摘数量",
            valueParts: analytics.noteCount == 0
                ? [.empty]
                : [.number(analytics.noteCount), .unit("条")],
            subtitle: analytics.noteCount == 0
                ? "还没有摘录"
                : (analytics.ideaCount == 0 ? "还没有记录过想法" : "\(analytics.ideaCount)条想法")
        )
        return [readingDayMetric, progressMetric, durationMetric, noteMetric]
    }

    var timelineCard: some View {
        themedCard {
            VStack(alignment: .leading, spacing: Spacing.contentEdge) {
                HStack(spacing: Spacing.base) {
                    Text("阅读历程")
                        .font(BookReadingDetailTypography.sectionTitle)
                        .foregroundStyle(theme.onCardPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if mode.isInteractive, let onChangeReadingStatus {
                        Button("修改状态", action: onChangeReadingStatus)
                            .font(BookReadingDetailTypography.timelineAction)
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.onCardPrimary)
                            .accessibilityHint("新增一条阅读状态记录")
                    }
                }

                ReadingStatusTimeline(
                    items: timelineItems,
                    style: theme.timelineStyle,
                    onSelectItem: mode.isInteractive ? { item in
                        guard let source = snapshot.statusHistory.first(where: { $0.id == item.id }),
                              source.recordID != nil else { return }
                        onEditReadingStatus?(source)
                    } : nil
                )
            }
            .padding(Spacing.contentEdge)
        }
    }

    var appIdentityCard: some View {
        themedCard {
            HStack(spacing: Spacing.cozy) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .background(theme.nestedBackground, in: RoundedRectangle(
                        cornerRadius: CornerRadius.blockLarge,
                        style: .continuous
                    ))
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("XMNote")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(theme.onCardPrimary)
                    Text("记录那些打动过你的文字")
                        .font(AppTypography.caption)
                        .foregroundStyle(theme.onCardSecondary)
                }
                Spacer(minLength: Spacing.cozy)
                Image("AppQRCode")
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityLabel("XMNote 下载二维码")
            }
            .padding(Spacing.contentEdge)
        }
    }

    func detailCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        themedCard {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(BookReadingDetailTypography.sectionTitle)
                    .foregroundStyle(theme.onCardPrimary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
    }

    /// 外层主卡使用 Android 同源半透明纸面；主题无效或降低透明度时由主题提供不透明表面。
    func themedCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: CornerRadius.containerLarge,
            style: .continuous
        )
        return content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardSurface, in: shape)
            .overlay {
                shape
                    .stroke(theme.border, lineWidth: StrokeWidth.hairline)
            }
    }

    @ViewBuilder
    func actionContainer<Content: View>(
        action: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let action {
            Button(action: action, label: content)
                .buttonStyle(.plain)
        } else {
            content()
        }
    }

    var bookInformation: String {
        [
            snapshot.book.author,
            snapshot.book.translator.isEmpty ? "" : "译者 \(snapshot.book.translator)",
            snapshot.book.press,
            snapshot.book.publicationDate
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " · ")
    }

    var bookTypeText: String {
        let type = snapshot.book.bookType == 1 ? "电子书" : "纸质书"
        let effectiveUnit = snapshot.book.bookType == 0 ? Int64(2) : snapshot.book.positionUnit
        let unit = switch effectiveUnit {
        case 0: "进度"
        case 1: "位置"
        default: "页码"
        }
        return "\(type) · \(unit)"
    }

    var wordCountText: String? {
        guard let value = snapshot.book.wordCount, value > 0 else { return nil }
        if value >= 10_000 {
            return "\((Double(value) / 10_000).formatted(.number.precision(.fractionLength(0...1)))) 万字"
        }
        return "\(value) 字"
    }

    var progressPercentageText: String {
        guard let fraction = snapshot.analytics.progress.fraction, fraction > 0 else { return "--" }
        return (fraction * 100).formatted(.number.precision(.fractionLength(0...2)))
    }

    var progressPositionText: String {
        let progress = snapshot.analytics.progress
        guard progress.currentValue > 0,
              let total = progress.totalValue,
              total > 0 else {
            return progressPercentageText == "--" ? "尚无阅读进度" : ""
        }
        return "位置 · \(Int64(progress.currentValue.rounded()))/\(total)"
    }

    var calendarHeatmapMonths: [CalendarHeatmapMonth] {
        let calendar = Calendar.autoupdatingCurrent
        guard let rawStart = snapshot.heatmapEarliestDate ?? snapshot.heatmapLatestDate,
              let rawEnd = snapshot.heatmapLatestDate ?? snapshot.heatmapEarliestDate else {
            return []
        }
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: min(rawStart, rawEnd))) ?? rawStart
        let end = calendar.date(from: calendar.dateComponents([.year, .month], from: max(rawStart, rawEnd))) ?? rawEnd
        var result: [CalendarHeatmapMonth] = []
        var cursor = start
        while cursor <= end {
            result.append(CalendarHeatmapMonth(monthStart: cursor, days: snapshot.heatmapDays))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    var monthlyChartMonths: [MonthlyReadingChart.Month] {
        let referenceDate = Date()
        return snapshot.monthlyDurations.map { month in
            MonthlyReadingChart.Month(
                id: .init(year: month.year, month: month.month),
                summaryText: BookReadingDetailFormatting.monthSummary(
                    year: month.year,
                    month: month.month,
                    seconds: month.totalSeconds,
                    relativeTo: referenceDate
                ),
                days: month.days.map { day in
                    MonthlyReadingChart.Day(
                        id: Int64((day.date.timeIntervalSince1970 * 1_000).rounded()),
                        dateText: BookReadingDetailFormatting.dayLabel(day.date),
                        durationSeconds: day.seconds
                    )
                }
            )
        }
    }

    var timelineItems: [ReadingStatusTimeline.Item] {
        snapshot.statusHistory.map { item in
            ReadingStatusTimeline.Item(
                id: item.id,
                status: ReadingStatusTimeline.Status(rawValue: item.isSyntheticShelfNode ? -1 : item.statusID) ?? .unknown,
                date: Date(timeIntervalSince1970: Double(item.changedAt) / 1_000),
                isEditable: item.recordID != nil
            )
        }
    }

    func statusSymbol(_ id: Int64) -> String {
        switch id {
        case 1: "heart"
        case 2: "book"
        case 3: "checkmark.circle"
        case 5: "shippingbox"
        default: "xmark.circle"
        }
    }

    func statusColor(_ id: Int64) -> Color {
        ReadingStatusPresentation.color(for: id) ?? ReadingStatusPresentation.abandoned
    }

    func smartDate(_ milliseconds: Int64?, relativeTo referenceDate: Date) -> String {
        guard let milliseconds, milliseconds > 0 else { return "" }
        return BookReadingDetailFormatting.smartDate(
            Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            relativeTo: referenceDate
        )
    }
}

/// 数据概览固定的四项语义顺序；普通字号为 2×2，辅助功能字号按同一顺序退化为单列。
private struct BookReadingDetailAnalyticsMetric: Identifiable {
    enum ID: Hashable {
        case readingDays
        case progress
        case duration
        case notes
    }

    let id: ID
    let title: String
    let valueParts: [BookReadingDetailAnalyticsValuePart]
    let subtitle: String
}

/// 指标值的数字、单位与空态角色，确保不把“小时/分钟”等单位放大成主数字。
private enum BookReadingDetailAnalyticsValuePart: Equatable {
    case number(String)
    case unit(String)
    case empty

    static func number(_ value: Int) -> Self {
        .number(String(value))
    }

    var text: String {
        switch self {
        case let .number(value), let .unit(value): value
        case .empty: "--"
        }
    }

    var isUnit: Bool {
        if case .unit = self { return true }
        return false
    }

    var isEmpty: Bool {
        self == .empty
    }
}

/// 以统一字体行盒约束四项指标；每个标题、值和副说明都占一行，从结构上保证同排基线一致。
private struct BookReadingDetailAnalyticsGrid: View {
    let metrics: [BookReadingDetailAnalyticsMetric]
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let onSelectProgress: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: Spacing.base
        ) {
            ForEach(metrics) { metric in
                metricContainer(metric)
            }
        }
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), alignment: .topLeading)]
        }
        return [
            GridItem(.flexible(), spacing: Spacing.double, alignment: .topLeading),
            GridItem(.flexible(), alignment: .topLeading)
        ]
    }

    @ViewBuilder
    private func metricContainer(_ metric: BookReadingDetailAnalyticsMetric) -> some View {
        if metric.id == .progress, let onSelectProgress {
            Button(action: onSelectProgress) {
                metricContent(metric)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更新阅读进度")
        } else {
            metricContent(metric)
        }
    }

    private func metricContent(_ metric: BookReadingDetailAnalyticsMetric) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(metric.title)
                .font(ReadingSummaryTypography.metricTitle)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: Spacing.none) {
                ForEach(Array(metric.valueParts.enumerated()), id: \.offset) { _, part in
                    Text(part.text)
                        .font(
                            part.isUnit
                                ? ReadingSummaryTypography.metricUnit
                                : ReadingSummaryTypography.metricNumber
                        )
                        .monospacedDigit()
                }
            }
            .foregroundStyle(
                metric.valueParts.contains(where: \.isEmpty)
                    ? secondaryTextColor
                    : primaryTextColor
            )
            .lineLimit(1)
            .minimumScaleFactor(0.76)

            Text(metric.subtitle.isEmpty ? "\u{00A0}" : metric.subtitle)
                .font(ReadingSummaryTypography.metricSubtitle)
                .foregroundStyle(secondaryTextColor)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.76)
                .accessibilityHidden(metric.subtitle.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// 阅读详情页局部排版组合；书名按跨平台字体度量补偿，其余层级复刻 Android 详情页的明确规格。
private enum BookReadingDetailTypography {
    static let heroTitle = Font.custom("STSongti-SC-Bold", size: 19, relativeTo: .title2)

    static let bookInformation = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .subheadline
    )

    static let attribute = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption
    )

    static let attributeIcon = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .caption
    )

    static let attributeMonogram = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .caption,
        weight: .semibold
    )

    static let sectionTitle = AppTypography.fixed(
        baseSize: 18,
        relativeTo: .headline,
        weight: .semibold
    )

    static let summaryTitle = sectionTitle

    static let summaryBody = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .body
    )

    static let summaryBodyUIFont = AppTypography.uiFixed(
        baseSize: 14,
        textStyle: .body
    )

    static let timelineAction = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .subheadline,
        weight: .medium
    )
}

/// 评分胶囊将 28pt 视觉表面和 44pt 交互热区解耦，既对齐 Android 密度又保留 iOS 可点击性。
private struct BookReadingDetailRatingCapsule: View {
    @Binding var value: Double
    let score: Int64
    let isInteractive: Bool
    let background: Color
    let border: Color
    let onRatingChanged: ((Double) -> Void)?

    @ScaledMetric(relativeTo: .caption) private var visualHeight: CGFloat = 28

    var body: some View {
        Group {
            if isInteractive {
                XMRatingBar(
                    value: $value,
                    preset: .capsule,
                    onRatingChanged: { value in onRatingChanged?(value) }
                )
            } else {
                XMRatingBar(score: score, preset: .capsule)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: InteractionMetrics.minimumTouchTarget)
        .background {
            Capsule()
                .fill(background)
                .frame(height: visualHeight)
        }
        .overlay {
            Capsule()
                .stroke(border, lineWidth: StrokeWidth.hairline)
                .frame(height: visualHeight)
        }
    }
}

/// 区分系统语义图标与 Android 字数徽章使用的拉丁字母标记。
private enum BookReadingDetailAttributeIcon {
    case system(String)
    case monogram(String)
}

/// 书籍属性徽章显式约束图标与文本，避免系统 Label 在紧凑换行中压缩或隐藏语义图标。
private struct BookReadingDetailAttributeBadge: View {
    let icon: BookReadingDetailAttributeIcon
    let text: String
    let foreground: Color
    let background: Color
    let border: Color

    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 14

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Group {
                switch icon {
                case let .system(name):
                    Image(systemName: name)
                        .font(BookReadingDetailTypography.attributeIcon)
                case let .monogram(value):
                    Text(value)
                        .font(BookReadingDetailTypography.attributeMonogram)
                }
            }
            .frame(width: iconSize, height: iconSize)

            Text(text)
                .font(BookReadingDetailTypography.attribute)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Spacing.tight)
        .padding(.vertical, Spacing.compact)
        .background(background, in: RoundedRectangle(
            cornerRadius: CornerRadius.blockSmall,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                .stroke(border, lineWidth: StrokeWidth.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 将属性徽章按可用宽度自然换行，避免固定列宽截断来源、标签和分组名称。
private struct BookReadingAttributeFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maximumWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                maximumWidth = max(maximumWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        maximumWidth = max(maximumWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? maximumWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var rows: [[Int]] = []
        var currentRow: [Int] = []
        var currentWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = currentWidth + (currentRow.isEmpty ? 0 : spacing) + size.width
            if !currentRow.isEmpty, proposedWidth > bounds.width {
                rows.append(currentRow)
                currentRow = [index]
                currentWidth = size.width
            } else {
                currentRow.append(index)
                currentWidth = proposedWidth
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        var y = bounds.minY
        for row in rows {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let rowWidth = sizes.reduce(0) { $0 + $1.width }
                + spacing * CGFloat(max(0, row.count - 1))
            let rowHeight = sizes.map(\.height).max() ?? 0
            var x = bounds.midX - rowWidth / 2

            for (offset, index) in row.enumerated() {
                let size = sizes[offset]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
