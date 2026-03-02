import SwiftUI
import UIKit
import Gifu

/**
 * [INPUT]: 依赖 SwiftUI UIViewRepresentable 与 Gifu GIFImageView，依赖 GIF 数据输入
 * [OUTPUT]: 对外提供 XMGIFImageView（SwiftUI 可用的 GIF 动画承载视图）
 * [POS]: UIComponents/Foundation 跨模块复用组件，统一 GIF 动图播放与生命周期管理
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct XMGIFImageView: UIViewRepresentable {
    let data: Data
    let contentMode: ContentMode
    let autoplay: Bool

    final class Coordinator {
        var lastData: Data?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GIFImageView {
        let imageView = GIFImageView()
        imageView.clipsToBounds = true
        imageView.contentMode = mappedContentMode
        return imageView
    }

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
