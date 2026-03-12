import SwiftUI
import UIKit
import Nuke

/**
 * [INPUT]: 依赖 SwiftUI UIViewRepresentable、Nuke ImagePipeline 与 XMImageRequestBuilder，依赖 XMJXThumbnailRegistry 管理缩略图引用
 * [OUTPUT]: 对外提供 XMJXThumbnailView（UIImageView 缩略图桥接视图）
 * [POS]: UIComponents/GalleryJX 的 SwiftUI->UIKit 桥接层，为 JXPhotoBrowser Zoom 转场提供可回溯的真实 UIView 缩略图来源
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// XMJXThumbnailView 桥接可追踪的 `UIImageView` 缩略图，给 JX 浏览器的缩放转场提供真实来源视图。
struct XMJXThumbnailView: UIViewRepresentable {
    let item: XMJXGalleryItem
    let registry: XMJXThumbnailRegistry
    let priority: XMImageRequestBuilder.Priority

    /// 初始化缩略图桥接视图，默认使用高优先级以提升首帧可用性。
    init(
        item: XMJXGalleryItem,
        registry: XMJXThumbnailRegistry,
        priority: XMImageRequestBuilder.Priority = .high
    ) {
        self.item = item
        self.registry = registry
        self.priority = priority
    }

    /// 创建缩略图加载协调器，统一维护注册表映射和图片请求任务。
    func makeCoordinator() -> Coordinator {
        Coordinator(registry: registry)
    }

    /// 创建缩略图承载 `UIImageView`，并在首次挂载时建立 registry 绑定。
    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = UIColor(Color.surfaceCard)

        context.coordinator.bind(imageView)
        context.coordinator.update(item: item, priority: priority)
        return imageView
    }

    /// 响应 SwiftUI 状态更新，刷新缩略图绑定关系和当前图片请求。
    func updateUIView(_ uiView: UIImageView, context: Context) {
        context.coordinator.bind(uiView)
        context.coordinator.update(item: item, priority: priority)
    }

    /// 输出缩略图期望尺寸，确保转场源视图拥有稳定几何边界。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        let resolved: CGSize?
        if let width = proposal.width, width > 0 {
            let height = proposal.height ?? width
            resolved = CGSize(width: width, height: height)
        } else if let height = proposal.height, height > 0 {
            resolved = CGSize(width: height, height: height)
        } else {
            resolved = nil
        }
        if let resolved {
            XMJXGalleryLogger.verbose(
                "thumbnail.sizeThatFits itemID=\(item.id) proposal=(w:\(proposal.width.map { String(Int($0.rounded())) } ?? "nil"),h:\(proposal.height.map { String(Int($0.rounded())) } ?? "nil")) resolved=(w:\(Int(resolved.width.rounded())),h:\(Int(resolved.height.rounded())))"
            )
        } else {
            XMJXGalleryLogger.verbose(
                "thumbnail.sizeThatFits itemID=\(item.id) proposal=(w:\(proposal.width.map { String(Int($0.rounded())) } ?? "nil"),h:\(proposal.height.map { String(Int($0.rounded())) } ?? "nil")) resolved=nil"
            )
        }
        return resolved
    }

    /// 解绑 UIKit 视图与 registry 映射，避免复用后残留旧引用。
    static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
        coordinator.unbind(uiView)
    }
}

extension XMJXThumbnailView {
    @MainActor
    /// Coordinator 负责缩略图注册、URL 去抖和异步图片加载。
    final class Coordinator {
        private let registry: XMJXThumbnailRegistry
        private weak var imageView: UIImageView?
        private var currentItemID: String?
        private var currentURLString: String?
        private var loadingTask: Task<Void, Never>?
        private let pipeline: ImagePipeline

        init(
            registry: XMJXThumbnailRegistry,
            pipeline: ImagePipeline = .shared
        ) {
            self.registry = registry
            self.pipeline = pipeline
        }

        deinit {
            loadingTask?.cancel()
        }

        /// 绑定最新复用后的 UIImageView，并维护注册表映射。
        func bind(_ imageView: UIImageView) {
            self.imageView = imageView
            if let currentItemID {
                registry.register(itemID: currentItemID, view: imageView)
            }
            XMJXGalleryLogger.verbose(
                "thumbnail.bind itemID=\(currentItemID ?? "nil") bounds=(w:\(Int(imageView.bounds.width.rounded())),h:\(Int(imageView.bounds.height.rounded())))"
            )
        }

        /// 解除视图绑定并清理注册表状态。
        func unbind(_ imageView: UIImageView) {
            loadingTask?.cancel()
            if let currentItemID {
                registry.unregister(itemID: currentItemID, view: imageView)
            }
            self.imageView = nil
        }

        /// 响应 item 变化，刷新注册关系并按需拉取缩略图。
        func update(item: XMJXGalleryItem, priority: XMImageRequestBuilder.Priority) {
            guard let imageView else { return }

            if let previousID = currentItemID, previousID != item.id {
                registry.unregister(itemID: previousID, view: imageView)
            }

            currentItemID = item.id
            registry.register(itemID: item.id, view: imageView)
            XMJXGalleryLogger.verbose(
                "thumbnail.update itemID=\(item.id) bounds=(w:\(Int(imageView.bounds.width.rounded())),h:\(Int(imageView.bounds.height.rounded())))"
            )

            let nextURL = resolvedURLString(for: item)
            if currentURLString == nextURL {
                return
            }

            currentURLString = nextURL
            imageView.image = nil
            loadingTask?.cancel()

            guard let urlString = nextURL,
                  let url = XMImageRequestBuilder.normalizedURL(from: urlString) else {
                return
            }

            loadingTask = Task {
                let request = XMImageLoadRequest(url: url, priority: priority)
                do {
                    let image = try await pipeline.image(for: request.imageRequest)
                    guard !Task.isCancelled else { return }
                    imageView.image = image
                } catch {
                    guard !Task.isCancelled else { return }
                    XMJXGalleryLogger.error(
                        "thumbnail.load.failed itemID=\(item.id) error=\(error.localizedDescription)"
                    )
                }
            }
        }

        private func resolvedURLString(for item: XMJXGalleryItem) -> String? {
            if XMImageRequestBuilder.normalizedURL(from: item.thumbnailURL) != nil {
                return item.thumbnailURL
            }
            if XMImageRequestBuilder.normalizedURL(from: item.originalURL) != nil {
                return item.originalURL
            }
            return nil
        }
    }
}
