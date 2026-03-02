import SwiftUI
import Nuke
import NukeUI

/**
 * [INPUT]: 依赖 NukeUI LazyImage、XMGIFImageView 与 XMImageRequestBuilder，依赖占位视图构造闭包
 * [OUTPUT]: 对外提供 XMRemoteImage（统一远程图片渲染组件，支持静态图与 GIF）
 * [POS]: UIComponents/Foundation 跨模块复用组件，统一图片加载状态、GIF 播放与请求策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

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

    @ViewBuilder
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
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(4)
            }
        }
        .task(id: url.absoluteString) {
            await loadGIFData(from: url)
        }
        .onDisappear {
            gifData = nil
        }
    }

    @MainActor
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

    @MainActor
    func resetGIFState() {
        gifData = nil
        gifLoadFailed = false
        shouldForceGIFMode = false
        didProbeGIFData = false
    }

    @MainActor
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

    @MainActor
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
