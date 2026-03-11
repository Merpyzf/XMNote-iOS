import SwiftUI
import Nuke
import NukeUI

/**
 * [INPUT]: 依赖 NukeUI LazyImage、XMGIFImageView 与 XMImageRequestBuilder，依赖占位视图构造闭包
 * [OUTPUT]: 对外提供 XMRemoteImage（统一远程图片渲染组件，支持静态图与 GIF）
 * [POS]: UIComponents/Foundation 跨模块复用组件，统一图片加载状态、GIF 播放与请求策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// XMRemoteImage 统一封装静态图与 GIF 远程图片渲染路径，收口加载、探测和占位态语义。
struct XMRemoteImage<Placeholder: View>: View {
    let urlString: String
    let contentMode: ContentMode
    let priority: XMImageRequestBuilder.Priority
    let showsGIFBadge: Bool
    let placeholder: () -> Placeholder

    private let pipeline: ImagePipeline

    @State private var gifData: Data?
    @State private var gifLoadFailed = false
    @State private var shouldForceGIFMode = false
    @State private var didProbeGIFData = false

    /// 初始化远程图片组件参数（地址、模式、优先级等）。
    init(
        urlString: String,
        contentMode: ContentMode = .fill,
        priority: XMImageRequestBuilder.Priority = .normal,
        showsGIFBadge: Bool = false,
        pipeline: ImagePipeline = .shared,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urlString = urlString
        self.contentMode = contentMode
        self.priority = priority
        self.showsGIFBadge = showsGIFBadge
        self.pipeline = pipeline
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let url = XMImageRequestBuilder.normalizedURL(from: urlString) {
                let isGIFURL = XMImageRequestBuilder.isGIFURL(url)
                if isGIFURL || shouldForceGIFMode {
                    gifContent(for: url)
                } else {
                    staticImage(
                        for: url,
                        shouldProbeGIFData: XMImageRequestBuilder.shouldProbeGIFData(for: url)
                    )
                }
            } else {
                placeholder()
            }
        }
        .task(id: urlString) {
            resetGIFState()
        }
    }
}

private extension XMRemoteImage {
    /// 渲染静态图片内容并处理占位/失败状态。
    func staticImage(
        for url: URL,
        shouldProbeGIFData: Bool
    ) -> some View {
        let request = XMImageRequestBuilder.makeImageRequest(url: url, priority: priority)

        return LazyImage(request: request) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .pipeline(pipeline)
        .onDisappear(.lowerPriority)
        .onCompletion { result in
            handleStaticImageCompletion(
                result: result,
                url: url,
                shouldProbeGIFData: shouldProbeGIFData
            )
        }
    }

    /// 渲染 GIF 内容层并处理加载状态。
    @ViewBuilder
    /// 优先展示 GIF 动画数据，失败后回退静态图，保证远程图组件有稳定兜底。
    func gifContent(for url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            if let gifData {
                XMGIFImageView(data: gifData, contentMode: contentMode, autoplay: true)
            } else if gifLoadFailed {
                staticImage(for: url, shouldProbeGIFData: false)
            } else {
                placeholder()
            }

            if showsGIFBadge {
                Text("GIF")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.compact)
                    .padding(.vertical, Spacing.hairline)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(Spacing.compact)
            }
        }
        .task(id: url.absoluteString) {
            await loadGIFData(from: url)
        }
        .onDisappear {
            gifData = nil
        }
    }

    /// 下载 GIF 原始数据并更新组件状态（成功进入 GIF 渲染，失败回退静态图）。
    @MainActor
    /// 下载 GIF 原始数据并更新组件状态。
    /// 并发语义：在主线程回写 `gifData/gifLoadFailed`，若任务取消则立即终止，避免旧 URL 结果串到新视图实例。
    func loadGIFData(from url: URL) async {
        gifLoadFailed = false
        gifData = nil

        let request = XMImageLoadRequest(url: url, priority: priority)
        do {
            let (data, _) = try await pipeline.data(for: request.imageRequest)
            guard !Task.isCancelled else { return }
            if XMImageRequestBuilder.isGIFData(data) {
                gifData = data
            } else {
                gifLoadFailed = true
            }
        } catch {
            guard !Task.isCancelled else { return }
            gifLoadFailed = true
        }
    }

    /// 重置 GIF 相关状态，避免 URL 切换后沿用旧加载结果。
    @MainActor
    /// 重置 GIF 相关状态，避免 URL 切换后沿用旧加载结果。
    func resetGIFState() {
        gifData = nil
        gifLoadFailed = false
        shouldForceGIFMode = false
        didProbeGIFData = false
    }

    /// 处理静态图加载回调并同步组件状态。
    @MainActor
    /// 根据静态图加载结果决定是否切换到 GIF 渲染分支。
    func handleStaticImageCompletion(
        result: Result<ImageResponse, Error>,
        url: URL,
        shouldProbeGIFData: Bool
    ) {
        guard case .success(let response) = result else {
            return
        }

        if XMImageRequestBuilder.isGIFResponse(response.urlResponse) {
            shouldForceGIFMode = true
            return
        }

        guard shouldProbeGIFData, !didProbeGIFData else {
            return
        }
        didProbeGIFData = true

        Task {
            await probeGIFDataIfNeeded(from: url)
        }
    }

    /// 按需探测资源是否为 GIF，避免错误渲染路径。
    @MainActor
    /// 在响应头不可靠时补做一次数据探测，避免 GIF 资源被误按静态图展示。
    func probeGIFDataIfNeeded(from url: URL) async {
        let request = XMImageLoadRequest(url: url, priority: priority)
        do {
            let (data, _) = try await pipeline.data(for: request.imageRequest)
            guard !Task.isCancelled else { return }
            if XMImageRequestBuilder.isGIFData(data) {
                shouldForceGIFMode = true
            }
        } catch {
            // 静默失败：保留静态图渲染
        }
    }
}
