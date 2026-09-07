/**
 * [INPUT]: 接收 Session 的有界目录页、可见瀑布流及既有预览缓存
 * [OUTPUT]: 提供独立字号的按需瀑布流排版和保留存活 Cell 位置的连续窗口交接
 * [POS]: 总览控制器的单轴窗口 owner；不为瀑布流准备整个桌面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

extension NoteReviewCanvasOverviewController {
    /// 外观换代只能复用位置，不能复用旧字形和补底；主 actor 读取有界批次，队列内准备，取消后拒绝返回。
    func rebuildWaterfallAppearance(model: CanvasOverviewPreparedModel, previous: CanvasOverviewPreparedModel,
                                   work: CanvasOverviewTransitionPreparation) async throws -> CanvasOverviewWaterfallGeometry {
        let ids = previous.waterfallGeometry.notes.map(\.id)
        guard !ids.isEmpty else { return model.waterfallGeometry }
        guard ids.count <= 128, let sourceReader else { throw NoteReviewDirectoryError.invalidBatch }
        var sources: [NoteReviewOverviewLayoutSource] = []
        try await NoteReviewCanvasSourceAdapter(read: { ids, priority in
            guard !work.isCancelled else { throw CancellationError() }
            return try await sourceReader(ids, priority)
        }).consume(ids: ids) { batch in
            try Task.checkCancellation()
            guard !work.isCancelled else { throw CancellationError() }
            sources.append(contentsOf: batch.sources)
        }
        try Task.checkCancellation()
        var input = model
        input.waterfallGeometry = previous.waterfallGeometry
        let keepsLayout = previous.waterfallStyle.bodyFont == model.waterfallStyle.bodyFont
            && previous.waterfallStyle.annotationFont == model.waterfallStyle.annotationFont
            && previous.waterfallStyle.bodyLineSpacing == model.waterfallStyle.bodyLineSpacing
            && previous.waterfallStyle.annotationLineSpacing == model.waterfallStyle.annotationLineSpacing
            && previous.waterfallStyle.typography == model.waterfallStyle.typography
            && previous.waterfallStyle.display == model.waterfallStyle.display
            && previous.waterfallStyle.alignment == model.waterfallStyle.alignment
            && previous.waterfallStyle.traits.preferredContentSizeCategory == model.waterfallStyle.traits.preferredContentSizeCategory
        let viewport = waterfallView.bounds.size
        let store = previewStore
        let queue = preparationQueue
        let preparedInput = input
        let preparedSources = sources
        let availableIDs = Set(preparedSources.map(\.noteID))
        let orderedIDs = ids.filter { availableIDs.contains($0) }
        let result: CanvasOverviewWaterfallGeometry? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: autoreleasepool {
                    CanvasOverviewWaterfallWindowPreparation.make(ids: orderedIDs, model: preparedInput,
                        sources: preparedSources, pins: [:], store: store, viewport: viewport, work: work,
                        reusesContent: false, retainsFrames: keepsLayout)
                })
            }
        }
        try Task.checkCancellation()
        guard !work.isCancelled, let result else { throw CancellationError() }
        return result
    }

    /// 取消只撤销未交付页，已显示身份及字形继续可用；下一次需求可重新准备。
    func cancelWaterfallPagePreparation() {
        waterfallPageGeneration += 1
        waterfallPageTask?.cancel(); waterfallPageTask = nil
        waterfallPageWork?.cancel(); waterfallPageWork = nil
        pendingWaterfallPage = nil
    }

    /// 已就绪的目标不重新读取；窗口边缘在滚动时提前准备，静止或安全交接点应用。
    func ensureDirectoryWaterfall(noteID: Int64, forTransition: Bool) -> Bool {
        if forTransition, preparedModel?.waterfallGeometry.indexByID[noteID] != nil { return true }
        guard waterfallPageTask == nil, pendingWaterfallPage == nil, let read = directoryWaterfallPageReader,
              let model = preparedModel, let sourceReader, !isCanvasPaused, !isDisposed else { return false }
        if !forTransition, let page = directoryWaterfallPage,
           let index = model.waterfallGeometry.indexByID[noteID] {
            let hasBefore = index >= 24 || page.firstOrdinal == 0
            let hasAfter = index < page.members.count - 24 || page.firstOrdinal + Int64(page.members.count) >= page.totalCount
            if hasBefore && hasAfter { return true }
        }
        waterfallPageGeneration += 1
        let token = waterfallPageGeneration
        let input = generation
        let work = CanvasOverviewTransitionPreparation()
        waterfallPageWork = work
        if forTransition { onPreparationChanged?(true, nil) }
        let size = waterfallView.bounds.size
        let queue = preparationQueue
        let store = previewStore
        waterfallPageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == waterfallPageGeneration {
                    waterfallPageTask = nil; waterfallPageWork = nil
                    if forTransition { onPreparationChanged?(false, nil) }
                }
            }
            do {
                guard let page = try await read(noteID) else { return }
                try Task.checkCancellation()
                let ids = page.members.map(\.record.noteID)
                guard ids.count <= 128 else { throw NoteReviewDirectoryError.invalidBatch }
                let pins = Dictionary(uniqueKeysWithValues: ids.compactMap { id -> (Int64, NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>)? in
                    guard let note = model.note(for: id), let key = note.key,
                          let value = store.previews.lease(for: key) else { return nil }
                    return (id, value)
                })
                let missing = ids.filter { model.waterfallGeometry.indexByID[$0] == nil && pins[$0] == nil }
                let sources = missing.isEmpty ? [] : try await sourceReader(missing, .userInitiated)
                try Task.checkCancellation()
                let result: CanvasOverviewWaterfallGeometry? = await withCheckedContinuation { continuation in
                    queue.async {
                        let value = autoreleasepool {
                            CanvasOverviewWaterfallWindowPreparation.make(ids: ids, model: model, sources: sources,
                                pins: pins, store: store, viewport: size, work: work)
                        }
                        continuation.resume(returning: value)
                    }
                }
                try Task.checkCancellation()
                guard token == waterfallPageGeneration, generation == input, !isCanvasPaused, !isDisposed,
                      !work.isCancelled, let result else { return }
                pendingWaterfallPage = (page, result)
                applyPendingWaterfallPage()
            } catch {
                guard !Task.isCancelled, token == waterfallPageGeneration else { return }
                if forTransition { onPreparationChanged?(false, "暂时无法准备目标排版") }
            }
        }
        return false
    }

    /// 只插入／删除离屏身份；现有卡片的 x、列归属及相对 y 不变，共同 y 补偿传给原生滚动视图。
    func applyPendingWaterfallPage() {
        guard let (page, geometry) = pendingWaterfallPage, let model = preparedModel,
              transitionState == .idle, !isObjectMenuPresented, widthSession == nil,
              canCommitBackgroundGeometry?() != false,
              !isDisposed, !isCanvasPaused else { return }
        let previous = model.waterfallGeometry
        let previousIDs = previous.notes.map(\.id)
        let nextIDs = geometry.notes.map(\.id)
        let before = Set(previousIDs), after = Set(nextIDs)
        let anchor = currentNoteID.flatMap { previous.indexByID[$0] != nil && geometry.indexByID[$0] != nil ? $0 : nil }
            ?? previousIDs.first { after.contains($0) }
        let shift: CGFloat
        if let anchor, let from = previous.indexByID[anchor], let to = geometry.indexByID[anchor] {
            shift = geometry.frames[to].minY - previous.frames[from].minY
        } else { shift = 0 }
        let deletes = previousIDs.enumerated().compactMap { !after.contains($0.element) ? IndexPath(item: $0.offset, section: 0) : nil }
        let inserts = nextIDs.enumerated().compactMap { !before.contains($0.element) ? IndexPath(item: $0.offset, section: 0) : nil }
        let offset = waterfallView.contentOffset
        pendingWaterfallPage = nil
        directoryWaterfallPage = page
        isPositioningViewport = true
        UIView.performWithoutAnimation {
            waterfallView.performBatchUpdates {
                preparedModel?.waterfallGeometry = geometry
                preparedModel?.isWaterfallPrepared = true
                waterfallLayout.geometry = geometry
                waterfallView.deleteItems(at: deletes)
                waterfallView.insertItems(at: inserts)
            }
            waterfallView.layoutIfNeeded()
            waterfallView.setContentOffset(CGPoint(x: offset.x, y: offset.y + shift), animated: false)
        }
        if anchor == nil, let id = currentNoteID { positionWaterfall(on: id, animated: false) }
        isPositioningViewport = false
        cancelPreviewWorker()
        rasterPreparationCache.removeAll()
        if currentMode == .waterfall { reportDemand() }
        onReady?()
    }

    /// 真实可见中心而非上一次进度决定预取；仅在边缘请求一次，正文任务不随每帧滚动重启。
    func requestWaterfallWindowIfNeeded() {
        guard currentMode == .waterfall, view.alpha > 0.5, directoryWaterfallPageReader != nil, !isPositioningViewport,
              canCommitBackgroundGeometry?() != false,
              let geometry = preparedModel?.waterfallGeometry,
              let index = geometry.nearestIndex(to: CGPoint(x: waterfallView.bounds.midX, y: waterfallView.bounds.midY)) else { return }
        _ = ensureDirectoryWaterfall(noteID: geometry.notes[index].id, forTransition: false)
    }
}

/// 准备队列逐项消费最多 128 条；可复用的原排版直接沿用，不解析第二次正文。
nonisolated enum CanvasOverviewWaterfallWindowPreparation {
    static func make(ids: [Int64], model: CanvasOverviewPreparedModel,
                     sources: [NoteReviewOverviewLayoutSource],
                     pins: [Int64: NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>],
                     store: CanvasOverviewPreviewStore, viewport: CGSize,
                     work: CanvasOverviewTransitionPreparation, reusesContent: Bool = true,
                     retainsFrames: Bool = true) -> CanvasOverviewWaterfallGeometry? {
        let byID = Dictionary(sources.map { ($0.noteID, $0) }, uniquingKeysWith: { _, last in last })
        let atlas = CanvasOverviewFallbackAtlas(count: ids.count)
        let generation = UUID()
        let width = NoteReviewCanvasWaterfallMetrics(viewport: viewport,
            accessibility: model.style.traits.preferredContentSizeCategory.isAccessibilityCategory,
            regularWidth: model.style.traits.horizontalSizeClass == .regular).cardWidth
        var notes: [CanvasOverviewNote] = []
        var contents: [CanvasOverviewPaperContentGeometry] = []
        for (index, id) in ids.enumerated() {
            guard !work.isCancelled else { return nil }
            if reusesContent, let existing = model.waterfallGeometry.indexByID[id] {
                notes.append(model.waterfallGeometry.notes[existing])
                contents.append(model.waterfallGeometry.contentGeometries[existing])
                continue
            }
            let sourceNote: CanvasOverviewNote
            if let old = model.note(for: id), let pin = pins[id] { sourceNote = old.restoringPreview(pin.value) }
            else if let source = byID[id], let parsed = CanvasOverviewTextFactory.makeRealNotes([source], style: model.waterfallStyle, cancellation: work).first {
                sourceNote = parsed
            } else { return nil }
            let note = sourceNote.reflowed(for: model.waterfallStyle)
            let retained = note.cached(in: store, generation: generation)
            let content = CanvasOverviewGeometryBuilder.makeContentGeometry(note: note, width: width)
            let fallback = atlas.append(index: index, note: note, content: content, width: width, style: model.waterfallStyle)
            notes.append(retained)
            contents.append(content.cached(in: store, key: .init(generation: generation, noteID: id, width: -Int(width), typography: .waterfall), fallback: fallback))
        }
        atlas.finish()
        let frames = retainsFrames ? Dictionary(uniqueKeysWithValues: model.waterfallGeometry.notes.enumerated().map {
            ($0.element.id, model.waterfallGeometry.frames[$0.offset])
        }) : [:]
        return CanvasOverviewGeometryBuilder.makeWaterfall(notes: notes, viewportSize: viewport,
            traits: model.style.traits, cancellation: work, preparedContents: contents, retainingFrames: frames)
    }
}
