/**
 * [INPUT]: 依赖 OCRRepositoryProtocol 提供 OCR 偏好与百度识别能力，依赖 UIKit 承接图片裁切、排序与结果聚合
 * [OUTPUT]: 对外提供 NotePhotoOCRFlowViewModel 与正式书摘 OCR Flow 共享模型，驱动单框裁切识别流程
 * [POS]: ViewModels/Note 的书摘拍照 OCR 状态编排器，负责图片输入、裁切区域管理与识别结果回填
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import CoreImage
import ImageIO
import UIKit

/// 正式书摘 OCR Flow 的框选模式；当前正式页仅暴露单框，但保留底层自由框选能力以复用测试中心画布。
enum NotePhotoOCRSelectionMode: String, CaseIterable, Identifiable {
    case single
    case freeform

    var id: String { rawValue }
}

/// OCR 画布中的标准化裁切区域。
struct NotePhotoOCRSelectionRegion: Identifiable {
    let id: UUID
    var normalizedRect: CGRect
    let createdAt: Date

    init(
        id: UUID = UUID(),
        normalizedRect: CGRect,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.createdAt = createdAt
    }
}

/// 单个裁切区域的 OCR 结果包装。
struct NotePhotoOCRRecognitionItem: Identifiable {
    let id: UUID
    let region: NotePhotoOCRSelectionRegion
    let result: OCRRecognitionResult

    init(
        id: UUID = UUID(),
        region: NotePhotoOCRSelectionRegion,
        result: OCRRecognitionResult
    ) {
        self.id = id
        self.region = region
        self.result = result
    }
}

/// 正式书摘 OCR Flow 的识别汇总结果。
struct NotePhotoOCRRecognitionSummary {
    let target: NoteEditorComposerTarget
    let selectionMode: NotePhotoOCRSelectionMode
    let sourceTitle: String
    let combinedText: String
    let items: [NotePhotoOCRRecognitionItem]
}

/// 正式书摘 OCR Flow 识别完成后的回传载荷。
struct NotePhotoOCRCompletionPayload {
    let summary: NotePhotoOCRRecognitionSummary
}

@MainActor
@Observable
final class NotePhotoOCRFlowViewModel {
    private struct PreparedRecognitionRegion {
        let region: NotePhotoOCRSelectionRegion
        let imageData: Data
    }

    private let repository: any OCRRepositoryProtocol
    private var shouldPersistPreferences = false

    let target: NoteEditorComposerTarget

    var preferences: OCRPreferences {
        didSet {
            guard shouldPersistPreferences else { return }
            repository.savePreferences(preferences)
        }
    }

    var selectedImage: UIImage?
    var selectedSourceTitle = "未选择"
    var selectionMode: NotePhotoOCRSelectionMode = .single
    var singleSelectionRect: CGRect?
    var freeformRegions: [NotePhotoOCRSelectionRegion] = []
    var selectedFreeformRegionID: UUID?

    var isRecognizing = false
    var statusMessage: String?
    var errorMessage: String?

    init(
        target: NoteEditorComposerTarget,
        repository: any OCRRepositoryProtocol
    ) {
        self.target = target
        self.repository = repository
        self.preferences = repository.fetchPreferences()
        self.shouldPersistPreferences = true
    }

    var isRuntimeSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// 返回当前环境下的 OCR 运行提示。
    var runtimeHintText: String {
        if isRuntimeSupported {
            return "当前 Flow 使用百度 OCR SDK 的真机识别链路，识别完成后会自动回填到书摘编辑页。"
        }
        return "当前是模拟器环境。你仍可验证拍照入口降级、相册选图、裁切与多框交互，但无法实际调用百度 OCR SDK。"
    }

    var canRecognize: Bool {
        !isRecognizing
            && selectedImage != nil
            && preferences.credentials.isConfigured
            && activeSelectionCount > 0
    }

    var hasSelection: Bool {
        activeSelectionCount > 0
    }

    var activeSelectionCount: Int {
        switch selectionMode {
        case .single:
            return singleSelectionRect == nil ? 0 : 1
        case .freeform:
            return freeformRegions.count
        }
    }

    /// 宿主页或相机页选中图片后，重置当前框选状态并进入裁切页。
    func selectImage(_ image: UIImage, sourceTitle: String) {
        selectedImage = image.normalizedUpImage()
        selectedSourceTitle = sourceTitle
        selectionMode = .single
        singleSelectionRect = nil
        freeformRegions = []
        selectedFreeformRegionID = nil
        errorMessage = nil
        statusMessage = "已载入\(sourceTitle)图片，请在图片上拖动选框，以选择要识别的区域。"
    }

    /// 重置单框选择。
    func resetSingleSelection() {
        clearSingleSelection()
    }

    /// 清空单框选择，回到 Android 对齐的无框初始态。
    func clearSingleSelection() {
        singleSelectionRect = nil
    }

    /// 选中指定自由框选区域；传入 nil 表示取消选中。
    func selectFreeformRegion(id: UUID?) {
        selectedFreeformRegionID = id
    }

    /// 追加一个新的自由框选区域，并自动切到选中态。
    func appendFreeformRegion(_ normalizedRect: CGRect) {
        let region = NotePhotoOCRSelectionRegion(normalizedRect: normalizedRect.clampedToUnit)
        freeformRegions.append(region)
        selectedFreeformRegionID = region.id
    }

    /// 删除当前选中的自由框选区域。
    func deleteSelectedFreeformRegion() {
        guard let selectedFreeformRegionID else { return }
        freeformRegions.removeAll { $0.id == selectedFreeformRegionID }
        self.selectedFreeformRegionID = nil
    }

    /// 按区域 ID 删除指定自由框选区域，并同步清理选中态。
    func deleteFreeformRegion(id: UUID) {
        freeformRegions.removeAll { $0.id == id }
        if selectedFreeformRegionID == id {
            selectedFreeformRegionID = nil
        }
    }

    /// 清空所有自由框选区域。
    func clearFreeformRegions() {
        freeformRegions = []
        selectedFreeformRegionID = nil
    }

    /// 清理 SDK 鉴权缓存，便于调试配置切换。
    func clearAuthorizationCache() {
        repository.clearAuthorizationCache()
        statusMessage = "已清除百度 OCR 鉴权缓存。"
        errorMessage = nil
    }

    /// 对当前选择区域执行 OCR，并返回可直接回填到宿主页的汇总结果。
    func recognizeCurrentSelection() async -> NotePhotoOCRCompletionPayload? {
        guard let selectedImage else {
            errorMessage = "请先拍照或从相册选择一张图片。"
            return nil
        }

        guard preferences.credentials.isConfigured else {
            errorMessage = "请先填写 API Key 与 Secret Key。"
            return nil
        }

        let orderedRegions = orderedSelectionRegions()
        guard !orderedRegions.isEmpty else {
            errorMessage = selectionMode == .single ? "请先在图片上拖动选框，以选择要识别的区域。" : "请先框选至少一个识别区域。"
            return nil
        }

        isRecognizing = true
        errorMessage = nil
        statusMessage = "正在识别..."

        defer {
            isRecognizing = false
        }

        do {
            await Task.yield()

            let preparedRegions = try await Self.prepareRecognitionRegions(
                image: selectedImage,
                orderedRegions: orderedRegions
            )

            var items: [NotePhotoOCRRecognitionItem] = []
            for preparedRegion in preparedRegions {
                let result = try await repository.recognizeText(
                    request: OCRRecognitionRequest(
                        imageData: preparedRegion.imageData,
                        preferences: preferences
                    )
                )

                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                items.append(
                    NotePhotoOCRRecognitionItem(
                        region: preparedRegion.region,
                        result: result
                    )
                )
            }

            let combinedText = items
                .map(\.result.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            guard !combinedText.isEmpty else {
                throw OCRRepositoryError.emptyText
            }

            let summary = NotePhotoOCRRecognitionSummary(
                target: target,
                selectionMode: selectionMode,
                sourceTitle: selectedSourceTitle,
                combinedText: combinedText,
                items: items
            )

            statusMessage = "识别完成，结果已准备回填到\(target.title)。"
            return NotePhotoOCRCompletionPayload(summary: summary)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = nil
            return nil
        }
    }
}

private extension NotePhotoOCRFlowViewModel {
    private nonisolated static func prepareRecognitionRegions(
        image: UIImage,
        orderedRegions: [NotePhotoOCRSelectionRegion]
    ) async throws -> [PreparedRecognitionRegion] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let preparedRegions = try orderedRegions.map { region in
                        guard let croppedImage = crop(image: image, normalizedRect: region.normalizedRect),
                              let imageData = croppedImage.jpegData(compressionQuality: 0.92) else {
                            throw OCRRepositoryError.invalidImageData
                        }

                        return PreparedRecognitionRegion(
                            region: region,
                            imageData: imageData
                        )
                    }

                    continuation.resume(returning: preparedRegions)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func orderedSelectionRegions() -> [NotePhotoOCRSelectionRegion] {
        switch selectionMode {
        case .single:
            guard selectedImage != nil, let singleSelectionRect else { return [] }
            return [NotePhotoOCRSelectionRegion(normalizedRect: singleSelectionRect.clampedToUnit)]
        case .freeform:
            return sortRegionsInReadingOrder(freeformRegions)
        }
    }

    nonisolated static func crop(image: UIImage, normalizedRect: CGRect) -> UIImage? {
        let normalizedImage = image.normalizedUpImage()
        guard let cgImage = normalizedImage.cgImage else { return nil }

        let clamped = normalizedRect.clampedToUnit
        let pixelRect = CGRect(
            x: clamped.minX * CGFloat(cgImage.width),
            y: clamped.minY * CGFloat(cgImage.height),
            width: clamped.width * CGFloat(cgImage.width),
            height: clamped.height * CGFloat(cgImage.height)
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard pixelRect.width > 1,
              pixelRect.height > 1,
              let cropped = cgImage.cropping(to: pixelRect) else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: normalizedImage.scale, orientation: .up)
    }

    func sortRegionsInReadingOrder(_ regions: [NotePhotoOCRSelectionRegion]) -> [NotePhotoOCRSelectionRegion] {
        let verticallySorted = regions.sorted {
            if abs($0.normalizedRect.midY - $1.normalizedRect.midY) < 0.0001 {
                return $0.normalizedRect.minX < $1.normalizedRect.minX
            }
            return $0.normalizedRect.midY < $1.normalizedRect.midY
        }

        var groupedRegions: [[NotePhotoOCRSelectionRegion]] = []
        for region in verticallySorted {
            guard var lastGroup = groupedRegions.popLast() else {
                groupedRegions.append([region])
                continue
            }

            let referenceMidY = lastGroup
                .map(\.normalizedRect.midY)
                .reduce(0, +) / CGFloat(lastGroup.count)
            let referenceHeight = lastGroup
                .map(\.normalizedRect.height)
                .reduce(0, +) / CGFloat(lastGroup.count)
            let threshold = min(referenceHeight, region.normalizedRect.height) * 0.5

            if abs(region.normalizedRect.midY - referenceMidY) <= threshold {
                lastGroup.append(region)
                groupedRegions.append(lastGroup)
            } else {
                groupedRegions.append(lastGroup)
                groupedRegions.append([region])
            }
        }

        return groupedRegions.flatMap { group in
            group.sorted { lhs, rhs in
                lhs.normalizedRect.minX < rhs.normalizedRect.minX
            }
        }
    }
}

private extension CGRect {
    nonisolated var clampedToUnit: CGRect {
        let width = min(max(size.width, 0.04), 1)
        let height = min(max(size.height, 0.04), 1)
        let x = min(max(origin.x, 0), 1 - width)
        let y = min(max(origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension UIImage {
    nonisolated func normalizedUpImage() -> UIImage {
        guard imageOrientation != .up else { return self }
        guard let cgImage else { return self }

        let exifOrientation: CGImagePropertyOrientation = switch imageOrientation {
        case .up:
            .up
        case .down:
            .down
        case .left:
            .left
        case .right:
            .right
        case .upMirrored:
            .upMirrored
        case .downMirrored:
            .downMirrored
        case .leftMirrored:
            .leftMirrored
        case .rightMirrored:
            .rightMirrored
        @unknown default:
            .up
        }

        let ciImage = CIImage(cgImage: cgImage)
            .oriented(forExifOrientation: Int32(exifOrientation.rawValue))
        let extent = ciImage.extent.integral
        guard extent.width > 0,
              extent.height > 0,
              let uprightCGImage = CIContext(options: nil).createCGImage(ciImage, from: extent) else {
            return self
        }

        return UIImage(cgImage: uprightCGImage, scale: scale, orientation: .up)
    }
}
