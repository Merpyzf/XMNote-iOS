import SwiftUI
import UIKit
import Gifu

/**
 * [INPUT]: 依赖 SwiftUI UIViewRepresentable 与 Gifu GIFImageView，依赖 GIF 数据输入
 * [OUTPUT]: 对外提供 XMGIFImageView（SwiftUI 可用的 GIF 动画承载视图）
 * [POS]: UIComponents/Foundation 跨模块复用组件，统一 GIF 动图播放与生命周期管理
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// GIF 播放承载视图，把 Gifu 能力桥接到 SwiftUI。
struct XMGIFImageView: UIViewRepresentable {
    let data: Data
    let contentMode: ContentMode
    let autoplay: Bool

    /// 记录上次播放的数据快照，避免同一 GIF 被重复重建动画帧。
    final class Coordinator {
        var lastData: Data?
    }

    /// 创建协调器并缓存上次 GIF 数据，避免重复重建动画帧。
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// 创建 GIF 承载视图并绑定协调器。
    func makeUIView(context: Context) -> GIFImageView {
        let imageView = GIFImageView()
        imageView.clipsToBounds = true
        imageView.contentMode = mappedContentMode
        return imageView
    }

    /// 同步播放模式并在 GIF 数据变化时重建动画帧缓存。
    func updateUIView(_ imageView: GIFImageView, context: Context) {
        imageView.contentMode = mappedContentMode

        if context.coordinator.lastData != data {
            imageView.prepareForReuse()
            imageView.animate(withGIFData: data, loopCount: 0)
            context.coordinator.lastData = data
        }

        if autoplay {
            imageView.startAnimatingGIF()
        } else {
            imageView.stopAnimatingGIF()
        }
    }

    /// 销毁视图时释放 GIF 播放资源与任务。
    static func dismantleUIView(_ imageView: GIFImageView, coordinator: Coordinator) {
        imageView.prepareForReuse()
        coordinator.lastData = nil
    }

    private var mappedContentMode: UIView.ContentMode {
        switch contentMode {
        case .fit:
            return .scaleAspectFit
        case .fill:
            return .scaleAspectFill
        @unknown default:
            return .scaleAspectFill
        }
    }
}
