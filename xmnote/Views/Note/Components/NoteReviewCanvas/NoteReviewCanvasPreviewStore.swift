/**
 * [INPUT]: 接收批次准备的不可变预览、绘制指令与轻量身份
 * [OUTPUT]: 提供有成本上限的预览缓存及同代次真实内容补底
 * [POS]: NoteReviewCanvas 渲染资源 owner；不读取仓储或保存正文到磁盘
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 业务更新时间共同定义预览身份；字体和展示配置由外层 generation 隔离。
nonisolated struct CanvasOverviewSourceRevision: Equatable, Sendable {
    var note: Int64 = 0
    var book: Int64 = 0
    var chapter: Int64 = 0
    init() {}
    init(_ source: NoteReviewOverviewLayoutSource) {
        note = source.noteUpdatedDate; book = source.bookUpdatedDate; chapter = source.chapterUpdatedDate
    }
}

/// 版本与宽度共同标识排版，旧代次只作为可信交接资源存活。
nonisolated struct CanvasOverviewResourceKey: Hashable, Sendable {
    let generation: UUID
    let noteID: Int64
    let width: Int
}

/// Foundation 富文本在准备后冻结；只传递不可变副本，不跨任务共享 Core Text 排版器。
nonisolated struct CanvasOverviewPreviewPayload: @unchecked Sendable {
    let quote: CanvasOverviewTextAsset
    let thought: CanvasOverviewTextAsset
    let book: CanvasOverviewTextAsset
    let chapter: CanvasOverviewTextAsset
    var cost: Int {
        [quote, thought, book, chapter].reduce(0) { $0 + $1.attributedText.length * 128 + $1.text.utf8.count * 2 + 256 }
    }
}

/// 字形和局部特殊效果图均为不可变准备结果，缓存成本包含实际像素。
nonisolated struct CanvasOverviewDrawingPayload: @unchecked Sendable {
    let blocks: [CanvasOverviewTextBlock]
    var cost: Int { blocks.reduce(0) { $0 + $1.layout.cost + $1.signature.utf8.count + 128 } }
}

/// 同一页面的新旧 generation 共用预算；lease 使当前一次绘制或调宽准备也被计入。
nonisolated final class CanvasOverviewPreviewStore: Sendable {
    let previews = NoteReviewCanvasResourceCache<CanvasOverviewResourceKey, CanvasOverviewPreviewPayload>(limit: 8 * 1_024 * 1_024)
    let drawings = NoteReviewCanvasResourceCache<CanvasOverviewResourceKey, CanvasOverviewDrawingPayload>(limit: 16 * 1_024 * 1_024, countLimit: 480)

    /// 内存告警只回收可重新准备的内容，不改变全量位置或真实低清补底。
    func removeUnprotected() { previews.removeUnprotected(); drawings.removeUnprotected() }
}

/// 一次准备任务独占图集上下文；完成后只发布不可变 CGImage，不向绘制线程暴露 CGContext。
nonisolated final class CanvasOverviewFallbackAtlas: @unchecked Sendable {
    let side: Int
    let columns: Int
    let slot: Int
    private var context: CGContext?
    private(set) var image: CGImage?

    /// 两种排版共用最多 2048² 像素，不为每条书摘保存一张独立高清图。
    init(count: Int, layoutCount: Int = 2, maximumSide: Int = 2_048) {
        columns = max(1, Int(ceil(sqrt(Double(max(1, count * layoutCount))))))
        slot = max(1, min(256, maximumSide / columns))
        side = min(maximumSide, columns * slot)
        context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.translateBy(x: 0, y: CGFloat(side))
        context?.scaleBy(x: 1, y: -1)
    }

    /// 每批直接绘入真实内容；返回的轻量区域不会持有该批正文或排版。
    func append(index: Int, note: CanvasOverviewNote, content: CanvasOverviewPaperContentGeometry,
                width: CGFloat, style: CanvasOverviewPaperStyle) -> CanvasOverviewFallbackRegion {
        let size = CGSize(width: width, height: content.chapterRect.maxY + content.quoteRect.minX)
        let scale = min(CGFloat(slot) / size.width, CGFloat(slot) / size.height)
        let rect = CGRect(x: CGFloat((index % columns) * slot), y: CGFloat((index / columns) * slot),
            width: size.width * scale, height: size.height * scale)
        if let context {
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: scale, y: scale)
            CanvasOverviewPaperRenderer.draw(paper: CanvasOverviewCanvasPaper(index: index, noteID: note.id,
                frame: CGRect(origin: .zero, size: size), visualFrame: .zero, rotation: 0, contentGeometry: content),
                note: note, style: style, in: context)
            context.restoreGState()
        }
        return CanvasOverviewFallbackRegion(atlas: self, rect: rect)
    }

    /// 只有完整准备结束才调用；发布后不再修改图集或接收追加。
    func finish() { image = context?.makeImage(); context = nil }
}

/// 单卡只持有图集的区域坐标；缓存缺失时绘制同一排版的真实低清像素。
nonisolated struct CanvasOverviewFallbackRegion: Sendable {
    let atlas: CanvasOverviewFallbackAtlas
    let rect: CGRect

    /// 调用者独占上下文，裁剪后映射整张不可变图集，不分配逐卡裁切图片。
    func draw(in context: CGContext, frame: CGRect, rotation: CGFloat) {
        guard let image = atlas.image, rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: frame.midX, y: frame.midY)
        context.rotate(by: rotation)
        context.translateBy(x: -frame.width / 2, y: -frame.height / 2)
        context.clip(to: CGRect(origin: .zero, size: frame.size))
        context.scaleBy(x: frame.width / rect.width, y: frame.height / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }
}
