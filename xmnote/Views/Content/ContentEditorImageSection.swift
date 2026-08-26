/**
 * [INPUT]: 依赖 PhotosUI 与系统相机读取用户图片，依赖 AVFoundation 判断相机权限，依赖 XMAttachmentUploadStrip 呈现上传/预览/重排状态，依赖 NotePhotoOCRFlowView 提供真实图片识字
 * [OUTPUT]: 对外提供 ContentEditorImageSection，统一承接书评与相关内容编辑器的相册/拍照附图、权限反馈、上传、删除、重试、排序、预览与 OCR 入口
 * [POS]: Views/Content 的模块共享表单区块，只复用项目既有组件与设计令牌，不定义新的视觉语言
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 书评与相关内容共用的图片编辑区块，使用 iOS 相册选择和项目标准附件条表达 Android 业务语义。
struct ContentEditorImageSection: View {
    let items: [ContentEditorImageItem]
    let accessibilityNamespace: String
    let ocrRepository: any OCRRepositoryProtocol
    let availableSelectionCount: Int
    let onStageImages: ([(data: Data, fileExtension: String)]) async -> Void
    let onMove: (_ sourceID: String, _ destinationID: String) -> Void
    let onRemove: (_ id: String) async -> Void
    let onRetry: (_ id: String) -> Void
    let onRecognizedText: (_ text: String) -> Void
    let onTransferError: (_ message: String) -> Void
    let onQuotaBlocked: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isReadingSelection = false
    @State private var cameraAuthorizationTask: Task<Void, Never>?
    @State private var showsCamera = false
    @State private var showsPhotoOCRFlow = false
    @State private var cameraAlert: ContentEditorCameraAlert?

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                header

                if items.isEmpty {
                    Text("暂无关联图片，可拍照、从相册添加或使用图片识字")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    attachmentStrip
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))

                    Text("长按图片可调整顺序；上传失败时可直接重试。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                actionRow
            }
            .padding(Spacing.contentEdge)
        }
        .animation(reduceMotion ? .smooth(duration: 0.12) : .smooth(duration: 0.28), value: items.isEmpty)
        .task(id: selectedPhotoItems) {
            await consumeSelectedPhotos()
        }
        .fullScreenCover(isPresented: $showsPhotoOCRFlow) {
            NotePhotoOCRFlowView(
                target: .content,
                repository: ocrRepository
            ) { payload in
                onRecognizedText(payload.summary.combinedText)
            }
        }
        .fullScreenCover(isPresented: $showsCamera) {
            ContentEditorCameraPicker(onComplete: handleCameraResult)
                .ignoresSafeArea()
        }
        .xmSystemAlert(item: $cameraAlert, descriptor: cameraAlertDescriptor)
        .onDisappear {
            cameraAuthorizationTask?.cancel()
            cameraAuthorizationTask = nil
        }
    }
}

private extension ContentEditorImageSection {
    var effectiveAvailableSelectionCount: Int {
        min(
            max(0, ContentEditorImageItem.maximumCount - items.count),
            max(0, availableSelectionCount)
        )
    }

    var header: some View {
        HStack(spacing: Spacing.base) {
            Text("图片")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textSecondary)

            Spacer(minLength: Spacing.half)

            Text("\(items.count)/\(ContentEditorImageItem.maximumCount)")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    var attachmentStrip: some View {
        XMAttachmentUploadStrip(
            items: items.map { item in
                XMAttachmentUploadItem(
                    id: item.id,
                    localFilePath: item.localFilePath,
                    remoteURL: item.remoteURL,
                    uploadState: attachmentState(item.uploadState)
                )
            },
            allowsFullScreenPreview: true,
            accessibilityNamespace: accessibilityNamespace,
            onMove: onMove,
            onRemove: { id in
                Task { @MainActor in
                    await onRemove(id)
                }
            },
            onRetry: onRetry
        )
    }

    var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.cozy) {
                cameraButton
                albumControl
                photoOCRButton
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Spacing.compact) {
                cameraButton
                albumControl
                photoOCRButton
            }
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: effectiveAvailableSelectionCount == 0
        )
    }

    var cameraButton: some View {
        Button(action: requestCameraPresentation) {
            Label("拍照", systemImage: "camera")
                .font(AppTypography.subheadline)
                .lineLimit(1)
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        }
        .disabled(isReadingSelection || items.count >= ContentEditorImageItem.maximumCount)
    }

    @ViewBuilder
    var albumControl: some View {
        if effectiveAvailableSelectionCount == 0 {
            Button(action: onQuotaBlocked) {
                albumLabel
            }
            .disabled(isReadingSelection)
        } else {
            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: effectiveAvailableSelectionCount,
                matching: .images
            ) {
                albumLabel
            }
            .disabled(isReadingSelection)
        }
    }

    var photoOCRButton: some View {
        Button {
            showsPhotoOCRFlow = true
        } label: {
            Label("图片识字", systemImage: "text.viewfinder")
                .font(AppTypography.subheadline)
                .lineLimit(1)
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        }
        .disabled(isReadingSelection)
    }

    var albumLabel: some View {
        Label(isReadingSelection ? "正在读取…" : "相册", systemImage: "photo.badge.plus")
            .font(AppTypography.subheadline)
            .lineLimit(1)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
    }

    /// 拍照入口先校验硬件与授权状态，只有可安全取图时才展示系统全屏相机。
    func requestCameraPresentation() {
        guard items.count < ContentEditorImageItem.maximumCount else { return }
        guard effectiveAvailableSelectionCount > 0 else {
            onQuotaBlocked()
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraAlert = .unavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showsCamera = true
        case .notDetermined:
            cameraAuthorizationTask?.cancel()
            cameraAuthorizationTask = Task { @MainActor in
                defer { cameraAuthorizationTask = nil }
                let isGranted = await Self.requestCameraAccess()
                guard !Task.isCancelled else { return }
                if isGranted {
                    showsCamera = true
                } else {
                    cameraAlert = .denied
                }
            }
        case .denied:
            cameraAlert = .denied
        case .restricted:
            cameraAlert = .restricted
        @unknown default:
            cameraAlert = .unavailable
        }
    }

    /// 系统相机只回传归一化 JPEG 数据；附件上传继续复用与相册完全相同的 Repository 链路。
    func handleCameraResult(_ result: ContentEditorCameraResult) {
        showsCamera = false
        switch result {
        case .captured(let data):
            Task { @MainActor in
                await onStageImages([(data: data, fileExtension: "jpg")])
            }
        case .cancelled:
            break
        case .processingFailed:
            cameraAlert = .processingFailed
        }
    }

    /// 按项目系统弹窗规范解释不可用状态；只有明确拒绝时提供可行动的设置入口。
    func cameraAlertDescriptor(_ alert: ContentEditorCameraAlert) -> XMSystemAlertDescriptor {
        switch alert {
        case .unavailable:
            return XMSystemAlertDescriptor(
                title: "当前无法拍照",
                message: "未检测到可用相机。你仍可从相册添加图片。",
                actions: [XMSystemAlertAction(title: "知道了", role: .cancel) { }]
            )
        case .denied:
            return XMSystemAlertDescriptor(
                title: "需要相机权限",
                message: "请在系统设置中允许“纸间书摘”使用相机，然后返回继续拍照。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "前往设置") {
                        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(settingsURL)
                    }
                ]
            )
        case .restricted:
            return XMSystemAlertDescriptor(
                title: "相机访问受限",
                message: "当前设备策略或家长控制限制了相机访问。你仍可从相册添加图片。",
                actions: [XMSystemAlertAction(title: "知道了", role: .cancel) { }]
            )
        case .processingFailed:
            return XMSystemAlertDescriptor(
                title: "照片处理失败",
                message: "没有获得可上传的照片数据，请重新拍摄或改从相册添加。",
                actions: [XMSystemAlertAction(title: "知道了", role: .cancel) { }]
            )
        }
    }

    /// 桥接 AVFoundation 回调为结构化并发结果；页面离开会取消等待任务并忽略迟到的授权结果。
    nonisolated static func requestCameraAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { isGranted in
                continuation.resume(returning: isGranted)
            }
        }
    }

    /// 读取相册 Transferable 后一次性交给 ViewModel；取消任务时不再启动上传或覆盖当前选择。
    func consumeSelectedPhotos() async {
        let selection = selectedPhotoItems
        guard !selection.isEmpty else { return }
        isReadingSelection = true
        defer {
            isReadingSelection = false
            selectedPhotoItems = []
        }

        do {
            var inputs: [(data: Data, fileExtension: String)] = []
            for item in selection {
                guard !Task.isCancelled else { return }
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                inputs.append((data: data, fileExtension: fileExtension))
            }
            guard !Task.isCancelled else { return }
            await onStageImages(inputs)
        } catch {
            guard !Task.isCancelled else { return }
            onTransferError("读取所选图片失败：\(Self.errorDescription(error))")
        }
    }

    /// 将领域上传状态映射为项目通用附件条状态。
    func attachmentState(_ state: ContentEditorImageUploadState) -> XMAttachmentUploadState {
        switch state {
        case .uploading: .uploading
        case .success: .success
        case .failed: .failed
        }
    }

    /// 优先提取业务可读错误，再回退系统本地化描述。
    nonisolated static func errorDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// 内容附件相机的可行动异常状态，使用稳定 ID 驱动项目标准系统弹窗。
private enum ContentEditorCameraAlert: String, Identifiable {
    case unavailable
    case denied
    case restricted
    case processingFailed

    var id: String { rawValue }
}

/// 系统相机完成结果，明确区分用户取消与图像处理失败，避免把取消误报为错误。
private enum ContentEditorCameraResult {
    case captured(Data)
    case cancelled
    case processingFailed
}

/// 书评/相关内容页面私有的系统相机桥接；相机采用全屏呈现并使用系统裁剪界面。
private struct ContentEditorCameraPicker: UIViewControllerRepresentable {
    let onComplete: (ContentEditorCameraResult) -> Void

    /// 建立只采集静态图片的系统相机，复用系统控制、方向与裁剪交互。
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = true
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    static func dismantleUIViewController(
        _ uiViewController: UIImagePickerController,
        coordinator: Coordinator
    ) {
        uiViewController.delegate = nil
    }

    /// UIKit delegate 协调器只回传内存数据，不写文件也不接触网络。
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onComplete: (ContentEditorCameraResult) -> Void
        private var hasCompleted = false

        init(onComplete: @escaping (ContentEditorCameraResult) -> Void) {
            self.onComplete = onComplete
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completeOnce(.cancelled)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage,
                  let data = ContentEditorCameraImageProcessor.makeJPEGData(from: image) else {
                completeOnce(.processingFailed)
                return
            }
            completeOnce(.captured(data))
        }

        private func completeOnce(_ result: ContentEditorCameraResult) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onComplete(result)
        }
    }
}

/// 相机图片处理器将 EXIF 方向烘焙到像素，并限制最长边与 JPEG 体积，降低上传与草稿缓存压力。
private enum ContentEditorCameraImageProcessor {
    private static let maximumPixelDimension: CGFloat = 3_072
    private static let jpegCompressionQuality: CGFloat = 0.82

    /// 使用 UIKit 绘制得到 `.up` 方向的标准位图；绘制过程同时完成必要的等比缩小。
    @MainActor
    static func makeJPEGData(from image: UIImage) -> Data? {
        let sourceSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return nil
        }

        let longestEdge = max(sourceSize.width, sourceSize.height)
        let downscale = min(1, maximumPixelDimension / longestEdge)
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * downscale).rounded()),
            height: max(1, (sourceSize.height * downscale).rounded())
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let normalizedImage = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return normalizedImage.jpegData(compressionQuality: jpegCompressionQuality)
    }
}
