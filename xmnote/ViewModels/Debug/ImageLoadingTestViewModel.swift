#if DEBUG
import Foundation
import Nuke

/**
 * [INPUT]: 依赖 Nuke ImagePipeline 与 XMImageRequestBuilder 构建统一请求，依赖图片样例 URL 集合
 * [OUTPUT]: 对外提供 ImageLoadingTestViewModel（图片加载测试状态编排）
 * [POS]: Debug 图片加载测试页状态中枢，覆盖静态图/GIF/失败链路/缓存来源与耗时观测
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class ImageLoadingTestViewModel {
    enum MediaKind {
        case staticImage
        case gif
    }

    enum LoadStatus: String {
        case idle
        case loading
        case success
        case failed

        var title: String {
            switch self {
            case .idle:
                return "未开始"
            case .loading:
                return "加载中"
            case .success:
                return "成功"
            case .failed:
                return "失败"
            }
        }
    }

    enum CacheSource: String {
        case memory
        case disk
        case network
        case unknown

        var title: String {
            switch self {
            case .memory:
                return "内存"
            case .disk:
                return "磁盘"
            case .network:
                return "网络"
            case .unknown:
                return "未知"
            }
        }
    }

    struct TestCaseItem: Identifiable {
        let id: UUID
        let title: String
        let note: String
        let urlString: String
        let mediaKind: MediaKind
        var status: LoadStatus = .idle
        var elapsedMs: Int?
        var cacheSource: CacheSource = .unknown
        var message: String?
        var previewVersion: Int = 0

        init(
            id: UUID = UUID(),
            title: String,
            note: String,
            urlString: String,
            mediaKind: MediaKind
        ) {
            self.id = id
            self.title = title
            self.note = note
            self.urlString = urlString
            self.mediaKind = mediaKind
        }
    }

    private enum ProbeResult {
        case success(elapsedMs: Int, cacheSource: CacheSource, message: String?)
        case failure(elapsedMs: Int?, message: String)
    }

    var items: [TestCaseItem]
    var isRunningAll = false
    var lastBatchRunAt: Date?

    var manualURLInput = ""
    var manualStatus: LoadStatus = .idle
    var manualElapsedMs: Int?
    var manualCacheSource: CacheSource = .unknown
    var manualMessage: String?
    var manualPreviewVersion = 0

    private let pipeline: ImagePipeline

    init(pipeline: ImagePipeline = .shared) {
        self.pipeline = pipeline
        self.items = Self.defaultCases
    }

    var successCount: Int {
        items.filter { $0.status == .success }.count
    }

    var failedCount: Int {
        items.filter { $0.status == .failed }.count
    }

    var averageElapsedMs: Int? {
        let values = items.compactMap(\.elapsedMs)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    var hasAnyCaseResult: Bool {
        items.contains { $0.status == .success || $0.status == .failed }
    }

    func runAll() async {
        guard !isRunningAll else { return }
        isRunningAll = true
        defer {
            isRunningAll = false
            lastBatchRunAt = Date()
        }

        let ids = items.map(\.id)
        for id in ids {
            await runItem(id)
        }
    }

    func runItem(_ id: UUID) async {
        guard let index = indexOfItem(id) else { return }
        items[index].status = .loading
        items[index].elapsedMs = nil
        items[index].cacheSource = .unknown
        items[index].message = nil

        let urlString = items[index].urlString
        let result = await probe(urlString: urlString)
        applyProbeResult(result, for: id)
    }

    func retryItem(_ id: UUID) async {
        await runItem(id)
    }

    func runManualURL() async {
        let trimmed = manualURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            manualStatus = .failed
            manualElapsedMs = nil
            manualCacheSource = .unknown
            manualMessage = "请输入 URL。"
            return
        }

        manualStatus = .loading
        manualElapsedMs = nil
        manualCacheSource = .unknown
        manualMessage = nil

        let result = await probe(urlString: trimmed)
        switch result {
        case .success(let elapsedMs, let cacheSource, let message):
            manualStatus = .success
            manualElapsedMs = elapsedMs
            manualCacheSource = cacheSource
            manualMessage = message
            manualPreviewVersion += 1
        case .failure(let elapsedMs, let message):
            manualStatus = .failed
            manualElapsedMs = elapsedMs
            manualCacheSource = .unknown
            manualMessage = message
        }
    }

    func resetManualResult() {
        manualStatus = .idle
        manualElapsedMs = nil
        manualCacheSource = .unknown
        manualMessage = nil
        manualPreviewVersion = 0
    }

    func resetAll() {
        items = items.map { item in
            var updated = item
            updated.status = .idle
            updated.elapsedMs = nil
            updated.cacheSource = .unknown
            updated.message = nil
            return updated
        }
        lastBatchRunAt = nil

        resetManualResult()
    }
}

private extension ImageLoadingTestViewModel {
    static let defaultCases: [TestCaseItem] = [
        TestCaseItem(
            title: "JPEG 成功",
            note: "静态图成功链路",
            urlString: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Example.jpg/320px-Example.jpg",
            mediaKind: .staticImage
        ),
        TestCaseItem(
            title: "WebP 成功",
            note: "WebP 解码与渲染",
            urlString: "https://www.gstatic.com/webp/gallery/1.sm.webp",
            mediaKind: .staticImage
        ),
        TestCaseItem(
            title: "GIF 动画",
            note: "Gifu 播放链路",
            urlString: "https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif",
            mediaKind: .gif
        ),
        TestCaseItem(
            title: "URL 非法",
            note: "输入校验失败",
            urlString: "ftp://example.com/not-supported.jpg",
            mediaKind: .staticImage
        ),
        TestCaseItem(
            title: "HTTP 404",
            note: "服务端失败链路",
            urlString: "https://httpstat.us/404",
            mediaKind: .staticImage
        ),
        TestCaseItem(
            title: "超时场景",
            note: "超过 12 秒请求超时",
            urlString: "https://httpstat.us/200?sleep=15000",
            mediaKind: .staticImage
        ),
    ]

    private func indexOfItem(_ id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    private func applyProbeResult(_ result: ProbeResult, for id: UUID) {
        guard let index = indexOfItem(id) else { return }
        switch result {
        case let .success(elapsedMs, cacheSource, message):
            items[index].status = .success
            items[index].elapsedMs = elapsedMs
            items[index].cacheSource = cacheSource
            items[index].message = message
            items[index].previewVersion += 1
        case let .failure(elapsedMs, message):
            items[index].status = .failed
            items[index].elapsedMs = elapsedMs
            items[index].cacheSource = .unknown
            items[index].message = message
        }
    }

    private func probe(urlString: String) async -> ProbeResult {
        guard let url = XMImageRequestBuilder.normalizedURL(from: urlString) else {
            return .failure(elapsedMs: nil, message: "URL 非法，仅支持 http/https。")
        }

        let request = XMImageRequestBuilder.makeImageRequest(
            url: url,
            priority: .normal
        )

        let start = Date()
        do {
            let response = try await pipeline.imageTask(with: request).response
            let elapsedMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
            let cacheSource = cacheSource(from: response.cacheType)
            return .success(elapsedMs: elapsedMs, cacheSource: cacheSource, message: nil)
        } catch {
            let elapsedMs = max(0, Int(Date().timeIntervalSince(start) * 1000))
            return .failure(elapsedMs: elapsedMs, message: normalizedErrorMessage(error))
        }
    }

    private func cacheSource(from cacheType: ImageResponse.CacheType?) -> CacheSource {
        switch cacheType {
        case .memory:
            return .memory
        case .disk:
            return .disk
        case nil:
            return .network
        @unknown default:
            return .unknown
        }
    }

    private func normalizedErrorMessage(_ error: Error) -> String {
        if error is CancellationError {
            return "任务已取消。"
        }
        if let pipelineError = error as? ImagePipeline.Error {
            if let underlying = pipelineError.dataLoadingError {
                return normalizedNetworkErrorMessage(underlying)
            }
            switch pipelineError {
            case .dataIsEmpty:
                return "响应数据为空。"
            case .decoderNotRegistered:
                return "没有可用的图片解码器。"
            default:
                return pipelineError.description
            }
        }
        return normalizedNetworkErrorMessage(error)
    }

    private func normalizedNetworkErrorMessage(_ error: Error) -> String {
        if let dataLoaderError = error as? DataLoader.Error {
            switch dataLoaderError {
            case .statusCodeUnacceptable(let code):
                return "HTTP 状态异常：\(code)。"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "请求超时（12s）。"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "无法连接到服务器。"
            case NSURLErrorNotConnectedToInternet:
                return "当前网络不可用。"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
#endif
