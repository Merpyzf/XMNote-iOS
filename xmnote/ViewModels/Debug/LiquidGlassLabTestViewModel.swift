#if DEBUG
import Foundation
import UIKit

/**
 * [INPUT]: 依赖 BookRepositoryProtocol 读取真实书封背景样例，依赖 UIKit 截取预览区域并保存 PNG
 * [OUTPUT]: 对外提供 LiquidGlassLabTestViewModel（液态玻璃视觉调试页状态编排）
 * [POS]: Debug 模块液态玻璃专项测试页状态中枢，集中管理参数、预设、截图、FPS 与真实背景样例
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class LiquidGlassLabTestViewModel {
    enum PreviewScene: String, CaseIterable, Identifiable, Codable, Hashable {
        case readability
        case controls
        case matrix
        case scrollReactive

        var id: String { rawValue }

        var title: String {
            switch self {
            case .readability:
                return "文本可读性"
            case .controls:
                return "工具栏/控件"
            case .matrix:
                return "多组件对照"
            case .scrollReactive:
                return "滚动响应"
            }
        }

        var subtitle: String {
            switch self {
            case .readability:
                return "验证复杂图片背景上的标题、正文、数字标签与阴影兜底。"
            case .controls:
                return "验证 Toolbar、BottomBar、Floating Bar 与图标按钮的玻璃质感。"
            case .matrix:
                return "同一组参数在多个背景和组件密度下并排比较。"
            case .scrollReactive:
                return "观察滚动、动态背景和浮动控制层叠加后的稳定性。"
            }
        }
    }

    enum BackgroundKind: String, CaseIterable, Identifiable, Codable, Hashable {
        case solid
        case gradient
        case lowComplexity
        case highComplexity
        case dynamicImage
        case bookMosaic

        var id: String { rawValue }

        var title: String {
            switch self {
            case .solid:
                return "纯色"
            case .gradient:
                return "渐变"
            case .lowComplexity:
                return "低复杂度"
            case .highComplexity:
                return "高复杂度"
            case .dynamicImage:
                return "动态背景"
            case .bookMosaic:
                return "真实书封"
            }
        }
    }

    enum SchemeMode: String, CaseIterable, Identifiable, Codable, Hashable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system:
                return "跟随系统"
            case .light:
                return "浅色"
            case .dark:
                return "深色"
            }
        }
    }

    enum GlassVariant: String, CaseIterable, Identifiable, Codable, Hashable {
        case regular
        case clear
        case identity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .regular:
                return "Regular"
            case .clear:
                return "Clear"
            case .identity:
                return "Identity"
            }
        }
    }

    enum GlassShapeOption: String, CaseIterable, Identifiable, Codable, Hashable {
        case capsule
        case roundedRect
        case circle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .capsule:
                return "Capsule"
            case .roundedRect:
                return "Rounded Rect"
            case .circle:
                return "Circle"
            }
        }
    }

    enum TintOption: String, CaseIterable, Identifiable, Codable, Hashable {
        case none
        case white
        case brand
        case blue
        case amber
        case black

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none:
                return "None"
            case .white:
                return "White"
            case .brand:
                return "Brand"
            case .blue:
                return "Blue"
            case .amber:
                return "Amber"
            case .black:
                return "Black"
            }
        }
    }

    enum MaterialStyle: String, CaseIterable, Identifiable, Codable, Hashable {
        case ultraThin
        case thin
        case regular
        case thick

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ultraThin:
                return "Ultra Thin"
            case .thin:
                return "Thin"
            case .regular:
                return "Regular"
            case .thick:
                return "Thick"
            }
        }
    }

    enum BlendModeOption: String, CaseIterable, Identifiable, Codable, Hashable {
        case normal
        case screen
        case overlay
        case multiply
        case plusLighter

        var id: String { rawValue }

        var title: String {
            switch self {
            case .normal:
                return "Normal"
            case .screen:
                return "Screen"
            case .overlay:
                return "Overlay"
            case .multiply:
                return "Multiply"
            case .plusLighter:
                return "Plus Lighter"
            }
        }
    }

    enum BackgroundSampling: String, CaseIterable, Identifiable, Codable, Hashable {
        case nativeOnly
        case soft
        case expanded

        var id: String { rawValue }

        var title: String {
            switch self {
            case .nativeOnly:
                return "Native Only"
            case .soft:
                return "Soft"
            case .expanded:
                return "Expanded"
            }
        }
    }

    struct GlassLabParameters: Codable, Equatable {
        var glassVariant: GlassVariant = .regular
        var glassShape: GlassShapeOption = .roundedRect
        var tint: TintOption = .none
        var isInteractive = true
        var usesGlassUnion = false
        var usesMorphingProbe = false
        var materialStyle: MaterialStyle = .ultraThin
        var blendMode: BlendModeOption = .normal
        var backgroundSampling: BackgroundSampling = .nativeOnly

        var blurRadius = 2.0
        var tintOpacity = 0.04
        var opacity = 0.98
        var saturation = 1.04
        var brightness = 0.0
        var contrast = 1.0
        var noise = 0.0
        var shadow = 0.10
        var highlightIntensity = 0.10
        var reflectionStrength = 0.03
        var frostedLayerDepth = 0.08
        var glassThickness = 0.08
        var edgeGlow = 0.02
        var borderLight = 0.08
        var vibrancy = 0.12
        var cornerRadius = 26.0
        var backdropScale = 1.0
        var motionParallax = 0.04
        var scrollReactiveEffects = 0.10
        var containerSpacing = 18.0
        var dynamicBrightnessAdaptation = 0.08
    }

    struct Preset: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        let createdAt: Date
        var parameters: GlassLabParameters
    }

    struct ScreenshotRecord: Identifiable, Codable, Equatable {
        let id: UUID
        let title: String
        let createdAt: Date
        let previewScene: PreviewScene
        let backgroundKind: BackgroundKind
        let presetName: String
        let imageFileName: String
        let metadataFileName: String
        let sizeDescription: String
        let parameterSummary: String
    }

    struct SnapshotMetadata: Codable, Equatable {
        let id: UUID
        let title: String
        let createdAt: Date
        let previewScene: PreviewScene
        let backgroundKind: BackgroundKind
        let presetName: String
        let parameters: GlassLabParameters
        let note: String
    }

    struct BookCoverSample: Identifiable, Hashable {
        let id: String
        let title: String
        let urlString: String
    }

    var parameters = GlassLabParameters()
    var previewScene: PreviewScene = .readability
    var backgroundKind: BackgroundKind = .gradient
    var schemeMode: SchemeMode = .system
    var savedPresets: [Preset] = []
    var screenshotRecords: [ScreenshotRecord] = []
    var selectedPresetID: UUID?
    var presetNameDraft = ""
    var captureStatusMessage: String?
    var isLoadingRealBookCovers = false
    var realBookCoverStatusMessage: String?
    var bookSamples: [BookCoverSample] = []
    var fps: Double = 0
    var minimumFPS: Double = 0
    var frameSampleCount = 0
    var scrollReactiveProgress: Double = 0

    private var hasLoadedBookCovers = false
    private var lastFrameTimestamp: CFTimeInterval?
    private var currentFPSWindow: [Double] = []
    private var totalFrameSamples = 0

    init() {
        loadPersistentState()
    }

    var selectedPresetName: String {
        guard let selectedPresetID,
              let preset = savedPresets.first(where: { $0.id == selectedPresetID }) else {
            return "未保存参数"
        }
        return preset.name
    }

    var sourceStatusText: String {
        if isLoadingRealBookCovers {
            return "正在读取真实书封背景..."
        }
        if let realBookCoverStatusMessage {
            return realBookCoverStatusMessage
        }
        if bookSamples.isEmpty {
            return "真实书封暂不可用，书封背景将使用占位矩阵。"
        }
        return "已载入 \(bookSamples.count) 张真实书封，可用于真实图片背景验证。"
    }

    var performanceSummary: String {
        if frameSampleCount == 0 {
            return "FPS 等待采样"
        }
        return "FPS \(format(fps)) / Low \(format(minimumFPS)) / Samples \(frameSampleCount)"
    }

    var nativeParameterSummary: String {
        "Glass \(parameters.glassVariant.title) · \(parameters.glassShape.title) · Tint \(parameters.tint.title) · Container \(format(parameters.containerSpacing))"
    }

    var previewRefreshID: String {
        [
            previewScene.rawValue,
            backgroundKind.rawValue,
            schemeMode.rawValue,
            parameters.glassVariant.rawValue,
            parameters.glassShape.rawValue,
            parameters.tint.rawValue,
            parameters.materialStyle.rawValue,
            parameters.backgroundSampling.rawValue
        ].joined(separator: "-")
    }

    var simulationParameterSummary: String {
        """
        Blur Radius（模拟采样层）: \(format(parameters.blurRadius))
        Tint Opacity: \(format(parameters.tintOpacity))
        Opacity: \(format(parameters.opacity))
        Saturation: \(format(parameters.saturation))
        Brightness: \(format(parameters.brightness))
        Contrast: \(format(parameters.contrast))
        Noise: \(format(parameters.noise))
        Shadow: \(format(parameters.shadow))
        Highlight: \(format(parameters.highlightIntensity))
        Reflection: \(format(parameters.reflectionStrength))
        Frosted Depth: \(format(parameters.frostedLayerDepth))
        Thickness: \(format(parameters.glassThickness))
        Edge Glow: \(format(parameters.edgeGlow))
        Border Light: \(format(parameters.borderLight))
        Vibrancy: \(format(parameters.vibrancy))
        Corner Radius: \(format(parameters.cornerRadius))
        Backdrop Scale: \(format(parameters.backdropScale))
        Motion / Parallax: \(format(parameters.motionParallax))
        Scroll Reactive: \(format(parameters.scrollReactiveEffects))
        Dynamic Brightness: \(format(parameters.dynamicBrightnessAdaptation))
        Material: \(parameters.materialStyle.title)
        Blend Mode: \(parameters.blendMode.title)
        Sampling: \(parameters.backgroundSampling.title)
        """
    }

    func loadBookCoversIfNeeded(using repository: any BookRepositoryProtocol) async {
        guard !hasLoadedBookCovers else { return }
        await loadBookCovers(using: repository)
    }

    func resetParameters() {
        parameters = GlassLabParameters()
        selectedPresetID = nil
        captureStatusMessage = "已恢复推荐基线参数。"
    }

    func setPreviewScene(_ scene: PreviewScene) {
        guard previewScene != scene else { return }
        previewScene = scene
        scrollReactiveProgress = 0
        captureStatusMessage = nil
    }

    func setBackgroundKind(_ kind: BackgroundKind) {
        guard backgroundKind != kind else { return }
        backgroundKind = kind
        scrollReactiveProgress = 0
        captureStatusMessage = nil
    }

    func setSchemeMode(_ mode: SchemeMode) {
        guard schemeMode != mode else { return }
        schemeMode = mode
        captureStatusMessage = nil
    }

    func markParametersEdited() {
        selectedPresetID = nil
        captureStatusMessage = nil
    }

    func savePreset() {
        let trimmed = presetNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "Liquid Glass 预设 \(savedPresets.count + 1)" : trimmed
        let preset = Preset(
            id: UUID(),
            name: resolvedName,
            createdAt: Date(),
            parameters: parameters
        )
        savedPresets.insert(preset, at: 0)
        selectedPresetID = preset.id
        presetNameDraft = ""
        persistPresets()
        captureStatusMessage = "已保存预设：\(resolvedName)"
    }

    func applyPreset(_ preset: Preset) {
        parameters = preset.parameters
        selectedPresetID = preset.id
        captureStatusMessage = "已加载预设：\(preset.name)"
    }

    func deletePreset(_ preset: Preset) {
        savedPresets.removeAll { $0.id == preset.id }
        if selectedPresetID == preset.id {
            selectedPresetID = nil
        }
        persistPresets()
        captureStatusMessage = "已删除预设：\(preset.name)"
    }

    func recordFrame(timestamp: CFTimeInterval) {
        defer { lastFrameTimestamp = timestamp }
        guard let lastFrameTimestamp else { return }
        let delta = timestamp - lastFrameTimestamp
        guard delta > 0 else { return }
        let current = min(120, max(1, 1 / delta))
        currentFPSWindow.append(current)
        if currentFPSWindow.count > 45 {
            currentFPSWindow.removeFirst(currentFPSWindow.count - 45)
        }
        totalFrameSamples += 1
        guard totalFrameSamples.isMultiple(of: 6) else { return }
        frameSampleCount = totalFrameSamples
        fps = currentFPSWindow.reduce(0, +) / Double(currentFPSWindow.count)
        minimumFPS = currentFPSWindow.min() ?? current
    }

    func updateScrollOffset(_ offset: CGFloat) {
        let progress = min(1, max(0, Double(abs(offset) / 220)))
        guard abs(progress - scrollReactiveProgress) > 0.01 else { return }
        scrollReactiveProgress = progress
    }

    func captureSnapshot(from anchorView: UIView?) async {
        guard let image = makeSnapshot(from: anchorView) else {
            captureStatusMessage = "截图失败：未找到可截取的预览区域。"
            return
        }

        do {
            let directory = try ensureSnapshotDirectory()
            let id = UUID()
            let title = "截图 \(screenshotRecords.count + 1)"
            let imageFileName = "\(id.uuidString).png"
            let metadataFileName = "\(id.uuidString).json"
            let imageURL = directory.appendingPathComponent(imageFileName)
            let metadataURL = directory.appendingPathComponent(metadataFileName)

            guard let pngData = image.pngData() else {
                captureStatusMessage = "截图失败：PNG 编码失败。"
                return
            }

            let metadata = SnapshotMetadata(
                id: id,
                title: title,
                createdAt: Date(),
                previewScene: previewScene,
                backgroundKind: backgroundKind,
                presetName: selectedPresetName,
                parameters: parameters,
                note: "截图来自 UIKit window snapshot；非原生参数为调试叠加层模拟。"
            )
            let metadataData = try JSONEncoder.debugEncoder.encode(metadata)
            try pngData.write(to: imageURL, options: .atomic)
            try metadataData.write(to: metadataURL, options: .atomic)

            let record = ScreenshotRecord(
                id: id,
                title: title,
                createdAt: metadata.createdAt,
                previewScene: previewScene,
                backgroundKind: backgroundKind,
                presetName: selectedPresetName,
                imageFileName: imageFileName,
                metadataFileName: metadataFileName,
                sizeDescription: "\(Int(image.size.width))×\(Int(image.size.height))",
                parameterSummary: nativeParameterSummary
            )
            screenshotRecords.insert(record, at: 0)
            if screenshotRecords.count > 12 {
                screenshotRecords.removeLast(screenshotRecords.count - 12)
            }
            persistScreenshotRecords()
            captureStatusMessage = "已保存截图：\(title)"
        } catch {
            captureStatusMessage = "截图保存失败：\(error.localizedDescription)"
        }
    }

    func screenshotURL(for record: ScreenshotRecord) -> URL? {
        guard let directory = try? ensureSnapshotDirectory() else { return nil }
        return directory.appendingPathComponent(record.imageFileName)
    }

    func deleteScreenshot(_ record: ScreenshotRecord) {
        if let directory = try? ensureSnapshotDirectory() {
            let imageURL = directory.appendingPathComponent(record.imageFileName)
            let metadataURL = directory.appendingPathComponent(record.metadataFileName)
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }
        screenshotRecords.removeAll { $0.id == record.id }
        persistScreenshotRecords()
        captureStatusMessage = "已删除截图：\(record.title)"
    }

    func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private extension LiquidGlassLabTestViewModel {
    enum Persistence {
        static let presetsKey = "debug.liquidGlassLab.presets"
        static let screenshotsKey = "debug.liquidGlassLab.screenshots"
        static let directoryPath = "Debug/LiquidGlassLab"
    }

    func loadPersistentState() {
        let decoder = JSONDecoder.debugDecoder
        if let data = UserDefaults.standard.data(forKey: Persistence.presetsKey),
           let decoded = try? decoder.decode([Preset].self, from: data) {
            savedPresets = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Persistence.screenshotsKey),
           let decoded = try? decoder.decode([ScreenshotRecord].self, from: data) {
            screenshotRecords = Array(decoded.prefix(12))
        }
    }

    func persistPresets() {
        guard let data = try? JSONEncoder.debugEncoder.encode(savedPresets) else { return }
        UserDefaults.standard.set(data, forKey: Persistence.presetsKey)
    }

    func persistScreenshotRecords() {
        guard let data = try? JSONEncoder.debugEncoder.encode(screenshotRecords) else { return }
        UserDefaults.standard.set(data, forKey: Persistence.screenshotsKey)
    }

    func ensureSnapshotDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent(Persistence.directoryPath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    func makeSnapshot(from anchorView: UIView?) -> UIImage? {
        guard let anchorView,
              let window = anchorView.window else {
            return nil
        }
        let rect = anchorView.convert(anchorView.bounds, to: window)
        guard rect.width > 1, rect.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func loadBookCovers(using repository: any BookRepositoryProtocol) async {
        isLoadingRealBookCovers = true
        realBookCoverStatusMessage = nil
        defer {
            isLoadingRealBookCovers = false
            hasLoadedBookCovers = true
        }

        do {
            var books: [BookItem] = []
            for try await observed in repository.observeBooks() {
                books = observed
                break
            }

            let urls = deduplicatedPreservingOrder(books.compactMap { normalizeCoverURL($0.cover) })
            bookSamples = urls.prefix(18).enumerated().map { index, url in
                BookCoverSample(
                    id: "book-cover-\(index)-\(url.hashValue)",
                    title: "书封 \(index + 1)",
                    urlString: url
                )
            }

            if bookSamples.isEmpty {
                realBookCoverStatusMessage = "本地 Book 表暂无有效封面，真实书封背景将显示占位矩阵。"
            }
        } catch {
            realBookCoverStatusMessage = "真实书封加载失败：\(error.localizedDescription)"
        }
    }

    func normalizeCoverURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func deduplicatedPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

private extension JSONEncoder {
    static var debugEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var debugDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
