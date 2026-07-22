import Foundation
import UIKit

/**
 * [INPUT]: 依赖 XMCoverImageLoading 加载封面，依赖 ReadCalendarSegmentColor 表达事件条颜色结果
 * [OUTPUT]: 对外提供 ReadCalendarColorRepository（Android Palette 等价量化、事件色修正、内存缓存与稳定哈希回退）
 * [POS]: Data 层阅读日历颜色仓储，隔离封面解码、取色算法、并发合并与刷新语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历颜色仓储，按 Android 端同一套 Palette 与事件色规则生成可渲染颜色。
struct ReadCalendarColorRepository: ReadCalendarColorRepositoryProtocol {
    private let imageLoader: any XMCoverImageLoading
    private let cacheStore: ReadCalendarColorCacheStore

    /// 注入统一封面加载器；颜色结果仅在进程内缓存，图片下载仍复用 Nuke 缓存。
    init(imageLoader: any XMCoverImageLoading = NukeCoverImageLoader()) {
        self.imageLoader = imageLoader
        self.cacheStore = .shared
    }

    /// 读取事件条颜色并复用进程内成功缓存。
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> ReadCalendarSegmentColor {
        await resolveEventColor(
            bookId: bookId,
            bookName: bookName,
            coverURL: coverURL,
            forceRefresh: false
        )
    }

    /// 解析事件条颜色；强制刷新跳过成功颜色缓存，但会与同源的并发请求合并。
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String,
        forceRefresh: Bool
    ) async -> ReadCalendarSegmentColor {
        let normalizedName = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCoverURL = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = Self.cacheKey(bookId: bookId)
        let sourceSignature = Self.sourceSignature(
            bookName: normalizedName,
            coverURL: normalizedCoverURL
        )

        switch await cacheStore.begin(
            key: cacheKey,
            sourceSignature: sourceSignature,
            forceRefresh: forceRefresh
        ) {
        case let .cached(color), let .joined(color):
            return color
        case .owner:
            break
        }

        let result = await resolveUncachedColor(
            bookName: bookName,
            normalizedCoverURL: normalizedCoverURL
        )
        await cacheStore.finish(
            result,
            for: cacheKey,
            sourceSignature: sourceSignature
        )
        return result
    }

    /// 所有异步图片与量化工作均可随调用任务取消；失败结果只返回、不写入跨请求缓存。
    private func resolveUncachedColor(
        bookName: String,
        normalizedCoverURL: String
    ) async -> ReadCalendarSegmentColor {
        let fallback = Self.resolveEventColor(swatches: [], fallbackSeed: bookName)
        guard let url = XMImageRequestBuilder.normalizedURL(from: normalizedCoverURL) else {
            return fallback.asDomainColor(state: .failed)
        }

        do {
            let image = try await imageLoader.loadImage(for: XMImageLoadRequest(url: url))
            try Task.checkCancellation()
            guard let swatches = await Self.extractPaletteAsync(from: image), !swatches.isEmpty else {
                return fallback.asDomainColor(state: .failed)
            }
            try Task.checkCancellation()
            return Self.resolveEventColor(
                swatches: swatches,
                fallbackSeed: bookName
            ).asDomainColor(state: .resolved)
        } catch {
            return fallback.asDomainColor(state: .failed)
        }
    }
}

// MARK: - Android Palette Equivalent

private extension ReadCalendarColorRepository {
    /// 在后台线程将封面缩放为 Android 同尺寸位图并执行 5-bit median-cut 量化。
    nonisolated static func extractPaletteAsync(from image: UIImage) async -> [PaletteSwatch]? {
        await Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return extractPalette(from: image)
        }.value
    }

    /// 固定使用 64×96 像素与最多 24 个色板，匹配 Android 阅读日历专用 Palette 配置。
    nonisolated static func extractPalette(from image: UIImage) -> [PaletteSwatch] {
        let targetWidth = 64
        let targetHeight = 96
        let bytesPerPixel = 4
        let bytesPerRow = targetWidth * bytesPerPixel
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return []
        }

        context.interpolationQuality = .medium
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        UIGraphicsPopContext()

        guard let rawBuffer = context.data else { return [] }
        let byteCount = targetWidth * targetHeight * bytesPerPixel
        let pixels = rawBuffer.bindMemory(to: UInt8.self, capacity: byteCount)
        var quantizedPixels: [Int] = []
        quantizedPixels.reserveCapacity(targetWidth * targetHeight)

        var index = 0
        while index < byteCount {
            quantizedPixels.append(
                quantize(red: pixels[index], green: pixels[index + 1], blue: pixels[index + 2])
            )
            index += bytesPerPixel
        }

        var quantizer = AndroidPaletteQuantizer(pixels: quantizedPixels, maxColors: 24)
        return quantizer.quantize()
    }

    /// 把 RGB888 缩到 Android ColorCutQuantizer 使用的 RGB555 索引。
    nonisolated static func quantize(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        (Int(red >> 3) << 10) | (Int(green >> 3) << 5) | Int(blue >> 3)
    }
}

/// AndroidX Palette 1.0.0 ColorCutQuantizer 的等价实现。
nonisolated private struct AndroidPaletteQuantizer {
    private var colors: [Int]
    private var histogram: [Int]
    private let maxColors: Int

    /// 构建 RGB555 直方图，并应用 Android Palette 默认的黑、白与红色 I 线过滤。
    init(pixels: [Int], maxColors: Int) {
        var histogram = Array(repeating: 0, count: 1 << 15)
        for pixel in pixels {
            histogram[pixel] += 1
        }
        for color in histogram.indices where histogram[color] > 0 {
            if Self.shouldIgnore(color: Self.approximateToRGB888(color)) {
                histogram[color] = 0
            }
        }
        self.colors = histogram.indices.filter { histogram[$0] > 0 }
        self.histogram = histogram
        self.maxColors = maxColors
    }

    /// 返回最多 24 个色板；颜色较多时按最大体积优先切分色彩空间。
    mutating func quantize() -> [PaletteSwatch] {
        guard !colors.isEmpty else { return [] }
        if colors.count <= maxColors {
            return colors.map {
                PaletteSwatch(rgb: Self.approximateToRGB888($0), population: histogram[$0])
            }
        }

        var boxes = [PaletteVBox(lower: 0, upper: colors.count - 1)]
        while boxes.count < maxColors {
            guard let splitIndex = boxes.indices
                .filter({ boxes[$0].canSplit })
                .max(by: { boxVolume(boxes[$0]) < boxVolume(boxes[$1]) }) else {
                break
            }

            let oldBox = boxes.remove(at: splitIndex)
            let splitPoint = findSplitPoint(for: oldBox)
            let lowerBox = PaletteVBox(lower: oldBox.lower, upper: splitPoint)
            let upperBox = PaletteVBox(lower: splitPoint + 1, upper: oldBox.upper)
            boxes.append(upperBox)
            boxes.append(lowerBox)
        }

        return boxes.compactMap { box in
            guard let swatch = averageColor(in: box), !Self.shouldIgnore(color: swatch.rgb) else {
                return nil
            }
            return swatch
        }
    }

    private func bounds(for box: PaletteVBox) -> PaletteBounds {
        var minRed = Int.max
        var maxRed = Int.min
        var minGreen = Int.max
        var maxGreen = Int.min
        var minBlue = Int.max
        var maxBlue = Int.min
        var population = 0
        for index in box.lower...box.upper {
            let color = colors[index]
            let red = Self.red5(color)
            let green = Self.green5(color)
            let blue = Self.blue5(color)
            minRed = min(minRed, red)
            maxRed = max(maxRed, red)
            minGreen = min(minGreen, green)
            maxGreen = max(maxGreen, green)
            minBlue = min(minBlue, blue)
            maxBlue = max(maxBlue, blue)
            population += histogram[color]
        }
        return PaletteBounds(
            minRed: minRed,
            maxRed: maxRed,
            minGreen: minGreen,
            maxGreen: maxGreen,
            minBlue: minBlue,
            maxBlue: maxBlue,
            population: population
        )
    }

    private func boxVolume(_ box: PaletteVBox) -> Int {
        let value = bounds(for: box)
        return (value.maxRed - value.minRed + 1)
            * (value.maxGreen - value.minGreen + 1)
            * (value.maxBlue - value.minBlue + 1)
    }

    private mutating func findSplitPoint(for box: PaletteVBox) -> Int {
        let value = bounds(for: box)
        let redLength = value.maxRed - value.minRed
        let greenLength = value.maxGreen - value.minGreen
        let blueLength = value.maxBlue - value.minBlue
        let dimension: PaletteDimension
        if redLength >= greenLength, redLength >= blueLength {
            dimension = .red
        } else if greenLength >= redLength, greenLength >= blueLength {
            dimension = .green
        } else {
            dimension = .blue
        }

        let sorted = colors[box.lower...box.upper].sorted {
            Self.significantKey($0, dimension: dimension)
                < Self.significantKey($1, dimension: dimension)
        }
        colors.replaceSubrange(box.lower...box.upper, with: sorted)

        let midpoint = value.population / 2
        var population = 0
        for index in box.lower...box.upper {
            population += histogram[colors[index]]
            if population >= midpoint {
                return min(box.upper - 1, index)
            }
        }
        return box.lower
    }

    private func averageColor(in box: PaletteVBox) -> PaletteSwatch? {
        var redSum = 0
        var greenSum = 0
        var blueSum = 0
        var population = 0
        for index in box.lower...box.upper {
            let color = colors[index]
            let colorPopulation = histogram[color]
            population += colorPopulation
            redSum += colorPopulation * Self.red5(color)
            greenSum += colorPopulation * Self.green5(color)
            blueSum += colorPopulation * Self.blue5(color)
        }
        guard population > 0 else { return nil }
        let red = Int((Double(redSum) / Double(population)).rounded())
        let green = Int((Double(greenSum) / Double(population)).rounded())
        let blue = Int((Double(blueSum) / Double(population)).rounded())
        return PaletteSwatch(
            rgb: RGBColor(red: UInt8(red << 3), green: UInt8(green << 3), blue: UInt8(blue << 3)),
            population: population
        )
    }

    private static func significantKey(_ color: Int, dimension: PaletteDimension) -> Int {
        switch dimension {
        case .red:
            return color
        case .green:
            return (green5(color) << 10) | (red5(color) << 5) | blue5(color)
        case .blue:
            return (blue5(color) << 10) | (green5(color) << 5) | red5(color)
        }
    }

    private static func approximateToRGB888(_ color: Int) -> RGBColor {
        RGBColor(
            red: UInt8(red5(color) << 3),
            green: UInt8(green5(color) << 3),
            blue: UInt8(blue5(color) << 3)
        )
    }

    private static func shouldIgnore(color: RGBColor) -> Bool {
        let hsl = color.hsl
        let isBlack = hsl.lightness <= 0.05
        let isWhite = hsl.lightness >= 0.95
        let isNearRedILine = hsl.hue >= 10 && hsl.hue <= 37 && hsl.saturation <= 0.82
        return isBlack || isWhite || isNearRedILine
    }

    private static func red5(_ color: Int) -> Int { (color >> 10) & 0x1F }
    private static func green5(_ color: Int) -> Int { (color >> 5) & 0x1F }
    private static func blue5(_ color: Int) -> Int { color & 0x1F }
}

nonisolated private struct PaletteVBox {
    let lower: Int
    let upper: Int
    var canSplit: Bool { upper > lower }
}

nonisolated private struct PaletteBounds {
    let minRed: Int
    let maxRed: Int
    let minGreen: Int
    let maxGreen: Int
    let minBlue: Int
    let maxBlue: Int
    let population: Int
}

nonisolated private enum PaletteDimension {
    case red
    case green
    case blue
}

nonisolated private struct PaletteSwatch {
    let rgb: RGBColor
    let population: Int
}

// MARK: - Android Event Color Resolver

private extension ReadCalendarColorRepository {
    /// 依次复刻 Android BookCoverColorResolver 与 ReadCalendarEventColorResolver。
    nonisolated static func resolveEventColor(
        swatches: [PaletteSwatch],
        fallbackSeed: String
    ) -> ResolvedEventColor {
        let scheme = resolveCoverScheme(swatches: swatches, fallbackSeed: fallbackSeed)
        let baseColor = resolveEventBaseColor(scheme: scheme, swatches: swatches)
        let background = normalizeEventBackground(baseColor.withAlpha(204))
        let text = resolveEventTextColor(background: background, rawText: scheme.onRepresentative)
        return ResolvedEventColor(background: background, text: text)
    }

    nonisolated static func resolveCoverScheme(
        swatches: [PaletteSwatch],
        fallbackSeed: String
    ) -> CoverColorScheme {
        guard !swatches.isEmpty else {
            let seed = normalizeRepresentative(androidGeneratedColor(from: fallbackSeed))
            return CoverColorScheme(
                representative: seed,
                accent: normalizeAccent(seed),
                onRepresentative: readableTextColor(for: seed)
            )
        }

        let candidates = swatches.map { swatch -> CoverColorCandidate in
            let hsl = swatch.rgb.hsl
            return CoverColorCandidate(
                rgb: swatch.rgb,
                population: max(1, swatch.population),
                saturation: hsl.saturation,
                lightness: hsl.lightness
            )
        }
        let representative = candidates.max {
            if $0.population != $1.population { return $0.population < $1.population }
            if $0.saturation != $1.saturation { return $0.saturation < $1.saturation }
            return $0.lightness < $1.lightness
        } ?? candidates[0]
        let representativeColor = normalizeRepresentative(representative.rgb)
        let maxPopulation = max(1, candidates.map(\.population).max() ?? 1)
        let accent = candidates.max {
            accentScore($0, maxPopulation: maxPopulation)
                < accentScore($1, maxPopulation: maxPopulation)
        }?.rgb ?? representativeColor
        return CoverColorScheme(
            representative: representativeColor,
            accent: normalizeAccent(accent),
            onRepresentative: readableTextColor(for: representativeColor)
        )
    }

    nonisolated static func accentScore(
        _ candidate: CoverColorCandidate,
        maxPopulation: Int
    ) -> Double {
        let population = Double(candidate.population) / Double(maxPopulation)
        let lightness = 1 - min(abs(candidate.lightness - 0.52), 0.52)
        return candidate.saturation * 0.58 + lightness * 0.28 + population * 0.14
    }

    nonisolated static func normalizeRepresentative(_ color: RGBColor) -> RGBColor {
        var hsl = color.hsl
        if hsl.saturation < 0.08 {
            hsl.saturation = 0
            hsl.lightness = hsl.lightness.clamped(to: 0.32...0.86)
        } else {
            hsl.saturation = min(hsl.saturation, 0.72)
            hsl.lightness = hsl.lightness.clamped(to: 0.24...0.82)
        }
        return RGBColor(hsl: hsl)
    }

    nonisolated static func normalizeAccent(_ color: RGBColor) -> RGBColor {
        var hsl = color.hsl
        if hsl.saturation < 0.08 {
            hsl.saturation = 0
            hsl.lightness = hsl.lightness.clamped(to: 0.28...0.76)
        } else {
            hsl.saturation = hsl.saturation.clamped(to: 0.22...0.78)
            hsl.lightness = hsl.lightness.clamped(to: 0.24...0.76)
        }
        return RGBColor(hsl: hsl)
    }

    nonisolated static func readableTextColor(for background: RGBColor) -> RGBColor {
        let black = RGBColor.black
        let white = RGBColor.white
        let blackContrast = contrastRatio(black, background)
        let whiteContrast = contrastRatio(white, background)
        if blackContrast >= 3.2, blackContrast >= whiteContrast { return black }
        if whiteContrast >= 3.2 { return white }
        return blackContrast >= whiteContrast ? black : white
    }

    nonisolated static func resolveEventBaseColor(
        scheme: CoverColorScheme,
        swatches: [PaletteSwatch]
    ) -> RGBColor {
        if !swatches.isEmpty, isReplaceableNeutral(scheme.representative),
           let theme = selectEventThemeColor(
            swatches: swatches,
            representative: scheme.representative
           ) {
            return theme
        }
        if isReplaceableNeutral(scheme.representative),
           isUsefulAccent(scheme.accent),
           colorDistance(scheme.representative, scheme.accent) >= 0.12 {
            return scheme.accent
        }
        return scheme.representative
    }

    nonisolated static func selectEventThemeColor(
        swatches: [PaletteSwatch],
        representative: RGBColor
    ) -> RGBColor? {
        let totalPopulation = swatches.reduce(0) { $0 + max(0, $1.population) }
        guard totalPopulation > 0 else { return nil }
        let maxPopulation = max(1, swatches.map { max(1, $0.population) }.max() ?? 1)
        let candidates = swatches.compactMap { swatch -> EventThemeCandidate? in
            let population = max(1, swatch.population)
            let proportion = Double(max(0, swatch.population)) / Double(totalPopulation)
            let hsv = swatch.rgb.hsv
            guard proportion >= 0.006,
                  hsv.saturation >= 0.18,
                  hsv.value >= 0.12,
                  !(hsv.value > 0.94 && hsv.saturation < 0.26) else {
                return nil
            }
            return EventThemeCandidate(
                color: swatch.rgb,
                population: population,
                proportion: proportion,
                hsv: hsv,
                representativeDistance: colorDistance(representative, swatch.rgb)
            )
        }
        return candidates.max {
            let lhs = eventThemeScore($0, maxPopulation: maxPopulation)
            let rhs = eventThemeScore($1, maxPopulation: maxPopulation)
            if lhs != rhs { return lhs < rhs }
            return $0.population < $1.population
        }?.color
    }

    nonisolated static func eventThemeScore(
        _ candidate: EventThemeCandidate,
        maxPopulation: Int
    ) -> Double {
        let saturationFit = 1 - (abs(candidate.hsv.saturation - 0.62) / 0.62).clamped(to: 0...1)
        let vividness = (candidate.hsv.saturation / 0.78).clamped(to: 0...1)
        let valueFit = 1 - (abs(candidate.hsv.value - 0.62) / 0.62).clamped(to: 0...1)
        let proportionFit = (candidate.proportion / 0.08).clamped(to: 0...1)
        let populationFit = (Double(candidate.population) / Double(maxPopulation)).clamped(to: 0...1)
        let distanceFit = (candidate.representativeDistance / 0.55).clamped(to: 0...1)
        return saturationFit * 0.18
            + vividness * 0.24
            + valueFit * 0.22
            + proportionFit * 0.20
            + distanceFit * 0.12
            + populationFit * 0.04
    }

    nonisolated static func isReplaceableNeutral(_ color: RGBColor) -> Bool {
        let hsv = color.hsv
        return hsv.saturation < 0.12
            || (hsv.value > 0.88 && hsv.saturation < 0.20)
            || (hsv.value < 0.24 && hsv.saturation < 0.16)
    }

    nonisolated static func isUsefulAccent(_ color: RGBColor) -> Bool {
        let hsv = color.hsv
        return hsv.saturation >= 0.22 && (0.30...0.88).contains(hsv.value)
    }

    nonisolated static func normalizeEventBackground(_ color: RGBColor) -> RGBColor {
        var hsv = color.hsv
        let saturationMax = hsv.hue < 24 || hsv.hue > 338 ? 0.54 : 0.68
        switch hsv.saturation {
        case ..<0.08:
            hsv.saturation = 0
        case ..<0.22:
            hsv.saturation = min(hsv.saturation * 1.16, 0.24)
        case ..<0.36:
            hsv.saturation = min(hsv.saturation * 1.08, 0.40)
        default:
            hsv.saturation = min(hsv.saturation * 1.04, saturationMax)
        }
        if hsv.value > 0.88 {
            hsv.value = 0.84
        } else if hsv.value < 0.46 {
            hsv.value = 0.52
        }
        return RGBColor(hsv: hsv, alpha: color.alpha)
    }

    nonisolated static func resolveEventTextColor(
        background: RGBColor,
        rawText: RGBColor
    ) -> RGBColor {
        let normalizedRaw = rawText.withAlpha(max(rawText.alpha, 0xE0))
        if contrastRatio(normalizedRaw, background) >= 3.2 {
            return normalizedRaw
        }
        let darkText = RGBColor(red: 0, green: 0, blue: 0, alpha: background.relativeLuminance > 0.72 ? 0xB8 : 0xA8)
        let lightText = RGBColor(red: 255, green: 255, blue: 255, alpha: 0xF4)
        return contrastRatio(darkText, background) > contrastRatio(lightText, background)
            ? darkText
            : lightText
    }

    nonisolated static func colorDistance(_ lhs: RGBColor, _ rhs: RGBColor) -> Double {
        (abs(Double(lhs.red) - Double(rhs.red))
            + abs(Double(lhs.green) - Double(rhs.green))
            + abs(Double(lhs.blue) - Double(rhs.blue))) / (255 * 3)
    }

    nonisolated static func contrastRatio(_ lhs: RGBColor, _ rhs: RGBColor) -> Double {
        let lighter = max(lhs.relativeLuminance, rhs.relativeLuminance)
        let darker = min(lhs.relativeLuminance, rhs.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

nonisolated private struct CoverColorScheme {
    let representative: RGBColor
    let accent: RGBColor
    let onRepresentative: RGBColor
}

nonisolated private struct CoverColorCandidate {
    let rgb: RGBColor
    let population: Int
    let saturation: Double
    let lightness: Double
}

nonisolated private struct EventThemeCandidate {
    let color: RGBColor
    let population: Int
    let proportion: Double
    let hsv: HSVColor
    let representativeDistance: Double
}

nonisolated private struct ResolvedEventColor {
    let background: RGBColor
    let text: RGBColor

    /// 将算法结果转换为领域模型，并由调用方标记真实封面或失败回退来源。
    func asDomainColor(state: ReadCalendarSegmentColorState) -> ReadCalendarSegmentColor {
        ReadCalendarSegmentColor(
            state: state,
            backgroundRGBAHex: background.rgbaHex,
            textRGBAHex: text.rgbaHex
        )
    }
}

nonisolated private struct HSLColor {
    var hue: Double
    var saturation: Double
    var lightness: Double
}

nonisolated private struct HSVColor {
    var hue: Double
    var saturation: Double
    var value: Double
}

nonisolated private struct RGBColor: Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    static let black = RGBColor(red: 0, green: 0, blue: 0)
    static let white = RGBColor(red: 255, green: 255, blue: 255)

    /// 构建不透明 RGB；事件背景与文本可另行覆盖 alpha。
    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 采用 Android ColorUtils.HSLToColor 同等分段与四舍五入规则生成颜色。
    init(hsl: HSLColor, alpha: UInt8 = 255) {
        let hue = ((hsl.hue.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let saturation = hsl.saturation.clamped(to: 0...1)
        let lightness = hsl.lightness.clamped(to: 0...1)
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let match = lightness - 0.5 * chroma
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let components: (Double, Double, Double)
        switch hue {
        case ..<60: components = (chroma, x, 0)
        case ..<120: components = (x, chroma, 0)
        case ..<180: components = (0, chroma, x)
        case ..<240: components = (0, x, chroma)
        case ..<300: components = (x, 0, chroma)
        default: components = (chroma, 0, x)
        }
        self.init(
            red: UInt8(clamping: Int(((components.0 + match) * 255).rounded())),
            green: UInt8(clamping: Int(((components.1 + match) * 255).rounded())),
            blue: UInt8(clamping: Int(((components.2 + match) * 255).rounded())),
            alpha: alpha
        )
    }

    /// 采用 Android HSVToColor 同等分段与四舍五入规则生成颜色。
    init(hsv: HSVColor, alpha: UInt8 = 255) {
        let hue = ((hsv.hue.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let saturation = hsv.saturation.clamped(to: 0...1)
        let value = hsv.value.clamped(to: 0...1)
        let chroma = value * saturation
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let match = value - chroma
        let components: (Double, Double, Double)
        switch hue {
        case ..<60: components = (chroma, x, 0)
        case ..<120: components = (x, chroma, 0)
        case ..<180: components = (0, chroma, x)
        case ..<240: components = (0, x, chroma)
        case ..<300: components = (x, 0, chroma)
        default: components = (chroma, 0, x)
        }
        self.init(
            red: UInt8(clamping: Int(((components.0 + match) * 255).rounded())),
            green: UInt8(clamping: Int(((components.1 + match) * 255).rounded())),
            blue: UInt8(clamping: Int(((components.2 + match) * 255).rounded())),
            alpha: alpha
        )
    }

    var hsl: HSLColor {
        let red = Double(self.red) / 255
        let green = Double(self.green) / 255
        let blue = Double(self.blue) / 255
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let delta = maxChannel - minChannel
        let lightness = (maxChannel + minChannel) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        let hue: Double
        if delta == 0 {
            hue = 0
        } else if maxChannel == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxChannel == green {
            hue = 60 * (((blue - red) / delta) + 2)
        } else {
            hue = 60 * (((red - green) / delta) + 4)
        }
        return HSLColor(hue: hue < 0 ? hue + 360 : hue, saturation: saturation, lightness: lightness)
    }

    var hsv: HSVColor {
        let red = Double(self.red) / 255
        let green = Double(self.green) / 255
        let blue = Double(self.blue) / 255
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let delta = maxChannel - minChannel
        let hue: Double
        if delta == 0 {
            hue = 0
        } else if maxChannel == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxChannel == green {
            hue = 60 * (((blue - red) / delta) + 2)
        } else {
            hue = 60 * (((red - green) / delta) + 4)
        }
        return HSVColor(
            hue: hue < 0 ? hue + 360 : hue,
            saturation: maxChannel == 0 ? 0 : delta / maxChannel,
            value: maxChannel
        )
    }

    var rgbaHex: UInt32 {
        (UInt32(red) << 24)
            | (UInt32(green) << 16)
            | (UInt32(blue) << 8)
            | UInt32(alpha)
    }

    var relativeLuminance: Double {
        func channel(_ value: UInt8) -> Double {
            let normalized = Double(value) / 255
            return normalized <= 0.03928
                ? normalized / 12.92
                : pow((normalized + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func withAlpha(_ alpha: UInt8) -> RGBColor {
        RGBColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension ReadCalendarColorRepository {
    nonisolated static let colorAlgorithmVersion = "android-palette-64x96-v1"

    /// 缓存键稳定绑定书籍与算法版本，来源签名单独识别书名/封面变化。
    nonisolated static func cacheKey(bookId: Int64) -> String {
        "book:\(bookId)|algo:\(colorAlgorithmVersion)"
    }

    /// 来源签名确保同一书籍更换书名或封面后不会沿用旧颜色。
    nonisolated static func sourceSignature(bookName: String, coverURL: String) -> String {
        "\(bookName)\u{0}\(coverURL)"
    }

    /// 复刻 Java/Kotlin String.hashCode，使用 UTF-16 code unit 参与 31 倍滚动哈希。
    nonisolated static func javaStringHashCode(_ value: String) -> Int32 {
        var hash: Int32 = 0
        for codeUnit in value.utf16 {
            hash = hash &* 31 &+ Int32(codeUnit)
        }
        return hash
    }

    /// 复刻 Android ColorGenerator.intToRGB；上层会先设为不透明再执行统一修正。
    nonisolated static func androidGeneratedColor(from value: String) -> RGBColor {
        let bits = UInt32(bitPattern: javaStringHashCode(value))
        return RGBColor(
            red: UInt8((bits >> 16) & 0xFF),
            green: UInt8((bits >> 8) & 0xFF),
            blue: UInt8(bits & 0xFF)
        )
    }
}

private extension Double {
    nonisolated func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
extension ReadCalendarColorRepository {
    /// 调试辅助：对输入封面执行生产取色算法并返回背景 RGBA Hex。
    nonisolated static func testingExtractPreferredEventBarColorHex(from data: Data) -> UInt32? {
        guard let image = UIImage(data: data) else { return nil }
        let swatches = extractPalette(from: image)
        guard !swatches.isEmpty else { return nil }
        return resolveEventColor(swatches: swatches, fallbackSeed: "").background.rgbaHex
    }

    /// 调试辅助：返回缓存键生成结果。
    nonisolated static func testingCacheKey(bookId: Int64, bookName: String, coverURL: String) -> String {
        cacheKey(bookId: bookId)
    }

    /// 调试辅助：返回来源签名。
    nonisolated static func testingSourceSignature(bookName: String, coverURL: String) -> String {
        sourceSignature(bookName: bookName, coverURL: coverURL)
    }
}
#endif

nonisolated private enum ReadCalendarColorCacheLookup {
    case cached(ReadCalendarSegmentColor)
    case joined(ReadCalendarSegmentColor)
    case owner
}

/// 有界成功结果缓存；Actor 同时把相同书籍与封面来源的并发请求合并为一次计算。
private actor ReadCalendarColorCacheStore {
    private struct CacheRecord {
        let color: ReadCalendarSegmentColor
        let sourceSignature: String
        let updatedAt: Int64
    }

    static let shared = ReadCalendarColorCacheStore()

    private let maxEntries = 1200
    private var memory: [String: CacheRecord] = [:]
    private var inFlightKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<ReadCalendarSegmentColor, Never>]] = [:]

    /// 初始化时清理旧版 v3 近似色落盘文件，后续只维护进程内成功结果。
    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let legacyFileURL = directory.appendingPathComponent("read_calendar_event_color_cache_v3.json")
        try? fileManager.removeItem(at: legacyFileURL)
    }

    /// 返回成功缓存、等待中的同源结果，或授予当前调用实际加载与计算职责。
    func begin(
        key: String,
        sourceSignature: String,
        forceRefresh: Bool
    ) async -> ReadCalendarColorCacheLookup {
        let requestKey = "\(key)|source:\(sourceSignature)"
        if !forceRefresh,
           let record = memory[key],
           record.sourceSignature == sourceSignature {
            return .cached(record.color)
        }
        if inFlightKeys.contains(requestKey) {
            let color = await withCheckedContinuation { continuation in
                waiters[requestKey, default: []].append(continuation)
            }
            return .joined(color)
        }
        inFlightKeys.insert(requestKey)
        return .owner
    }

    /// 唤醒同源等待者；只有真实封面取色成功结果进入有界内存缓存。
    func finish(
        _ color: ReadCalendarSegmentColor,
        for key: String,
        sourceSignature: String
    ) {
        let requestKey = "\(key)|source:\(sourceSignature)"
        inFlightKeys.remove(requestKey)
        if color.state == .resolved {
            memory[key] = CacheRecord(
                color: color,
                sourceSignature: sourceSignature,
                updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
            trimIfNeeded()
        }
        let continuations = waiters.removeValue(forKey: requestKey) ?? []
        continuations.forEach { $0.resume(returning: color) }
    }

    private func trimIfNeeded() {
        guard memory.count > maxEntries else { return }
        let removeCount = memory.count - maxEntries
        for item in memory.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(removeCount) {
            memory.removeValue(forKey: item.key)
        }
    }
}
