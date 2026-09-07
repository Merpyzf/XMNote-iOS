/**
 * [INPUT]: 接收 Session 目录区域和用户请求的目标模式
 * [OUTPUT]: 提供有界局部内容与独立字号的按需瀑布流排版，不触发全量正文准备
 * [POS]: 生产与测试共用总览的目录接入层；保持现有相机与转场 owner
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

extension NoteReviewCanvasOverviewController {
    /// 首次桌面不测瀑布流；只有真实目标需要时准备局部排版，主 actor 只提交最终结果。
    /// 取消、背景及请求代次共同约束提交；等待期间真实源表面保持完整。
    func ensureWaterfallPrepared() -> Bool {
        if directoryWaterfallPageReader != nil, let id = currentNoteID {
            return ensureDirectoryWaterfall(noteID: id, forTransition: true)
        }
        guard let model = preparedModel else { return false }
        guard !model.isWaterfallPrepared else { return true }
        guard modelPreparation == nil, !isDisposed, !isCanvasPaused, let sourceReader else { return false }
        let token = generation
        let work = CanvasOverviewTransitionPreparation()
        modelPreparation = work
        preparationIsPending = true
        onPreparationChanged?(true, nil)
        let size = waterfallView.bounds.size
        let queue = preparationQueue
        let store = previewStore
        realDataTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pins = Dictionary(uniqueKeysWithValues: model.notes.compactMap { note -> (Int64, NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>)? in
                    guard let key = note.key, let pin = store.previews.lease(for: key) else { return nil }
                    return (note.id, pin)
                })
                let missing = model.notes.filter { pins[$0.id] == nil }.map(\.id)
                let sources = missing.isEmpty ? [] : try await sourceReader(missing, .userInitiated)
                try Task.checkCancellation()
                let result: CanvasOverviewWaterfallGeometry? = await withCheckedContinuation { continuation in
                    queue.async {
                        continuation.resume(returning: autoreleasepool {
                            CanvasOverviewDirectoryWaterfallPreparation.make(model: model, sources: sources,
                                pins: pins, store: store, viewport: size, cancellation: work)
                        })
                    }
                }
                try Task.checkCancellation()
                guard token == generation, !isDisposed, !isCanvasPaused, !work.isCancelled else { return }
                guard let result else { throw NoteReviewDirectoryError.staleSource }
                preparedModel?.waterfallGeometry = result
                preparedModel?.isWaterfallPrepared = true
                waterfallLayout.geometry = result
                waterfallView.reloadData()
                waterfallView.layoutIfNeeded()
                modelPreparation = nil; realDataTask = nil; preparationIsPending = false
                onPreparationChanged?(false, nil)
                onReady?()
                if showsDiagnosticControls, let target = pendingMode {
                    pendingMode = nil
                    requestMode(target)
                }
            } catch is CancellationError { return }
            catch {
                guard token == generation, !isDisposed else { return }
                modelPreparation = nil; realDataTask = nil; preparationIsPending = false
                onPreparationChanged?(false, "暂时无法准备目标排版")
            }
        }
        return false
    }
}

/// 准备队列独占转换与测量；发布后只保留不可变指令及同排版补底，不保留 Core Text 布局对象。
nonisolated enum CanvasOverviewDirectoryWaterfallPreparation {
    static func make(model: CanvasOverviewPreparedModel, sources: [NoteReviewOverviewLayoutSource],
                     pins: [Int64: NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>],
                     store: CanvasOverviewPreviewStore, viewport: CGSize,
                     cancellation: CanvasOverviewTransitionPreparation) -> CanvasOverviewWaterfallGeometry? {
        let byID = Dictionary(sources.map { ($0.noteID, $0) }, uniquingKeysWith: { _, last in last })
        let atlas = CanvasOverviewFallbackAtlas(count: model.notes.count)
        let width = NoteReviewCanvasWaterfallMetrics(viewport: viewport,
            accessibility: model.style.traits.preferredContentSizeCategory.isAccessibilityCategory,
            regularWidth: model.style.traits.horizontalSizeClass == .regular).cardWidth
        var contents: [CanvasOverviewPaperContentGeometry] = []
        var notes: [CanvasOverviewNote] = []
        for (index, old) in model.notes.enumerated() {
            guard !cancellation.isCancelled, let key = old.key else { return nil }
            let sourceNote: CanvasOverviewNote
            if let pin = pins[old.id] { sourceNote = old.restoringPreview(pin.value) }
            else if let source = byID[old.id], old.revision == CanvasOverviewSourceRevision(source),
                    let restored = CanvasOverviewTextFactory.makeRealNotes([source], style: model.waterfallStyle,
                                                                          cancellation: cancellation).first {
                sourceNote = restored
            } else { return nil }
            let note = sourceNote.reflowed(for: model.waterfallStyle)
            notes.append(note.cached(in: store, generation: key.generation))
            let content = CanvasOverviewGeometryBuilder.makeContentGeometry(note: note, width: width)
            let fallback = atlas.append(index: index, note: note, content: content, width: width, style: model.waterfallStyle)
            contents.append(content.cached(in: store,
                key: .init(generation: key.generation, noteID: old.id, width: -Int(width), typography: .waterfall), fallback: fallback))
        }
        atlas.finish()
        return CanvasOverviewGeometryBuilder.makeWaterfall(notes: notes, viewportSize: viewport,
            traits: model.style.traits, cancellation: cancellation, preparedContents: contents)
    }
}
