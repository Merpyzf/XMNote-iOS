import Foundation
import UIKit

/**
 * [INPUT]: 依赖 XMCoverImageLoading 统一下载封面，依赖 ReadCalendarSegmentColor 领域模型表达事件条颜色结果
 * [OUTPUT]: 对外提供 ReadCalendarColorRepository（ReadCalendarColorRepositoryProtocol 实现，封面颜色提取 + 视觉优先回退 + 文本可读性计算 + 失败哈希回退）
 * [POS]: Data 层阅读日历颜色仓储，负责封面取色策略（近白过滤 + 视觉优先色）与持久缓存，不让 ViewModel 直接依赖网络/图像分析细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarColorRepository: ReadCalendarColorRepositoryProtocol {
    private let imageLoader: any XMCoverImageLoading
    private let cacheStore: ReadCalendarColorCacheStore

    /// 注入封面加载器并初始化本地颜色缓存，用于后续事件条取色。
    init(imageLoader: any XMCoverImageLoading = NukeCoverImageLoader()) {
        self.imageLoader = imageLoader
        self.cacheStore = .shared
    }

    /// 解析封面颜色并返回事件条颜色；失败时走稳定哈希回退。
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> ReadCalendarSegmentColor {
        let normalizedName = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCoverURL = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = Self.cacheKey(
            bookId: bookId,
            bookName: normalizedName,
            coverURL: normalizedCoverURL
        )

        if let cached = await cacheStore.color(for: cacheKey) {
            return cached
        }

        let fallback = fallbackHashedColor(bookId: bookId, bookName: normalizedName)

        guard let url = XMImageRequestBuilder.normalizedURL(from: normalizedCoverURL) else {
            await cacheStore.save(fallback, for: cacheKey)
            return fallback
        }

        do {
            let image = try await imageLoader.loadImage(for: XMImageLoadRequest(url: url))
            if Task.isCancelled {
                await cacheStore.save(fallback, for: cacheKey)
                return fallback
            }

            guard let preferredBackground = await Self.extractPreferredEventBarColorAsync(from: image) else {
                await cacheStore.save(fallback, for: cacheKey)
                return fallback
            }
            if Task.isCancelled {
                await cacheStore.save(fallback, for: cacheKey)
                return fallback
            }

            let textColor = bestTextColor(for: preferredBackground)
            let resolved = ReadCalendarSegmentColor.resolved(
                backgroundRGBAHex: preferredBackground.rgbaHex,
                textRGBAHex: textColor.rgbaHex
            )
            await cacheStore.save(resolved, for: cacheKey)
            return resolved
        } catch {
            await cacheStore.save(fallback, for: cacheKey)
            return fallback
        }
    }
}

// MARK: - Cover Color Policy

private extension ReadCalendarColorRepository {
    /// 在后台线程提取封面优先色，避免阻塞主线程。
    nonisolated static func extractPreferredEventBarColorAsync(from image: UIImage) async -> RGBAColor? {
        await Task.detached(priority: .utility) {
            extractPreferredEventBarColor(from: image)
        }.value
    }

    /// 从封面图像中选择事件条优先色（主色优先，其次视觉优先色）。
    nonisolated static func extractPreferredEventBarColor(from image: UIImage) -> RGBAColor? {
        let swatches = extractColorSwatches(from: image)
        guard !swatches.isEmpty else { return nil }

        if let dominant = findDominantColor(from: swatches),
           !isInvalidEventBarColor(dominant) {
            return dominant
        }

        if let visualPriority = findVisualPriorityColor(from: swatches) {
            return visualPriority
        }

        return nil
    }

    /// 从原始图片数据解码后提取事件条优先色。
    nonisolated static func extractPreferredEventBarColor(from data: Data) -> RGBAColor? {
        guard let image = UIImage(data: data) else { return nil }
        return extractPreferredEventBarColor(from: image)
    }

    /// 对封面缩采样并提取颜色样本集，供主色筛选算法使用。
    nonisolated static func extractColorSwatches(from image: UIImage) -> [ColorSwatch] {
        guard let cgImage = image.cgImage else {
            return []
        }

        let targetWidth = 40
        let targetHeight = 56
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

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let rawBuffer = context.data else { return [] }
        let count = targetWidth * targetHeight * bytesPerPixel
        let pixels = rawBuffer.bindMemory(to: UInt8.self, capacity: count)

        var histogram: [UInt32: Int] = [:]
        histogram.reserveCapacity(2048)

        var index = 0
        while index < count {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            let alpha = pixels[index + 3]
            index += bytesPerPixel

            guard alpha >= 24 else { continue }
            let key = quantizedKey(red: red, green: green, blue: blue)
            histogram[key, default: 0] += 1
        }

        return histogram.map { key, population in
            ColorSwatch(color: color(from: key), population: population)
        }
    }

    /// 从候选色样中读取目标结果。
    nonisolated static func findDominantColor(from swatches: [ColorSwatch]) -> RGBAColor? {
        guard let dominant = swatches.max(by: { lhs, rhs in
            if lhs.population != rhs.population {
                return lhs.population < rhs.population
            }
            return lhs.color.rgbaHex < rhs.color.rgbaHex
        }) else {
            return nil
        }
        return dominant.color
    }

    /// 判断颜色是否不适合事件条展示（过白/过暗/低饱和）。
    nonisolated static func isInvalidEventBarColor(_ color: RGBAColor) -> Bool {
        let hsv = color.hsv
        let isNearWhite = hsv.value >= 0.92 && hsv.saturation <= 0.20
        let isLowSaturationLightTone = hsv.saturation < 0.16 && hsv.value > 0.70
        let isTooDark = hsv.value < 0.18
        return isNearWhite || isLowSaturationLightTone || isTooDark
    }

    /// 从候选色样中读取目标结果。
    nonisolated static func findVisualPriorityColor(from swatches: [ColorSwatch]) -> RGBAColor? {
        let candidates = swatches.filter {
            let hsv = $0.color.hsv
            let alpha = Double($0.color.alpha) / 255.0
            return alpha > 0.8
            && hsv.saturation >= 0.35
            && hsv.value >= 0.35
            && hsv.value <= 0.90
        }

        guard let maxPopulation = candidates.map(\.population).max(),
              maxPopulation > 0 else {
            return nil
        }

        guard let best = candidates.max(by: { lhs, rhs in
            let lhsScore = scoreVisualPrioritySwatch(lhs, maxPopulation: maxPopulation)
            let rhsScore = scoreVisualPrioritySwatch(rhs, maxPopulation: maxPopulation)
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            if lhs.population != rhs.population {
                return lhs.population < rhs.population
            }
            return lhs.color.rgbaHex < rhs.color.rgbaHex
        }) else {
            return nil
        }

        return best.color
    }

    /// 按饱和度、亮度与像素占比为候选色样打分，筛出更适合事件条展示的颜色。
    nonisolated static func scoreVisualPrioritySwatch(_ swatch: ColorSwatch, maxPopulation: Int) -> Double {
        let hsv = swatch.color.hsv
        let normalizedPopulation = Double(swatch.population) / Double(maxPopulation)
        let brightnessPreference = 1.0 - abs(hsv.value - 0.62)
        return 0.45 * normalizedPopulation
            + 0.35 * hsv.saturation
            + 0.20 * brightnessPreference
    }

    /// 把 RGB 量化为 5bit 键，用于颜色分桶统计。
    nonisolated static func quantizedKey(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        let r = UInt32(red >> 3)
        let g = UInt32(green >> 3)
        let b = UInt32(blue >> 3)
        return (r << 10) | (g << 5) | b
    }

    /// 读取缓存项并还原为业务颜色模型。
    nonisolated static func color(from key: UInt32) -> RGBAColor {
        let r = UInt8(((key >> 10) & 0x1F) << 3 | 0x04)
        let g = UInt8(((key >> 5) & 0x1F) << 3 | 0x04)
        let b = UInt8((key & 0x1F) << 3 | 0x04)
        return RGBAColor(red: r, green: g, blue: b, alpha: 255)
    }
}

// MARK: - Cache Key

private extension ReadCalendarColorRepository {
    nonisolated static let colorAlgorithmVersion = "v2"

    /// 生成颜色缓存键（bookId+书名+封面 URL+算法版本）。
    nonisolated static func cacheKey(bookId: Int64, bookName: String, coverURL: String) -> String {
        "\(bookId)|\(bookName)|\(coverURL)|algo:\(colorAlgorithmVersion)"
    }
}

#if DEBUG
extension ReadCalendarColorRepository {
    /// 测试辅助：返回封面提取色的 RGBA Hex。
    nonisolated static func testingExtractPreferredEventBarColorHex(from data: Data) -> UInt32? {
        extractPreferredEventBarColor(from: data)?.rgbaHex
    }

    /// 测试辅助：返回缓存键生成结果。
    nonisolated static func testingCacheKey(bookId: Int64, bookName: String, coverURL: String) -> String {
        cacheKey(bookId: bookId, bookName: bookName, coverURL: coverURL)
    }
}
#endif

// MARK: - Text Contrast

private extension ReadCalendarColorRepository {
    /// 为背景色选择对比度更高的文本颜色。
    func bestTextColor(for background: RGBAColor) -> RGBAColor {
        let lightText = RGBAColor(red: 248, green: 251, blue: 255, alpha: 236)
        let darkText = RGBAColor(red: 34, green: 43, blue: 55, alpha: 234)

        let lightRatio = contrastRatio(foreground: lightText, background: background)
        let darkRatio = contrastRatio(foreground: darkText, background: background)

        if lightRatio >= darkRatio {
            if lightRatio >= 4.5 {
                return lightText
            }
        } else if darkRatio >= 4.5 {
            return darkText
        }

        let luminance = background.relativeLuminance
        if luminance > 0.62 {
            return RGBAColor(red: 26, green: 33, blue: 42, alpha: 242)
        }
        if luminance < 0.25 {
            return RGBAColor(red: 250, green: 252, blue: 255, alpha: 242)
        }
        return darkRatio >= lightRatio ? darkText : lightText
    }

    /// 计算前景与背景颜色对比度。
    func contrastRatio(foreground: RGBAColor, background: RGBAColor) -> Double {
        let fg = foreground.relativeLuminance
        let bg = background.relativeLuminance
        let lighter = max(fg, bg)
        let darker = min(fg, bg)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

// MARK: - Fallback Hash Color

private extension ReadCalendarColorRepository {
    /// 基于书籍信息生成稳定回退色，保证失败场景也有一致配色。
    func fallbackHashedColor(bookId: Int64, bookName: String) -> ReadCalendarSegmentColor {
        let seedString = "\(bookId)|\(bookName)"
        let hash = Self.fnv1a64(seedString)

        let hue = Double(hash % 360) / 360.0
        let saturation = 0.34 + Double((hash >> 10) & 0x3F) / 63.0 * 0.22
        let brightness = 0.66 + Double((hash >> 18) & 0x3F) / 63.0 * 0.2
        let alpha = 0.88

        let uiColor = UIColor(
            hue: CGFloat(hue),
            saturation: CGFloat(saturation),
            brightness: CGFloat(brightness),
            alpha: CGFloat(alpha)
        )
        let background = RGBAColor(uiColor: uiColor)
        let text = bestTextColor(for: background)

        return ReadCalendarSegmentColor.failed(
            backgroundRGBAHex: background.rgbaHex,
            textRGBAHex: text.rgbaHex
        )
    }

    /// 计算 FNV-1a 哈希，作为回退配色种子。
    nonisolated static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }
}

private struct ColorSwatch {
    let color: RGBAColor
    let population: Int
}

private struct HSVColor {
    let hue: Double
    let saturation: Double
    let value: Double
}

private struct RGBAColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    nonisolated init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    nonisolated init(uiColor: UIColor) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = UInt8(clamping: Int(round(r * 255)))
        self.green = UInt8(clamping: Int(round(g * 255)))
        self.blue = UInt8(clamping: Int(round(b * 255)))
        self.alpha = UInt8(clamping: Int(round(a * 255)))
    }

    nonisolated var rgbaHex: UInt32 {
        (UInt32(red) << 24)
        | (UInt32(green) << 16)
        | (UInt32(blue) << 8)
        | UInt32(alpha)
    }

    nonisolated var hsv: HSVColor {
        let red = Double(self.red) / 255.0
        let green = Double(self.green) / 255.0
        let blue = Double(self.blue) / 255.0

        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue

        let hue: Double
        if delta == 0 {
            hue = 0
        } else if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = ((blue - red) / delta) + 2
        } else {
            hue = ((red - green) / delta) + 4
        }

        let normalizedHue = ((hue / 6).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        return HSVColor(hue: normalizedHue, saturation: saturation, value: maxValue)
    }

    nonisolated var relativeLuminance: Double {
        let red = linearize(Double(self.red) / 255.0)
        let green = linearize(Double(self.green) / 255.0)
        let blue = linearize(Double(self.blue) / 255.0)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    nonisolated private func linearize(_ component: Double) -> Double {
        if component <= 0.03928 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}

private actor ReadCalendarColorCacheStore {
    /// CacheRecord 是颜色缓存落盘模型，记录状态、前景/背景色和更新时间。
    struct CacheRecord: Codable {
        let state: ReadCalendarSegmentColorState
        let backgroundRGBAHex: UInt32
        let textRGBAHex: UInt32
        let updatedAt: Int64
    }

    static let shared = ReadCalendarColorCacheStore()

    private let fileURL: URL
    private let maxEntries = 1200
    private var memory: [String: CacheRecord] = [:]

    /// 初始化缓存文件路径并恢复本地颜色缓存。
    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.fileURL = directory.appendingPathComponent("read_calendar_event_color_cache_v2.json")

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: CacheRecord].self, from: data) else {
            return
        }
        self.memory = decoded
    }

    /// 读取缓存项并还原为业务颜色模型。
    func color(for key: String) -> ReadCalendarSegmentColor? {
        guard let record = memory[key] else { return nil }
        return ReadCalendarSegmentColor(
            state: record.state,
            backgroundRGBAHex: record.backgroundRGBAHex,
            textRGBAHex: record.textRGBAHex
        )
    }

    /// 写入颜色缓存并触发容量裁剪与持久化。
    func save(_ color: ReadCalendarSegmentColor, for key: String) {
        guard color.state != .pending else { return }
        memory[key] = CacheRecord(
            state: color.state,
            backgroundRGBAHex: color.backgroundRGBAHex,
            textRGBAHex: color.textRGBAHex,
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        trimIfNeeded()
        persistIfPossible()
    }

    private func trimIfNeeded() {
        guard memory.count > maxEntries else { return }
        let removeCount = memory.count - maxEntries
        let sorted = memory.sorted { lhs, rhs in
            lhs.value.updatedAt < rhs.value.updatedAt
        }
        for index in 0..<removeCount {
            memory.removeValue(forKey: sorted[index].key)
        }
    }

    private func persistIfPossible() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
