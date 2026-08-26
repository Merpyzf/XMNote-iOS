/**
 * [INPUT]: 依赖 NoteMergeViewModel、ContentEditorImageSection、OCR Repository 与 XMToastCenter
 * [OUTPUT]: 对外提供 NoteMergeImageEditorSheet，承载合并草稿附图的增删、排序、重试与 OCR
 * [POS]: Views/Note/Sheets 的书摘合并图片业务 Sheet；图片状态仍由 NoteMergeViewModel 持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 合并附图编辑 Sheet 复用生产附件条、相册/相机/OCR 与每日额度策略。
struct NoteMergeImageEditorSheet: View {
    @Bindable var viewModel: NoteMergeViewModel
    let ocrRepository: any OCRRepositoryProtocol

    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter

    var body: some View {
        NavigationStack {
            ScrollView {
                ContentEditorImageSection(
                    items: contentImageItems,
                    accessibilityNamespace: "note_merge.attachment_strip",
                    ocrRepository: ocrRepository,
                    availableSelectionCount: viewModel.availableImageSelectionCount,
                    onStageImages: { inputs in
                        await viewModel.stageImages(inputs)
                        presentImageErrorIfNeeded()
                    },
                    onMove: viewModel.moveImage,
                    onRemove: viewModel.removeImage,
                    onRetry: viewModel.retryImage,
                    onRecognizedText: { text in
                        viewModel.appendRecognizedTextToContent(text)
                        toastCenter.success("识别文字已追加到合并正文")
                    },
                    onTransferError: { toastCenter.error($0) },
                    onQuotaBlocked: {
                        toastCenter.error(
                            viewModel.imageQuotaState?.blockedMessage ?? "当前无法继续添加图片"
                        )
                    }
                )
                .padding(Spacing.screenEdge)
            }
            .background(Color.surfacePage)
            .navigationTitle("编辑合并图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var contentImageItems: [ContentEditorImageItem] {
        (viewModel.draft?.imageItems ?? []).map { item in
            ContentEditorImageItem(
                id: item.id,
                remoteURL: item.remoteURL,
                localFilePath: item.localFilePath,
                uploadState: contentUploadState(item.uploadState),
                origin: item.origin
            )
        }
    }

    private func contentUploadState(
        _ state: NoteEditorImageUploadState
    ) -> ContentEditorImageUploadState {
        switch state {
        case .uploading: .uploading
        case .success: .success
        case .failed: .failed
        }
    }

    private func presentImageErrorIfNeeded() {
        guard let message = viewModel.imageErrorMessage else { return }
        toastCenter.error(message)
        viewModel.clearImageError()
    }
}
