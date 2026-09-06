/**
 * [INPUT]: 接收宿主菜单打开、收起与用户选择总览的明确意图
 * [OUTPUT]: 提前准备有界目标邻域，复用冷准备；未选择时撤销菜单独占的剩余工作
 * [POS]: NoteReviewCanvas 页面私有菜单意图预热，不改变当前模式、相机或业务身份
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

extension NoteReviewCanvasOverviewController {
    /// 主 actor 只在静止菜单意图下启动准备；实际选择复用同一代任务，不另建数据会话。
    func beginMenuPrewarming(ids: [Int64], currentID: Int64, settings: NoteReviewSettings) {
        guard !isDisposed, !isCanvasPaused, !isApplyingDeletion, widthSession == nil,
              transitionState == .idle, !activeScrollView.isDragging,
              !activeScrollView.isDecelerating, !desktopScrollView.isZooming else { return }
        isMenuPrewarming = true
        let wasPreparing = modelPreparation != nil
        applySnapshot(ids: ids, currentID: currentID, settings: settings)
        if !ids.isEmpty, preparedModel == nil, modelPreparation == nil,
           deferredModel == nil, !preparationIsPending {
            // A new menu intent may retry a failed cold preparation, never a timer-driven retry loop.
            requestPreparation(count: ids.count, preservingCurrentID: currentNoteID)
        }
        if !wasPreparing, modelPreparation != nil { menuPreparationGeneration = generation }
        prewarmPreparedMenuTargetsIfNeeded()
    }

    /// 菜单关闭不丢弃已完成模型；只有未选择总览时，才撤销本次菜单独占的冷准备。
    func endMenuPrewarming(cancelUnrequestedPreparation: Bool) {
        isMenuPrewarming = false
        let ownedGeneration = menuPreparationGeneration
        menuPreparationGeneration = nil
        if cancelUnrequestedPreparation {
            menuPrewarmRequestGeneration += 1
            menuPrewarmTask?.cancel(); menuPrewarmTask = nil
            if ownedGeneration == generation, modelPreparation != nil {
                generation += 1
                modelPreparation?.cancel(); modelPreparation = nil
                realDataTask?.cancel(); realDataTask = nil
                preparationIsPending = false
                deferredModel = nil
                requestedInitialPreparation = preparedModel != nil
                setLoadingVisible(false)
                onPreparationChanged?(false, nil)
            }
        }
    }

    /// 准备可见端点及全景聚焦邻域；每个模式最多二十张，后台工作过期即停止，源面始终可操作。
    func prewarmPreparedMenuTargetsIfNeeded() {
        guard isMenuPrewarming, !isCanvasPaused, !isDisposed, !isApplyingDeletion,
              menuPrewarmTask == nil, !preparationIsPending, widthSession == nil,
              transitionState == .idle, let model = preparedModel, let id = currentNoteID else { return }
        let token = generation
        prepareTargetSurface(currentMode == .desktop ? .waterfall : .desktop)
        guard let plan = makeTransitionPlan(anchorNoteID: id) else { return }
        let demand = transitionPreviewDemand(for: plan)
        menuPrewarmRequestGeneration += 1
        let request = menuPrewarmRequestGeneration
        menuPrewarmTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if generation == token, menuPrewarmRequestGeneration == request { menuPrewarmTask = nil }
            }
            do {
                try await warmPreviews(ids: Array(([id] + demand.desktop).uniquedIDs.prefix(20)),
                    model: model, work: nil, modes: [.desktop], requiresAll: false)
                try Task.checkCancellation()
                guard generation == token, menuPrewarmRequestGeneration == request,
                      !isDisposed, !isCanvasPaused else { return }
                try await warmPreviews(ids: Array(([id] + demand.waterfall).uniquedIDs.prefix(20)),
                    model: model, work: nil, modes: [.waterfall], requiresAll: false)
            } catch { /* Speculative preparation never presents an error or changes the source surface. */ }
        }
    }
}

private extension Array where Element == Int64 {
    /// 有界候选保留首次顺序，当前书摘始终占第一个准备名额。
    var uniquedIDs: [Int64] {
        var seen = Set<Int64>()
        return filter { seen.insert($0).inserted }
    }
}
