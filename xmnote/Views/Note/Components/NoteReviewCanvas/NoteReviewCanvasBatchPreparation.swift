/**
 * [INPUT]: 接收背压消费的布局源、渲染配置及取消令牌
 * [OUTPUT]: 输出桌面与瀑布流独立排版的轻量几何、预算缓存及真实低清图集
 * [POS]: NoteReviewCanvas 准备队列私有累加器；每批释放 HTML 和未保护正文
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 仅由同一准备队列串行使用，发布的模型不再持有本累加器或 CGContext。
nonisolated final class CanvasOverviewBatchPreparation: @unchecked Sendable {
    let generation = UUID()
    let store: CanvasOverviewPreviewStore
    let atlas: CanvasOverviewFallbackAtlas
    let style: CanvasOverviewPaperStyle
    let waterfallStyle: CanvasOverviewPaperStyle
    let width: CGFloat
    let waterfallWidth: CGFloat
    let size: CGSize
    let scale: CGFloat
    let packing: CanvasOverviewDesktopPacking
    let fixedColumns: Int?
    let anchorID: Int64?
    let initialProtectedIDs: Set<Int64>
    let preparesWaterfall: Bool
    let overviewLongEdge: CGFloat
    private var initialDrawingPins: [NoteReviewCanvasResourceLease<CanvasOverviewDrawingPayload>] = []
    private var initialSourcePins: [NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>] = []
    var notes: [CanvasOverviewNote] = []
    var desktop: [Int: CanvasOverviewPaperContentGeometry] = [:]
    var waterfall: [CanvasOverviewPaperContentGeometry] = []
    var waterfallNotes: [CanvasOverviewNote] = []

    /// 仓储源已经由主 actor 获取；这里仅保存准备参数和轻量累加输出。
    init(count: Int, store: CanvasOverviewPreviewStore, style: CanvasOverviewPaperStyle,
         waterfallStyle: CanvasOverviewPaperStyle, width: CGFloat, size: CGSize, scale: CGFloat,
         packing: CanvasOverviewDesktopPacking, fixedColumns: Int?, anchorID: Int64?,
         initialProtectedIDs: Set<Int64> = [], preparesWaterfall: Bool = true, overviewLongEdge: CGFloat = 2_048) {
        self.store = store; self.style = style; self.waterfallStyle = waterfallStyle
        self.width = width; self.size = size; self.scale = scale; self.packing = packing
        self.fixedColumns = fixedColumns; self.anchorID = anchorID
        self.preparesWaterfall = preparesWaterfall
        self.overviewLongEdge = overviewLongEdge
        self.initialProtectedIDs = initialProtectedIDs.isEmpty ? [] : Set(((anchorID.map { [$0] } ?? [])
            + initialProtectedIDs.filter { $0 != anchorID }).prefix(20))
        waterfallWidth = NoteReviewCanvasWaterfallMetrics(viewport: size,
            accessibility: style.traits.preferredContentSizeCategory.isAccessibilityCategory,
            regularWidth: style.traits.horizontalSizeClass == .regular).cardWidth
        atlas = CanvasOverviewFallbackAtlas(count: count, layoutCount: preparesWaterfall ? 2 : 1,
            maximumSide: overviewLongEdge < 2_048 ? 1_024 : 2_048)
    }

    /// 每条转换后立即移交预算缓存并绘制图集；取消在每条之间检查，不再积累全量富文本。
    func append(_ sources: [NoteReviewOverviewLayoutSource], cancellation: CanvasOverviewTransitionPreparation) {
        for source in sources {
            guard !cancellation.isCancelled,
                  let note = CanvasOverviewPreparationMetrics.measure("Parse preview", {
                      CanvasOverviewTextFactory.makeRealNotes([source], style: style, cancellation: cancellation).first
                  }) else { return }
            let index = notes.count
            let first = CanvasOverviewPreparationMetrics.measure("Measure desktop text") {
                CanvasOverviewGeometryBuilder.makeContentGeometry(note: note, width: width)
            }
            let firstRegion = CanvasOverviewPreparationMetrics.measure("Raster fallback") {
                atlas.append(index: index * (preparesWaterfall ? 2 : 1), note: note, content: first, width: width, style: style)
            }
            desktop[index] = first.cached(in: store,
                key: CanvasOverviewResourceKey(generation: generation, noteID: note.id, width: Int(width)), fallback: firstRegion)
            if preparesWaterfall {
                let waterfallNote = note.reflowed(for: waterfallStyle)
                waterfallNotes.append(waterfallNote.cached(in: store, generation: generation))
                let second = CanvasOverviewGeometryBuilder.makeContentGeometry(note: waterfallNote, width: waterfallWidth)
                let fallback = atlas.append(index: index * 2 + 1, note: waterfallNote, content: second,
                    width: waterfallWidth, style: waterfallStyle)
                waterfall.append(second.cached(in: store,
                    key: CanvasOverviewResourceKey(generation: generation, noteID: note.id, width: -Int(waterfallWidth), typography: .waterfall), fallback: fallback))
            }
            let retained = note.cached(in: store, generation: generation)
            notes.append(retained)
            // Later batches must not evict the anchor that the pending first screen will display.
            if initialProtectedIDs.contains(note.id) {
                if let key = retained.key, let pin = store.previews.lease(for: key) { initialSourcePins.append(pin) }
                if preparesWaterfall, let key = waterfallNotes.last?.key,
                   let pin = store.previews.lease(for: key) { initialSourcePins.append(pin) }
                for key in [desktop[index]?.key, waterfall.last?.key].compactMap({ $0 }) {
                    if let pin = store.drawings.lease(for: key) { initialDrawingPins.append(pin) }
                }
            }
        }
    }

    /// 精确高度已经完整；只构建索引与总览像素，不重新解析或测量正文。
    func finish(cancellation: CanvasOverviewTransitionPreparation) -> CanvasOverviewPreparedModel? {
        guard !cancellation.isCancelled else { return nil }
        atlas.finish()
        return CanvasOverviewPreparationMetrics.measure("Build immutable layout and overview") {
            CanvasOverviewModelBuilder.build(notes: notes, viewportSize: size, screenScale: scale,
                style: style, waterfallStyle: waterfallStyle, isRealData: true, desktopCardWidth: width,
                packing: packing, cancellation: cancellation, desktopContents: desktop,
                waterfallContents: waterfall, waterfallNotes: waterfallNotes, fixedColumns: fixedColumns, anchorID: anchorID,
                preparesWaterfall: preparesWaterfall, overviewLongEdge: overviewLongEdge)
        }
    }
}
