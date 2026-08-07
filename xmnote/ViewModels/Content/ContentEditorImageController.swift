/**
 * [INPUT]: 依赖 S3UploadRepositoryProtocol 承接图片暂存、上传与缓存清理，依赖 ContentEditorImageItem 描述稳定编辑状态
 * [OUTPUT]: 对外提供 ContentEditorImageController，统一驱动书评/相关内容附图的选择、草稿缓存恢复、上传、失败重试、删除与拖动排序
 * [POS]: ViewModels/Content 的共享图片状态编排器，被 ReviewEditorViewModel 与 RelevantEditorViewModel 组合使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 内容编辑器图片状态编排器，确保文件写入和远端上传始终通过 Repository 完成。
@MainActor
@Observable
final class ContentEditorImageController {
    var items: [ContentEditorImageItem] = [] {
        didSet {
            guard items != oldValue else { return }
            itemsChangedHandler?()
        }
    }
    var errorMessage: String?

    private let repository: any S3UploadRepositoryProtocol
    private let uploadPrefix: String
    @ObservationIgnored private var itemsChangedHandler: (() -> Void)?
    private var uploadTasks: [String: Task<Void, Never>] = [:]

    /// 注入上传仓储与业务对象键前缀，避免 ViewModel 直接访问文件系统或网络客户端。
    init(repository: any S3UploadRepositoryProtocol, uploadPrefix: String) {
        self.repository = repository
        self.uploadPrefix = uploadPrefix
    }

    /// 页面状态释放时取消尚未结束的上传任务，避免异步结果越过编辑器生命周期回写。
    isolated deinit {
        uploadTasks.values.forEach { $0.cancel() }
    }

    /// 注册附件状态变化回调，使组合它的编辑 ViewModel 能统一触发防抖草稿保存。
    func setItemsChangedHandler(_ handler: @escaping () -> Void) {
        itemsChangedHandler = handler
    }

    /// 装载数据库中的成功图片；首次加载前会取消本控制器尚未结束的上传任务。
    func loadExistingItems(_ items: [ContentEditorImageItem]) {
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        self.items = items
        errorMessage = nil
    }

    /// 恢复自动草稿附图：远端成功项始终保留，本地项经仓储校验后转为可重试失败态。
    func loadRecoveredItems(_ draftItems: [ContentEditorImageItem]) async {
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()

        var recoveredItems: [ContentEditorImageItem] = []
        recoveredItems.reserveCapacity(draftItems.count)
        var invalidLocalCount = 0

        for var item in draftItems.prefix(ContentEditorImageItem.maximumCount) {
            guard !Task.isCancelled else { return }
            let remoteURL = item.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !remoteURL.isEmpty {
                if let localFilePath = item.localFilePath, !localFilePath.isEmpty {
                    await repository.discardStagedFile(at: URL(fileURLWithPath: localFilePath))
                }
                item.remoteURL = remoteURL
                item.localFilePath = nil
                item.uploadState = .success
                recoveredItems.append(item)
                continue
            }

            guard let localFilePath = item.localFilePath, !localFilePath.isEmpty,
                  await repository.isStagedFileAvailable(
                    at: URL(fileURLWithPath: localFilePath)
                  ) else {
                invalidLocalCount += 1
                continue
            }
            item.remoteURL = nil
            item.uploadState = .failed
            recoveredItems.append(item)
        }

        items = recoveredItems
        if invalidLocalCount > 0 {
            errorMessage = "有 \(invalidLocalCount) 张本地图片缓存已失效，已从恢复草稿中移除"
        } else {
            errorMessage = nil
        }
    }

    /// 把相册图片交给仓储暂存，并逐张启动真实上传；每张图片独立暴露 uploading/success/failed 状态。
    func stageImages(_ inputs: [(data: Data, fileExtension: String)]) async {
        guard !inputs.isEmpty else { return }
        let remainingCount = ContentEditorImageItem.maximumCount - items.count
        guard remainingCount > 0 else {
            errorMessage = "最多只能添加 \(ContentEditorImageItem.maximumCount) 张图片"
            return
        }
        if inputs.count > remainingCount {
            errorMessage = "最多只能添加 \(ContentEditorImageItem.maximumCount) 张图片，已保留前 \(remainingCount) 张"
        } else {
            errorMessage = nil
        }

        for input in inputs.prefix(remainingCount) {
            guard !Task.isCancelled else { return }
            await stageImage(data: input.data, fileExtension: input.fileExtension)
        }
    }

    /// 删除指定图片并清理未保存的本地缓存；远端对象可能被其他内容复用，因此不在此处删除。
    func removeImage(id: String) async {
        uploadTasks[id]?.cancel()
        uploadTasks[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removedItem = items.remove(at: index)
        await discardLocalFileIfNeeded(removedItem)
    }

    /// 将失败图片重新置为上传中并复用同一暂存缓存重试。
    func retryImage(id: String) {
        guard let item = items.first(where: { $0.id == id }),
              item.uploadState == .failed,
              item.localFilePath?.isEmpty == false else {
            return
        }
        startUpload(for: item)
    }

    /// 按附件条拖动结果更新顺序；保存时图片子表将使用这一顺序写入 order。
    func moveImage(sourceID: String, destinationID: String) {
        guard let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = items.firstIndex(where: { $0.id == destinationID }),
              sourceIndex != destinationIndex else {
            return
        }
        var reordered = items
        let movedItem = reordered.remove(at: sourceIndex)
        reordered.insert(movedItem, at: min(destinationIndex, reordered.count))
        items = reordered
    }

    /// 放弃编辑时取消全部上传并清理本会话创建的暂存缓存；既有远端图片不受影响。
    func discardEditingSession() async {
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        for item in items {
            await discardLocalFileIfNeeded(item)
        }
    }

    /// 清理尚未载入当前控制器的草稿暂存图，只移除本地缓存，不触碰远端图片。
    func discardStagedFiles(in draftItems: [ContentEditorImageItem]) async {
        for item in draftItems {
            await discardLocalFileIfNeeded(item)
        }
    }

    /// 保留草稿退出前停止上传，并把中断项转为可在下次恢复时重试的失败态。
    func pauseUploadsPreservingStagedFiles() {
        uploadTasks.values.forEach { $0.cancel() }
        uploadTasks.removeAll()
        items = items.map { item in
            guard item.uploadState == .uploading else { return item }
            var pausedItem = item
            pausedItem.uploadState = .failed
            return pausedItem
        }
    }

    /// 清空已被界面消费的上传错误，允许相同失败再次触发标准系统弹窗。
    func clearError() {
        errorMessage = nil
    }

    var hasUploadingImage: Bool {
        items.contains { $0.uploadState == .uploading }
    }

    var hasFailedImage: Bool {
        items.contains { $0.uploadState == .failed }
    }

    var newDraftImageCount: Int {
        items.count { $0.origin == .newInDraft }
    }

    /// 主内容保存并完成额度登记后更新来源，阻止同一编辑会话后续保存重复计数。
    func markDraftImagesAsPersisted() {
        items = items.map { item in
            var updatedItem = item
            updatedItem.origin = .persisted
            return updatedItem
        }
    }
}

private extension ContentEditorImageController {
    /// 暂存单张图片并立即加入上传条；任务取消后不会把过期结果写回界面。
    func stageImage(data: Data, fileExtension: String) async {
        do {
            let localURL = try await repository.stageImageData(
                data,
                preferredFileExtension: fileExtension
            )
            guard !Task.isCancelled else {
                await repository.discardStagedFile(at: localURL)
                return
            }
            let item = ContentEditorImageItem(
                id: UUID().uuidString,
                remoteURL: nil,
                localFilePath: localURL.path,
                uploadState: .uploading,
                origin: .newInDraft
            )
            items.append(item)
            startUpload(for: item)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "图片暂存失败：\(Self.errorDescription(error))"
        }
    }

    /// 为单张暂存图建立可取消上传任务；成功清理本地缓存，失败保留缓存以便重试。
    func startUpload(for item: ContentEditorImageItem) {
        guard let localFilePath = item.localFilePath, !localFilePath.isEmpty else { return }
        updateItem(id: item.id) {
            $0.uploadState = .uploading
        }
        uploadTasks[item.id]?.cancel()
        let repository = repository
        let uploadPrefix = uploadPrefix
        uploadTasks[item.id] = Task { [weak self] in
            do {
                let result = try await repository.uploadFile(
                    localURL: URL(fileURLWithPath: localFilePath),
                    prefix: uploadPrefix,
                    progress: nil
                )
                guard !Task.isCancelled else { return }
                await repository.discardStagedFile(at: URL(fileURLWithPath: localFilePath))
                guard !Task.isCancelled else { return }
                self?.updateItem(id: item.id) {
                    $0.remoteURL = result.remoteURL.absoluteString
                    $0.localFilePath = nil
                    $0.uploadState = .success
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.updateItem(id: item.id) {
                    $0.uploadState = .failed
                }
                self?.errorMessage = "图片上传失败：\(Self.errorDescription(error))"
            }
            self?.uploadTasks[item.id] = nil
        }
    }

    /// 以稳定 ID 原位更新单个条目，避免异步上传结果影响其他图片顺序。
    func updateItem(id: String, mutation: (inout ContentEditorImageItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&items[index])
    }

    /// 仅清理由本会话暂存的本地文件，不触碰远端 URL。
    func discardLocalFileIfNeeded(_ item: ContentEditorImageItem) async {
        guard let localFilePath = item.localFilePath, !localFilePath.isEmpty else { return }
        await repository.discardStagedFile(at: URL(fileURLWithPath: localFilePath))
    }

    /// 优先提取业务可读错误，再回退系统本地化描述。
    nonisolated static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
