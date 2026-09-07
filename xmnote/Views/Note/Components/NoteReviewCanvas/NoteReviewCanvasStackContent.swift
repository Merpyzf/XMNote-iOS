/**
 * [INPUT]: 接收现有纸面端点、不可变字形、输出密度与取消令牌
 * [OUTPUT]: 提供保留真实排版的纸张像素与有界网格预览预算，卡片堆不认识字体或富文本
 * [POS]: NoteReviewCanvas 内容层与堆叠骨架之间的窄边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 完整纸面与已被前纸遮挡的背纸只在采样范围上不同，不使用占位纸或另一套字体。
nonisolated struct CanvasStackPaperContent: Sendable {
    let noteID: Int64
    let logicalSize: CGSize
    let sampledRect: CGRect
    let image: UIImage
    let accessibilityLabel: String
    var backing: CanvasStackPaperBacking? = nil
    var pixelBytes: Int { image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0 }
}

/// 背纸不可见部分只保留同源纸皮；内容裁片不携带第二层阴影，侧边仍是真实完整纸面。
nonisolated struct CanvasStackPaperBacking: Sendable {
    let skin: UIImage
    let background: CGImage?
    let overlay: CGColor
    let cornerRadius: CGFloat
}

/// 同一内容入口供静态堆叠与运动代理消费，绘制不依赖卡片 UIView。
nonisolated enum CanvasStackContentRenderer {
    static let maximumPreviewLongEdge: CGFloat = 1_024
    static let maximumPreviewStacks = 32
    static let previewBudget = 64 * 1_024 * 1_024
    static let stackPixelBudget = previewBudget / maximumPreviewStacks
    static let transitionBudget = 64 * 1_024 * 1_024

    /// 准备队列独占 CGContext，只消费已解析字形；逐张检查取消，后台结果不可再变更。
    static func paper(_ endpoint: CanvasOverviewRenderEndpoint, pixelScale: CGFloat,
                      exposedHeight: CGFloat? = nil, cancellation: CanvasOverviewTransitionPreparation) -> CanvasStackPaperContent? {
        guard !cancellation.isCancelled, let blocks = endpoint.paper.contentGeometry.preparedBlocks else { return nil }
        let size = endpoint.paper.frame.size
        let height = min(size.height, exposedHeight ?? size.height)
        let rect = CGRect(x: 0, y: 0, width: size.width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(0.1, pixelScale)
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: -rect.minX, y: -rect.minY)
            let paper = CanvasOverviewCanvasPaper(index: 0, noteID: endpoint.note.id,
                frame: CGRect(origin: .zero, size: size), visualFrame: .zero, rotation: 0,
                contentGeometry: endpoint.paper.contentGeometry)
            context.addPath(CGPath(roundedRect: paper.frame, cornerWidth: endpoint.style.cornerRadius,
                cornerHeight: endpoint.style.cornerRadius, transform: nil))
            context.clip()
            for block in blocks {
                CanvasOverviewPaperRenderer.draw(block: block, paperColor: endpoint.style.paperColor, in: context)
            }
        }
        guard !cancellation.isCancelled else { return nil }
        return .init(noteID: endpoint.note.id, logicalSize: size, sampledRect: rect, image: image,
                     accessibilityLabel: endpoint.note.summary + "，" + endpoint.note.summaryBook,
                     backing: .init(skin: endpoint.style.paperSkin,
                        background: endpoint.style.backgroundImage, overlay: endpoint.style.backgroundOverlay,
                        cornerRadius: endpoint.style.cornerRadius))
    }

    /// 非独立代理的远处纸张合成一张透明视口图，一起收拢；不生成全组高清纹理。
    static func remainder(_ endpoints: [CanvasOverviewRenderEndpoint], bounds: CGRect, scale: CGFloat,
                          cancellation: CanvasOverviewTransitionPreparation) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(scale, 2_048 / max(bounds.width, bounds.height))
        format.opaque = false; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            for endpoint in endpoints {
                guard !cancellation.isCancelled else { break }
                let context = renderer.cgContext
                context.saveGState()
                context.translateBy(x: endpoint.pose.center.x - bounds.minX, y: endpoint.pose.center.y - bounds.minY)
                context.rotate(by: endpoint.pose.rotation)
                context.scaleBy(x: endpoint.scale, y: endpoint.scale)
                context.translateBy(x: -endpoint.paper.frame.midX, y: -endpoint.paper.frame.midY)
                CanvasOverviewPaperRenderer.draw(paper: endpoint.paper, note: endpoint.note, style: endpoint.style, in: context)
                context.restoreGState()
            }
        }
    }
}

/// 骨架只接受图像、固有尺寸和身份；修改单卡视觉不需要改堆叠布局。
@MainActor
final class CanvasStackPaperView: UIView {
    let content: CanvasStackPaperContent
    private let pixels = UIImageView()

    init(content: CanvasStackPaperContent) {
        self.content = content
        super.init(frame: CGRect(origin: .zero, size: content.logicalSize))
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        if let backing = content.backing {
            let skin = UIImageView(image: backing.skin)
            skin.frame = bounds.insetBy(dx: -CanvasOverviewPaperRenderer.shadowPadding, dy: -CanvasOverviewPaperRenderer.shadowPadding)
            addSubview(skin)
            if let background = backing.background {
                let clip = UIView(frame: bounds)
                clip.clipsToBounds = true; clip.layer.cornerRadius = backing.cornerRadius
                let picture = UIImageView(image: UIImage(cgImage: background))
                picture.frame = clip.bounds; picture.contentMode = .scaleAspectFill
                clip.addSubview(picture)
                let tint = UIView(frame: clip.bounds)
                tint.backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(backing.overlay)
                clip.addSubview(tint)
                addSubview(clip)
            }
        }
        pixels.image = content.image
        pixels.frame = content.sampledRect
        addSubview(pixels)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 只做等比投影与平移，图片中的文字不重新测量、不非等比拉伸。
    func apply(_ pose: CanvasOverviewPaperPose) {
        center = pose.center
        let scale = pose.size.width / content.logicalSize.width
        transform = CGAffineTransform(rotationAngle: pose.rotation).scaledBy(x: scale, y: scale)
    }
}

/// 每堆仅持有少量代表纸张；后纸只保存可见的真实正文区域，避免缓存整张不可见高清纸。
nonisolated struct CanvasStackPreview: Sendable {
    let group: NoteReviewCanvasStackGroup
    let papers: [CanvasStackPaperContent]
    var pixelBytes: Int { papers.reduce(0) { $0 + $1.pixelBytes } }
}
