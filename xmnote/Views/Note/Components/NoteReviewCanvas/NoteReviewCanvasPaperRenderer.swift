/**
 * [INPUT]: 依赖已准备的纸面九宫格、文字指令、颜色和几何
 * [OUTPUT]: 提供单画布、瀑布流与共享纸张端点的同源绘制入口
 * [POS]: NoteReviewCanvas 纯 Core Graphics 绘制；不访问 UIKit 视图或可变外观
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreGraphics
import Foundation

/// 文字端点使用同一阅读起点和裁剪；截断渐隐不改变已测行布局。
nonisolated struct NoteReviewCanvasPaperTextBlock: Sendable {
    let rect: CGRect
    let layout: NoteReviewCanvasTextLayout
    let truncated: Bool
}

/// 纸边和固定阴影在准备阶段栅格一次，后续只做九宫格拼接。
nonisolated struct NoteReviewCanvasPaperSkin: Sendable {
    private let pieces: [CGImage?]
    private let caps: [CGFloat]
    let cost: Int

    /// 输入图片必须为向上的原始像素；切片在准备阶段完成，绘制热路径不裁图或生成阴影。
    init(image: CGImage, scale: CGFloat, cap: CGFloat) {
        let scale = max(1, scale)
        let cx = min(Int((cap * scale).rounded()), image.width / 2)
        let cy = min(Int((cap * scale).rounded()), image.height / 2)
        let xs = [0, cx, image.width - cx, image.width]
        let ys = [0, cy, image.height - cy, image.height]
        var parts: [CGImage?] = []
        for row in 0..<3 {
            for column in 0..<3 {
                parts.append(image.cropping(to: CGRect(x: xs[column], y: ys[row],
                    width: xs[column + 1] - xs[column], height: ys[row + 1] - ys[row])))
            }
        }
        pieces = parts
        caps = [CGFloat(cx) / scale, CGFloat(cy) / scale]
        cost = image.bytesPerRow * image.height
    }

    /// 调用者独占 CGContext；按上左原点绘制，文字和纸面不依赖 UIGraphics 当前上下文。
    func draw(in context: CGContext, rect: CGRect) {
        let capX = min(caps[0], rect.width / 2), capY = min(caps[1], rect.height / 2)
        let xs = [rect.minX, rect.minX + capX, rect.maxX - capX, rect.maxX]
        let ys = [rect.minY, rect.minY + capY, rect.maxY - capY, rect.maxY]
        for row in 0..<3 {
            for column in 0..<3 {
                guard let image = pieces[row * 3 + column] else { continue }
                let target = CGRect(x: xs[column], y: ys[row],
                    width: xs[column + 1] - xs[column], height: ys[row + 1] - ys[row])
                context.saveGState()
                context.translateBy(x: target.minX, y: target.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: target.size))
                context.restoreGState()
            }
        }
    }
}

/// 所有表面消费同一组不可变指令；切换显示权不重新换行或生成另一套字体。
nonisolated enum NoteReviewCanvasPaperRenderer {
    /// 调用者提供独占上下文及未缩放桌面坐标；不读取正文、视图或业务状态。
    static func draw(frame: CGRect, rotation: CGFloat, cornerRadius: CGFloat,
                     skin: NoteReviewCanvasPaperSkin, paperColor: CGColor,
                     backgroundImage: CGImage? = nil, backgroundOverlay: CGColor? = nil,
                     blocks: [NoteReviewCanvasPaperTextBlock], in context: CGContext) {
        context.saveGState()
        context.translateBy(x: frame.midX, y: frame.midY)
        context.rotate(by: rotation)
        let rect = CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
        skin.draw(in: context, rect: rect.insetBy(dx: -24, dy: -24))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.clip()
        context.translateBy(x: rect.minX, y: rect.minY)
        drawBackground(backgroundImage, overlay: backgroundOverlay, size: frame.size, in: context)
        for block in blocks { draw(block: block, paperColor: paperColor, in: context) }
        context.restoreGState()
    }

    /// 图片已由宿主解码为不可变缩略图；按纸面等比铺满，绘制线程不发起读取。
    static func drawBackground(_ image: CGImage?, overlay: CGColor?, size: CGSize, in context: CGContext) {
        guard let image else { return }
        let factor = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let target = CGRect(x: (size.width - CGFloat(image.width) * factor) / 2,
            y: (size.height - CGFloat(image.height) * factor) / 2,
            width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        context.saveGState()
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
        if let overlay { context.setFillColor(overlay); context.fill(CGRect(origin: .zero, size: size)) }
    }

    /// 文本纹理准备和直接绘制复用此入口，保证截断末行及阅读起点一致。
    static func draw(block: NoteReviewCanvasPaperTextBlock, paperColor: CGColor, in context: CGContext) {
        let rect = block.rect
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        block.layout.draw(in: context)
        context.restoreGState()
        guard block.truncated, let space = paperColor.colorSpace,
              let gradient = CGGradient(colorsSpace: space,
                colors: [paperColor.copy(alpha: 0) ?? paperColor, paperColor] as CFArray, locations: [0, 1]) else { return }
        context.saveGState()
        context.clip(to: CGRect(x: rect.minX, y: rect.maxY - 20, width: rect.width, height: 20))
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY - 20),
            end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        context.restoreGState()
    }
}
