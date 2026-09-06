/**
 * [INPUT]: 接收同代次视口或单纸端点的不可变栅格键与可取消绘制闭包
 * [OUTPUT]: 合并重复准备请求，复用有界高清像素，不持有业务数据或布局器
 * [POS]: NoteReviewCanvas 页面私有准备缓存；主 actor 管理任务，准备队列独占绘制
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit
import os

/// 位置与密度共同定义同一幅像素，不能用当前书摘身份代替真实视口。
nonisolated struct CanvasOverviewRasterPreparationKey: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case viewport
        case reading(noteID: Int64, mode: Int)
    }
    let generation: Int
    let modelGeneration: UUID?
    let kind: Kind
    let contentState: Int
    private let geometry: [Double]

    /// 保留精确逻辑坐标，只有相同端点才共享像素，不把相邻缩放档位混为同一结果。
    init(generation: Int, modelGeneration: UUID?, kind: Kind, rect: CGRect, outputSize: CGSize, scale: CGFloat,
         contentState: Int = 0) {
        self.generation = generation
        self.modelGeneration = modelGeneration
        self.kind = kind
        self.contentState = contentState
        geometry = [rect.minX, rect.minY, rect.width, rect.height,
                    outputSize.width, outputSize.height, scale].map(Double.init)
    }
}

/// 单个消费者取消不会取消另一消费者需要的同键工作；离场或代次失效同步撤销全部交付资格。
@MainActor
final class CanvasOverviewRasterPreparationCache {
    private final class Job {
        let identity: UUID
        let order: Int
        let cancellation: CanvasOverviewTransitionPreparation
        let task: Task<UIImage?, Never>
        var consumers: Set<UUID> = []

        /// 身份用于区分相同像素键的前后任务，消费者集合只在主 actor 更新。
        init(identity: UUID, order: Int, cancellation: CanvasOverviewTransitionPreparation, task: Task<UIImage?, Never>) {
            self.identity = identity; self.order = order; self.cancellation = cancellation; self.task = task
        }
    }
    private var jobs: [CanvasOverviewRasterPreparationKey: Job] = [:]
    private var invalidationGeneration = 0
    private let images = NoteReviewCanvasResourceCache<CanvasOverviewRasterPreparationKey, UIImage>(
        limit: 16 * 1_024 * 1_024, countLimit: 8)
    private(set) var buildCount = 0
    private(set) var hitCount = 0
    var activeCount: Int { jobs.count }
    var cachedBytes: Int { images.statistics.bytes }

    /// 主 actor 合并进行中和已完成请求；绘制只在注入的串行队列执行，返回前重新核对任务身份。
    func image(for key: CanvasOverviewRasterPreparationKey, queue: DispatchQueue,
               render: @escaping @Sendable (CanvasOverviewTransitionPreparation) -> UIImage?) async -> UIImage? {
        let epoch = invalidationGeneration
        while !Task.isCancelled, epoch == invalidationGeneration {
            if let cached = images.lease(for: key) {
                hitCount += 1
                return cached.value
            }
            if let existing = jobs[key], !existing.cancellation.isCancelled {
                hitCount += 1
                return await join(existing, epoch: epoch)
            }
            if jobs.count < 2, jobs[key] == nil { break }
            // Capacity applies backpressure. A newer key never cancels still-protected work.
            guard let oldest = jobs.min(by: { $0.value.order < $1.value.order })?.value else { continue }
            _ = await oldest.task.value
        }
        guard !Task.isCancelled, epoch == invalidationGeneration else { return nil }
        let identity = UUID()
        let cancellation = CanvasOverviewTransitionPreparation()
        buildCount += 1
        let queueInterval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Raster queue wait")
        let task = Task<UIImage?, Never> { [weak self] in
            let image: UIImage? = await withCheckedContinuation { continuation in
                queue.async {
                    CanvasOverviewPreparationMetrics.signposter.endInterval("Raster queue wait", queueInterval)
                    let interval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Endpoint or viewport raster")
                    let image = autoreleasepool { cancellation.isCancelled ? nil : render(cancellation) }
                    CanvasOverviewPreparationMetrics.signposter.endInterval("Endpoint or viewport raster", interval)
                    continuation.resume(returning: cancellation.isCancelled ? nil : image)
                }
            }
            guard let self, self.jobs[key]?.identity == identity else { return nil }
            self.jobs.removeValue(forKey: key)
            guard !cancellation.isCancelled, epoch == self.invalidationGeneration else { return nil }
            if let image, let bitmap = image.cgImage {
                self.images.insert(image, for: key, cost: bitmap.bytesPerRow * bitmap.height)
            }
            return image
        }
        let job = Job(identity: identity, order: buildCount, cancellation: cancellation, task: task)
        jobs[key] = job
        return await join(job, epoch: epoch)
    }

    /// 等待者只保护自己的需求；最后一个消费者取消后允许正在绘制的单元结束，不再交付。
    private func join(_ job: Job, epoch: Int) async -> UIImage? {
        let consumer = UUID()
        job.consumers.insert(consumer)
        return await withTaskCancellationHandler {
            defer { release(consumer, from: job) }
            guard !Task.isCancelled else { return nil }
            let image = await job.task.value
            guard !Task.isCancelled, !job.cancellation.isCancelled, epoch == invalidationGeneration else { return nil }
            return image
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.release(consumer, from: job) }
        }
    }

    /// 消费者身份消除取消和正常结束的双重释放；受另一端点保护的工作继续执行。
    private func release(_ consumer: UUID, from job: Job) {
        guard job.consumers.remove(consumer) != nil, job.consumers.isEmpty else { return }
        job.cancellation.cancel()
        job.task.cancel()
    }

    /// 不改变当前可信表面，仅释放可重建缓存并停止后续绘制单元；迟到结果无法进入新缓存。
    func removeAll() {
        invalidationGeneration += 1
        for job in jobs.values { job.cancellation.cancel(); job.task.cancel() }
        jobs.removeAll()
        images.removeUnprotected()
    }
}
