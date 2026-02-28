import Foundation
import UIKit

/**
 * [INPUT]: 依赖 URLSession 获取封面图，依赖 ReadCalendarSegmentColor 领域模型表达事件条颜色结果
 * [OUTPUT]: 对外提供 ReadCalendarColorRepository（ReadCalendarColorRepositoryProtocol 实现，封面主色提取 + 文本可读性计算 + 失败回退）
 * [POS]: Data 层阅读日历颜色仓储，负责封面取色策略与持久缓存，不让 ViewModel 直接依赖网络/图像分析细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarColorRepository: ReadCalendarColorRepositoryProtocol {
    private let session: URLSession
    private let cacheStore: ReadCalendarColorCacheStore

    init(session: URLSession = ReadCalendarColorRepository.makeSession()) {
        self.session = session
        self.cacheStore = .shared
    }

    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> ReadCalendarSegmentColor {
        let normalizedName = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCover = coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = Self.cacheKey(
            bookId: bookId,
            bookName: normalizedName,
            coverURL: normalizedCover
        )

        if let cached = await cacheStore.color(for: cacheKey) {
            return cached
        }

        let fallback = fallbackHashedColor(bookId: bookId, bookName: normalizedName)

        guard let url = Self.validCoverURL(from: normalizedCover) else {
            await cacheStore.save(fallback, for: cacheKey)
            return fallback
        }

        do {
            let data = try await fetchCoverData(url: url)
            if Task.isCancelled {
                return .pending
            }

            guard let dominant = await Self.extractDominantColorAsync(from: data) else {
                await cacheStore.save(fallback, for: cacheKey)
                return fallback
            }

            let textColor = bestTextColor(for: dominant)
            let resolved = ReadCalendarSegmentColor.resolved(
                backgroundRGBAHex: dominant.rgbaHex,
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

// MARK: - Network

private extension ReadCalendarColorRepository {
    nonisolated static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 16
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache.shared
        return URLSession(configuration: config)
    }

    nonisolated static func validCoverURL(from coverURL: String) -> URL? {
        guard let url = URL(string: coverURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    func fetchCoverData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .returnCacheDataElseLoad

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              !data.isEmpty else {
            throw ReadCalendarCoverColorError.invalidResponse
        }
        return data
    }
}

// MARK: - Dominant Color

private extension ReadCalendarColorRepository {
    nonisolated static func extractDominantColorAsync(from data: Data) async -> RGBAColor? {
        await Task.detached(priority: .utility) {
            extractDominantColor(from: data)
        }.value
    }

    nonisolated static func extractDominantColor(from data: Data) -> RGBAColor? {
        guard let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            return nil
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
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        guard let rawBuffer = context.data else { return nil }
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

        guard let best = histogram.max(by: { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            return lhs.key < rhs.key
        }) else {
            return nil
        }

        return color(from: best.key)
    }

    nonisolated static func quantizedKey(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        let r = UInt32(red >> 3)
        let g = UInt32(green >> 3)
        let b = UInt32(blue >> 3)
        return (r << 10) | (g << 5) | b
    }

    nonisolated static func color(from key: UInt32) -> RGBAColor {
        let r = UInt8(((key >> 10) & 0x1F) << 3 | 0x04)
        let g = UInt8(((key >> 5) & 0x1F) << 3 | 0x04)
        let b = UInt8((key & 0x1F) << 3 | 0x04)
        return RGBAColor(red: r, green: g, blue: b, alpha: 255)
    }
}

// MARK: - Text Contrast

private extension ReadCalendarColorRepository {
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

    nonisolated static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return hash
    }

    nonisolated static func cacheKey(bookId: Int64, bookName: String, coverURL: String) -> String {
        "\(bookId)|\(bookName)|\(coverURL)"
    }
}

// MARK: - Internal Types

private enum ReadCalendarCoverColorError: Error {
    case invalidResponse
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

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.fileURL = directory.appendingPathComponent("read_calendar_event_color_cache_v1.json")

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: CacheRecord].self, from: data) else {
            return
        }
        self.memory = decoded
    }

    func color(for key: String) -> ReadCalendarSegmentColor? {
        guard let record = memory[key] else { return nil }
        return ReadCalendarSegmentColor(
            state: record.state,
            backgroundRGBAHex: record.backgroundRGBAHex,
            textRGBAHex: record.textRGBAHex
        )
    }

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
