/**
 * [INPUT]: 依赖 OCRRepositoryProtocol 与 NotePhotoOCRFlowViewModel 驱动正式书摘 OCR 状态，依赖 AVFoundation/PhotosUI 提供拍照与选图能力
 * [OUTPUT]: 对外提供 NotePhotoOCRFlowView，承载书摘编辑页的拍照、单框裁切与识别回填流程
 * [POS]: Views/Note/Components 的页面私有子视图，负责对齐 Android 的正式拍照 OCR 主流程
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@preconcurrency import AVFoundation
import Combine
import CoreImage
import ImageIO
import PhotosUI
import SwiftUI
import UIKit

private enum OCRFlowRoute: Hashable {
    case crop
}

struct NotePhotoOCRFlowView: View {
    let target: NoteEditorComposerTarget
    let onComplete: (NotePhotoOCRCompletionPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: NotePhotoOCRFlowViewModel
    @StateObject private var cameraController = OCRCameraSessionController()
    @State private var path: [OCRFlowRoute] = []

    init(
        target: NoteEditorComposerTarget,
        repository: any OCRRepositoryProtocol,
        onComplete: @escaping (NotePhotoOCRCompletionPayload) -> Void
    ) {
        self.target = target
        self.onComplete = onComplete
        _viewModel = State(initialValue: NotePhotoOCRFlowViewModel(target: target, repository: repository))
    }

    var body: some View {
        NavigationStack(path: $path) {
            OCRCameraScreen(
                viewModel: viewModel,
                cameraController: cameraController,
                onClose: { dismiss() },
                onSelectedImage: handleSelectedImage(_:sourceTitle:)
            )
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(for: OCRFlowRoute.self) { route in
                switch route {
                case .crop:
                    OCRCropRecognitionScreen(
                        viewModel: viewModel,
                        onBack: popCropScreen,
                        onRecognized: handleRecognitionCompleted(_:)
                    )
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func handleSelectedImage(_ image: UIImage, sourceTitle: String) {
        viewModel.selectImage(image, sourceTitle: sourceTitle)
        path.append(.crop)
    }

    private func popCropScreen() {
        guard path.last == .crop else { return }
        path.removeLast()
    }

    private func handleRecognitionCompleted(_ payload: NotePhotoOCRCompletionPayload) {
        onComplete(payload)
        dismiss()
    }
}

private struct OCRCameraScreen: View {
    private struct FocusIndicatorState: Equatable {
        let point: CGPoint
        let scale: CGFloat
        let opacity: Double
        let highlightOpacity: Double
    }

    private static let darkForegroundPrimary = Color.white.opacity(0.96)
    private static let darkForegroundSecondary = Color.white.opacity(0.72)

    @Bindable var viewModel: NotePhotoOCRFlowViewModel
    @ObservedObject var cameraController: OCRCameraSessionController
    let onClose: () -> Void
    let onSelectedImage: (UIImage, String) -> Void

    @AppStorage("note.photo_ocr.camera_tip_count") private var cameraTipDisplayCount = 0
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isLoadingPhotoItem = false
    @State private var photoLoadingErrorMessage: String?
    @State private var focusIndicatorState: FocusIndicatorState?
    @State private var focusIndicatorToken = UUID()
    @State private var guideTipToken = UUID()
    @State private var showsGuideTip = false

    var body: some View {
        cameraStage
        .background(Color.black.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            topOverlay
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomOverlay
        }
        .task(id: selectedPhotoItem) {
            guard let selectedPhotoItem else { return }
            await consumePhotoItem(selectedPhotoItem)
        }
        .onAppear {
            cameraController.prepareSession()
        }
        .onDisappear {
            cameraController.stopSession()
        }
        .onChange(of: cameraController.isReady) { _, isReady in
            if isReady {
                showGuideTipIfNeeded()
            }
        }
        .xmSystemAlert(
            isPresented: $photoLoadingErrorMessage.isPresented(),
            descriptor: XMSystemAlertDescriptor(
                title: "图片载入失败",
                message: photoLoadingErrorMessage ?? "相册图片读取失败，请重新选择。",
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) { }
                ]
            )
        )
        .environment(\.colorScheme, .dark)
    }
}

private extension OCRCameraScreen {
    var cameraStage: some View {
        ZStack {
            cameraPreviewLayer

            VStack(spacing: 0) {
                topEdgeScrim
                Spacer(minLength: 0)
                bottomEdgeScrim
            }
            .allowsHitTesting(false)

            if let focusIndicatorState {
                focusIndicator(state: focusIndicatorState)
            }
        }
        .ignoresSafeArea()
    }

    var topEdgeScrim: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.52),
                Color.black.opacity(0.18),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 164)
    }

    var bottomEdgeScrim: some View {
        LinearGradient(
            colors: [
                Color.clear,
                Color.black.opacity(0.2),
                Color.black.opacity(0.58)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 220)
    }

    @ViewBuilder
    var cameraPreviewLayer: some View {
        if cameraController.shouldShowFailurePlaceholder {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        Color.brand.opacity(0.12),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: Spacing.base) {
                    Image(systemName: cameraController.placeholderIconName)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.78))

                    Text(cameraController.stateMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .multilineTextAlignment(.center)

                    Text("即使当前设备无法打开相机，你仍可通过底部“相册”按钮进入裁切识别页。")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.double)
            }
        } else {
            ZStack {
                Color.black

                if cameraController.hasPreparedPreview {
                    OCRCameraPreview(
                        controller: cameraController,
                        onTapToFocus: handleTapToFocus(_:)
                    )
                }
            }
        }
    }

    var topOverlay: some View {
        VStack(spacing: Spacing.base) {
            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    Button(action: onClose) {
                        TopBarActionIcon(
                            systemName: "xmark",
                            iconSize: 15,
                            weight: .semibold,
                            foregroundColor: Self.darkForegroundPrimary
                        )
                    }
                    .topBarGlassButtonStyle(true)
                    .accessibilityLabel("关闭 OCR 流程")
                }
            }

            if let bannerText = cameraBannerText {
                banner(text: bannerText, tint: cameraController.isReady ? Color.brand : Color.feedbackWarning)
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.half)
        .padding(.bottom, Spacing.base)
    }

    var bottomOverlay: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if showsGuideTip {
                tipCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            GlassEffectContainer(spacing: Spacing.double) {
                HStack(alignment: .bottom, spacing: Spacing.double) {
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images
                    ) {
                        controlColumn(
                            symbol: "photo.on.rectangle.angled",
                            isProminent: false,
                            isDisabled: isLoadingPhotoItem,
                            isLoading: isLoadingPhotoItem
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isLoadingPhotoItem ? "正在读取相册图片" : "从相册选择图片")

                    Spacer(minLength: 0)

                    Button(action: capturePhoto) {
                        captureButton
                    }
                    .buttonStyle(.plain)
                    .disabled(!cameraController.canCapturePhoto)

                    Spacer(minLength: 0)

                    Button(action: cameraController.toggleFlashMode) {
                        controlColumn(
                            symbol: cameraController.flashMode == .on ? "bolt.fill" : "bolt.slash.fill",
                            isProminent: false,
                            isDisabled: !cameraController.isFlashAvailable,
                            isLoading: false
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!cameraController.isFlashAvailable)
                    .accessibilityLabel(cameraController.flashMode == .on ? "关闭闪光灯" : "打开闪光灯")
                }
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.half)
        .padding(.bottom, Spacing.base)
    }

    var tipCard: some View {
        HStack(alignment: .top, spacing: Spacing.half) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brand)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("拍摄建议")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Self.darkForegroundPrimary)
                Text("横向拍摄识别效果更好，文字边缘尽量完整并避免强反光。")
                    .font(.caption)
                    .foregroundStyle(Self.darkForegroundSecondary)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.snappy) {
                    showsGuideTip = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Self.darkForegroundSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭拍摄建议")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.blockLarge))
    }

    func controlColumn(
        symbol: String,
        isProminent: Bool,
        isDisabled: Bool,
        isLoading: Bool
    ) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(isProminent ? 0.2 : 0.12))
                .frame(width: isProminent ? 70 : 54, height: isProminent ? 70 : 54)

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: isProminent ? 22 : 17, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(isDisabled ? 0.4 : 0.96))
            }
        }
        .glassEffect(.regular.interactive(), in: .circle)
    }

    var captureButton: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(cameraController.canCapturePhoto ? 0.92 : 0.35), lineWidth: 4)
                .frame(width: 78, height: 78)

            Circle()
                .fill(Color.white.opacity(cameraController.canCapturePhoto ? 0.92 : 0.22))
                .frame(width: 62, height: 62)

            if cameraController.isCapturing {
                ProgressView()
                    .tint(Color.black.opacity(0.78))
            }
        }
    }

    func banner(text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.half) {
            Image(systemName: tint == Color.brand ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(Self.darkForegroundPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.blockLarge))
    }

    private func focusIndicator(state: FocusIndicatorState) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.96), lineWidth: 2.2)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 5.6)
                .blur(radius: 1.4)
                .opacity(state.highlightOpacity)

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.22 * state.highlightOpacity), lineWidth: 1)
                .padding(10)
        }
        .frame(width: 80, height: 80)
        .scaleEffect(state.scale)
        .opacity(state.opacity)
        .shadow(color: Color.white.opacity(0.08 * state.highlightOpacity), radius: 10, x: 0, y: 0)
        .position(state.point)
        .allowsHitTesting(false)
    }

    var cameraBannerText: String? {
        if isLoadingPhotoItem {
            return "正在读取相册图片…"
        }
        guard cameraController.shouldShowFailurePlaceholder else { return nil }
        return cameraController.stateMessage
    }

    func showGuideTipIfNeeded() {
        guard cameraController.isReady, cameraTipDisplayCount < 3 else { return }
        cameraTipDisplayCount += 1
        withAnimation(.smooth) {
            showsGuideTip = true
        }
        let currentToken = UUID()
        guideTipToken = currentToken
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard guideTipToken == currentToken else { return }
            await MainActor.run {
                withAnimation(.smooth) {
                    showsGuideTip = false
                }
            }
        }
    }

    func handleTapToFocus(_ point: CGPoint) {
        focusIndicatorToken = UUID()
        let currentToken = focusIndicatorToken

        focusIndicatorState = FocusIndicatorState(
            point: point,
            scale: 1.16,
            opacity: 0,
            highlightOpacity: 0.2
        )

        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            focusIndicatorState = FocusIndicatorState(
                point: point,
                scale: 1,
                opacity: 1,
                highlightOpacity: 1
            )
        }

        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard focusIndicatorToken == currentToken else { return }
            await MainActor.run {
                withAnimation(.smooth(duration: 0.18)) {
                    focusIndicatorState = FocusIndicatorState(
                        point: point,
                        scale: 1,
                        opacity: 1,
                        highlightOpacity: 0.58
                    )
                }
            }

            try? await Task.sleep(for: .milliseconds(520))
            guard focusIndicatorToken == currentToken else { return }
            await MainActor.run {
                withAnimation(.smooth(duration: 0.2)) {
                    focusIndicatorState = FocusIndicatorState(
                        point: point,
                        scale: 0.96,
                        opacity: 0,
                        highlightOpacity: 0.12
                    )
                }
            }

            try? await Task.sleep(for: .milliseconds(220))
            guard focusIndicatorToken == currentToken else { return }
            await MainActor.run {
                focusIndicatorState = nil
            }
        }
    }

    func capturePhoto() {
        Task {
            do {
                let image = try await cameraController.capturePhoto()
                await MainActor.run {
                    onSelectedImage(image, "拍照")
                }
            } catch {
                await MainActor.run {
                    photoLoadingErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    func consumePhotoItem(_ item: PhotosPickerItem) async {
        isLoadingPhotoItem = true
        defer {
            isLoadingPhotoItem = false
            selectedPhotoItem = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw OCRCameraControllerError.invalidPhotoData
            }
            onSelectedImage(image, "相册")
        } catch {
            photoLoadingErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct OCRCropRecognitionScreen: View {
    private enum InstructionPresentationStyle {
        case automatic
        case manual
    }

    private static let darkForegroundPrimary = Color.white.opacity(0.96)

    @Bindable var viewModel: NotePhotoOCRFlowViewModel
    let onBack: () -> Void
    let onRecognized: (NotePhotoOCRCompletionPayload) -> Void

    @State private var isSelectionInteractionActive = false
    @State private var instructionPresentationID = UUID()
    @State private var instructionPresentationStyle: InstructionPresentationStyle = .automatic

    var body: some View {
        OCRCropRecognitionHost(
            state: OCRCropRecognitionPageState(
                selectedImage: viewModel.selectedImage,
                selectionMode: viewModel.selectionMode,
                singleSelectionRect: viewModel.singleSelectionRect,
                freeformRegions: viewModel.freeformRegions,
                selectedFreeformRegionID: viewModel.selectedFreeformRegionID,
                showsGrid: viewModel.preferences.showsCropGrid,
                isRecognizing: viewModel.isRecognizing,
                canRetake: canPopDuringCrop,
                canClearSelection: canPopDuringCrop && viewModel.hasSelection,
                canRecognize: canPopDuringCrop && viewModel.canRecognize,
                errorMessage: viewModel.errorMessage,
                currentInstructionText: currentInstructionText,
                instructionPresentationID: instructionPresentationID
            ),
            onSingleSelectionChanged: { newValue in
                viewModel.singleSelectionRect = newValue
            },
            onRegionCreated: viewModel.appendFreeformRegion(_:),
            onRegionSelected: { viewModel.selectFreeformRegion(id: $0) },
            onRegionDeleted: viewModel.deleteFreeformRegion(id:),
            onClearErrorMessage: {
                withAnimation(.smooth) {
                    viewModel.errorMessage = nil
                }
            },
            onRetake: handleRetake,
            onClearSelection: clearCurrentSelection,
            onRecognize: recognizeSelection,
            onInteractionStateChanged: handleSelectionInteractionChanged(_:)
        )
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: handleBackAction) {
                    TopBarActionIcon(
                        systemName: "chevron.left",
                        iconSize: 15,
                        weight: .semibold,
                        foregroundColor: Self.darkForegroundPrimary
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canPopDuringCrop)
                .opacity(canPopDuringCrop ? 1 : 0.42)
                .accessibilityLabel("返回")
            }
        }
        .onAppear {
            presentInstruction(.automatic)
        }
        .navigationPopGuard(
            canPop: canPopDuringCrop,
            onBlockedAttempt: { }
        )
        .environment(\.colorScheme, .dark)
    }
}

private extension OCRCropRecognitionScreen {
    var canPopDuringCrop: Bool {
        !isSelectionInteractionActive && !viewModel.isRecognizing
    }

    var currentInstructionText: String? {
        instructionText(for: instructionPresentationStyle)
    }

    private func instructionText(for style: InstructionPresentationStyle) -> String? {
        switch style {
        case .automatic:
            if viewModel.singleSelectionRect == nil {
                return "拖动框住要识别的文字，确认范围后点击“开始识别”。"
            }
            return "拖动边角可微调范围，长按框内可移动位置。"
        case .manual:
            return "适合识别单段或连续正文。拖动创建范围，边角可微调，长按框内可移动位置。"
        }
    }

    private func presentInstruction(_ style: InstructionPresentationStyle) {
        instructionPresentationStyle = style
        instructionPresentationID = UUID()
    }

    func clearCurrentSelection() {
        guard canPopDuringCrop else { return }
        viewModel.clearSingleSelection()
        presentInstruction(.automatic)
    }

    func recognizeSelection() {
        Task {
            guard let payload = await viewModel.recognizeCurrentSelection() else { return }
            await MainActor.run {
                onRecognized(payload)
            }
        }
    }

    func handleBackAction() {
        guard canPopDuringCrop else { return }
        onBack()
    }

    func handleRetake() {
        guard canPopDuringCrop else { return }
        onBack()
    }

    func handleSelectionInteractionChanged(_ isActive: Bool) {
        guard isSelectionInteractionActive != isActive else { return }
        isSelectionInteractionActive = isActive
    }
}

private struct OCRCropRecognitionPageState {
    let selectedImage: UIImage?
    let selectionMode: NotePhotoOCRSelectionMode
    let singleSelectionRect: CGRect?
    let freeformRegions: [NotePhotoOCRSelectionRegion]
    let selectedFreeformRegionID: UUID?
    let showsGrid: Bool
    let isRecognizing: Bool
    let canRetake: Bool
    let canClearSelection: Bool
    let canRecognize: Bool
    let errorMessage: String?
    let currentInstructionText: String?
    let instructionPresentationID: UUID

    var showsEmptyState: Bool {
        selectedImage == nil
    }
}

private struct OCRCropRecognitionHost: UIViewControllerRepresentable {
    let state: OCRCropRecognitionPageState
    let onSingleSelectionChanged: (CGRect?) -> Void
    let onRegionCreated: (CGRect) -> Void
    let onRegionSelected: (UUID?) -> Void
    let onRegionDeleted: (UUID) -> Void
    let onClearErrorMessage: () -> Void
    let onRetake: () -> Void
    let onClearSelection: () -> Void
    let onRecognize: () -> Void
    let onInteractionStateChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> OCRCropRecognitionViewController {
        OCRCropRecognitionViewController()
    }

    func updateUIViewController(_ uiViewController: OCRCropRecognitionViewController, context: Context) {
        uiViewController.apply(
            state: state,
            callbacks: OCRCropRecognitionViewController.Callbacks(
                onSingleSelectionChanged: onSingleSelectionChanged,
                onRegionCreated: onRegionCreated,
                onRegionSelected: onRegionSelected,
                onRegionDeleted: onRegionDeleted,
                onClearErrorMessage: onClearErrorMessage,
                onRetake: onRetake,
                onClearSelection: onClearSelection,
                onRecognize: onRecognize,
                onInteractionStateChanged: onInteractionStateChanged
            )
        )
    }
}

private final class OCRMaterialPanelView: UIVisualEffectView {
    init(
        cornerRadius: CGFloat,
        strokeAlpha: CGFloat = 0.16,
        fillAlpha: CGFloat = 0.08,
        style: UIGlassEffect.Style = .regular
    ) {
        super.init(effect: UIGlassEffect(style: style))
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(strokeAlpha).cgColor
        contentView.backgroundColor = UIColor.black.withAlphaComponent(fillAlpha)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class OCRCropRecognitionViewController: UIViewController {
    struct Callbacks {
        let onSingleSelectionChanged: (CGRect?) -> Void
        let onRegionCreated: (CGRect) -> Void
        let onRegionSelected: (UUID?) -> Void
        let onRegionDeleted: (UUID) -> Void
        let onClearErrorMessage: () -> Void
        let onRetake: () -> Void
        let onClearSelection: () -> Void
        let onRecognize: () -> Void
        let onInteractionStateChanged: (Bool) -> Void
    }

    fileprivate enum BannerContent: Equatable {
        case error(String)
        case instruction(String)
    }

    private var callbacks: Callbacks?
    private var state: OCRCropRecognitionPageState?
    private var isInstructionBannerDismissed = false
    private var displayedBannerContent: BannerContent?
    private var bannerAnimationToken: Int = 0
    private weak var bannerSnapshotView: UIView?

    private let canvasView = OCRSelectionCanvasView()
    private let emptyStateStack = UIStackView()
    private let emptyStateIconView = UIImageView()
    private let emptyStateLabel = UILabel()

    private let bottomStack = UIStackView()
    private let bannerView = OCRMaterialPanelView(
        cornerRadius: 14,
        strokeAlpha: 0.08,
        fillAlpha: 0.03,
        style: .regular
    )
    private let bannerIconView = UIImageView()
    private let bannerLabel = UILabel()
    private let bannerCloseButton = UIButton(type: .system)
    private let bannerCloseIconView = UIImageView()
    private let actionRow = UIStackView()
    private let retakeButton = UIButton(type: .system)
    private let recognizeButton = UIButton(type: .system)
    private let clearSelectionButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureStyles()
        configureActions()
        configureConstraints()
    }

    func apply(state: OCRCropRecognitionPageState, callbacks: Callbacks) {
        let previousState = self.state
        self.state = state
        self.callbacks = callbacks

        canvasView.apply(
            state: state,
            callbacks: .init(
                onSingleSelectionChanged: callbacks.onSingleSelectionChanged,
                onRegionCreated: callbacks.onRegionCreated,
                onRegionSelected: callbacks.onRegionSelected,
                onRegionDeleted: callbacks.onRegionDeleted,
                onInteractionStateChanged: callbacks.onInteractionStateChanged
            )
        )

        if previousState?.instructionPresentationID != state.instructionPresentationID {
            resetInstructionBanner()
        }

        canvasView.isHidden = state.showsEmptyState
        emptyStateStack.isHidden = !state.showsEmptyState

        updateButtons()
        updateBanner(animated: previousState != nil)
    }
}

private extension OCRCropRecognitionViewController {
    func configureHierarchy() {
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)

        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateStack.axis = .vertical
        emptyStateStack.alignment = .center
        emptyStateStack.spacing = Spacing.base
        emptyStateStack.isHidden = true
        emptyStateStack.addArrangedSubview(emptyStateIconView)
        emptyStateStack.addArrangedSubview(emptyStateLabel)
        view.addSubview(emptyStateStack)

        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.axis = .vertical
        bottomStack.alignment = .fill
        bottomStack.spacing = 8
        view.addSubview(bottomStack)

        bannerIconView.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerCloseButton.translatesAutoresizingMaskIntoConstraints = false
        bannerCloseIconView.translatesAutoresizingMaskIntoConstraints = false
        bannerView.contentView.addSubview(bannerIconView)
        bannerView.contentView.addSubview(bannerLabel)
        bannerView.contentView.addSubview(bannerCloseButton)
        bannerCloseButton.addSubview(bannerCloseIconView)
        bannerView.isHidden = true
        bottomStack.addArrangedSubview(bannerView)

        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.distribution = .equalCentering
        actionRow.spacing = 14
        retakeButton.translatesAutoresizingMaskIntoConstraints = false
        recognizeButton.translatesAutoresizingMaskIntoConstraints = false
        clearSelectionButton.translatesAutoresizingMaskIntoConstraints = false

        actionRow.addArrangedSubview(retakeButton)
        actionRow.addArrangedSubview(recognizeButton)
        actionRow.addArrangedSubview(clearSelectionButton)
        bottomStack.addArrangedSubview(actionRow)
    }

    func configureStyles() {
        emptyStateIconView.image = UIImage(systemName: "photo")
        emptyStateIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        emptyStateIconView.tintColor = UIColor(Color.brand).withAlphaComponent(0.3)
        emptyStateLabel.text = "没有可裁切的图片，请返回上一步重新选择。"
        emptyStateLabel.textColor = UIColor(Color.textSecondary)
        emptyStateLabel.font = .preferredFont(forTextStyle: .title3)
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center

        bannerIconView.contentMode = .scaleAspectFit
        bannerLabel.font = .preferredFont(forTextStyle: .footnote)
        bannerLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        bannerLabel.numberOfLines = 0
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bannerCloseButton.tintColor = .clear
        bannerCloseButton.backgroundColor = .clear
        bannerCloseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        bannerCloseButton.setContentHuggingPriority(.required, for: .horizontal)
        bannerCloseButton.accessibilityLabel = "关闭提示"

        bannerCloseIconView.isUserInteractionEnabled = false
        bannerCloseIconView.contentMode = .scaleAspectFit
        bannerCloseIconView.image = UIImage(systemName: "xmark")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        bannerCloseIconView.tintColor = UIColor.white.withAlphaComponent(0.7)

        bannerCloseButton.configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            let isHighlighted = button.state.contains(.highlighted)
            self.bannerCloseIconView.tintColor = UIColor.white.withAlphaComponent(isHighlighted ? 0.92 : 0.7)
            self.bannerCloseButton.transform = isHighlighted
                ? CGAffineTransform(scaleX: 0.94, y: 0.94)
                : .identity
        }

        recognizeButton.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        recognizeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        recognizeButton.contentHorizontalAlignment = .center

        retakeButton.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        retakeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        clearSelectionButton.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
        clearSelectionButton.titleLabel?.adjustsFontForContentSizeCategory = true
    }

    func configureActions() {
        retakeButton.addAction(UIAction { [weak self] _ in
            self?.callbacks?.onRetake()
        }, for: .touchUpInside)

        clearSelectionButton.addAction(UIAction { [weak self] _ in
            self?.callbacks?.onClearSelection()
        }, for: .touchUpInside)

        recognizeButton.addAction(UIAction { [weak self] _ in
            self?.callbacks?.onRecognize()
        }, for: .touchUpInside)

        bannerCloseButton.addAction(UIAction { [weak self] _ in
            self?.dismissCurrentBanner()
        }, for: .touchUpInside)
    }

    func configureConstraints() {
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: Spacing.half),
            canvasView.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -Spacing.half),

            emptyStateStack.centerXAnchor.constraint(equalTo: canvasView.centerXAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: canvasView.centerYAnchor),
            emptyStateStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Spacing.double),
            emptyStateStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Spacing.double),

            bottomStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.screenEdge),
            bottomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.screenEdge),
            bottomStack.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -8),

            bannerIconView.leadingAnchor.constraint(equalTo: bannerView.contentView.leadingAnchor, constant: 12),
            bannerIconView.widthAnchor.constraint(equalToConstant: 16),
            bannerIconView.heightAnchor.constraint(equalToConstant: 16),

            bannerLabel.leadingAnchor.constraint(equalTo: bannerIconView.trailingAnchor, constant: Spacing.half),
            bannerLabel.topAnchor.constraint(equalTo: bannerView.contentView.topAnchor, constant: 9),
            bannerLabel.bottomAnchor.constraint(equalTo: bannerView.contentView.bottomAnchor, constant: -9),

            bannerCloseButton.leadingAnchor.constraint(equalTo: bannerLabel.trailingAnchor, constant: 6),
            bannerCloseButton.trailingAnchor.constraint(equalTo: bannerView.contentView.trailingAnchor, constant: -2),
            bannerCloseButton.centerYAnchor.constraint(equalTo: bannerView.contentView.centerYAnchor),
            bannerCloseButton.widthAnchor.constraint(equalToConstant: 44),
            bannerCloseButton.heightAnchor.constraint(equalToConstant: 44),

            bannerIconView.centerYAnchor.constraint(equalTo: bannerView.contentView.centerYAnchor),
            bannerCloseIconView.centerXAnchor.constraint(equalTo: bannerCloseButton.centerXAnchor),
            bannerCloseIconView.centerYAnchor.constraint(equalTo: bannerCloseButton.centerYAnchor),
            bannerCloseIconView.widthAnchor.constraint(equalToConstant: 12),
            bannerCloseIconView.heightAnchor.constraint(equalToConstant: 12),

            actionRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),

            retakeButton.widthAnchor.constraint(equalToConstant: 50),
            retakeButton.heightAnchor.constraint(equalToConstant: 50),
            clearSelectionButton.widthAnchor.constraint(equalToConstant: 50),
            clearSelectionButton.heightAnchor.constraint(equalToConstant: 50),
            recognizeButton.heightAnchor.constraint(equalToConstant: 50),
            recognizeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 136)
        ])
    }

    func updateButtons() {
        guard let state else { return }

        retakeButton.configuration = sideButtonConfiguration(
            systemImage: "camera",
            isEnabled: state.canRetake
        )
        retakeButton.isEnabled = state.canRetake
        retakeButton.accessibilityLabel = "重新拍摄"

        clearSelectionButton.configuration = sideButtonConfiguration(
            systemImage: "arrow.uturn.backward",
            isEnabled: state.canClearSelection
        )
        clearSelectionButton.isEnabled = state.canClearSelection
        clearSelectionButton.accessibilityLabel = "清空选框"

        var configuration = state.canRecognize || state.isRecognizing
            ? UIButton.Configuration.prominentGlass()
            : UIButton.Configuration.clearGlass()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = state.canRecognize || state.isRecognizing
            ? UIColor.white.withAlphaComponent(0.22)
            : UIColor.white.withAlphaComponent(0.05)
        configuration.baseForegroundColor = UIColor.white.withAlphaComponent(state.canRecognize || state.isRecognizing ? 0.98 : 0.42)
        configuration.image = nil
        configuration.title = state.isRecognizing ? "识别中" : "开始识别"
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22)
        configuration.background.backgroundColor = state.canRecognize || state.isRecognizing
            ? UIColor.white.withAlphaComponent(0.2)
            : UIColor.white.withAlphaComponent(0.06)
        configuration.showsActivityIndicator = state.isRecognizing
        configuration.imagePadding = 8
        configuration.activityIndicatorColorTransformer = UIConfigurationColorTransformer { _ in
            UIColor.white.withAlphaComponent(0.92)
        }
        recognizeButton.configuration = configuration
        recognizeButton.isEnabled = state.canRecognize
        recognizeButton.accessibilityLabel = state.isRecognizing ? "识别中" : "开始识别"
    }

    func sideButtonConfiguration(
        systemImage: String,
        isEnabled: Bool
    ) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.clearGlass()
        configuration.cornerStyle = .capsule
        configuration.title = nil
        configuration.image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        configuration.baseForegroundColor = UIColor.white.withAlphaComponent(isEnabled ? 0.9 : 0.4)
        configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(isEnabled ? 0.1 : 0.03)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        configuration.background.backgroundColor = UIColor.white.withAlphaComponent(isEnabled ? 0.08 : 0.03)
        configuration.buttonSize = .large
        configuration.imagePadding = 0
        if #available(iOS 26.0, *) {
            configuration.background.cornerRadius = 25
        }
        return configuration
    }

    func updateBanner(animated: Bool = true) {
        let content = currentBannerContent()
        let previousContent = displayedBannerContent

        guard previousContent != content else { return }
        displayedBannerContent = content

        let shouldAnimate = animated && !UIAccessibility.isReduceMotionEnabled
        guard shouldAnimate else {
            applyBannerContent(content)
            return
        }

        switch (previousContent, content) {
        case (nil, nil):
            return
        case (nil, .some(let nextContent)):
            animateShowBanner(nextContent)
        case (.some, nil):
            animateHideBanner()
        case (.some, .some(let nextContent)):
            animateReplaceBannerContent(nextContent)
        }
    }

    func currentBannerContent() -> BannerContent? {
        guard let state else { return nil }
        if let errorMessage = state.errorMessage {
            return .error(errorMessage)
        }
        if !isInstructionBannerDismissed, let instructionText = state.currentInstructionText {
            return .instruction(instructionText)
        }
        return nil
    }

    func resetInstructionBanner() {
        isInstructionBannerDismissed = false
        updateBanner(animated: true)
    }

    func dismissCurrentBanner() {
        guard let state else { return }
        if state.errorMessage != nil {
            callbacks?.onClearErrorMessage()
            return
        }

        isInstructionBannerDismissed = true
        updateBanner(animated: true)
    }

    func applyBannerContent(_ content: BannerContent?) {
        stopBannerAnimations()
        guard let content else {
            bannerView.alpha = 1
            bannerView.transform = .identity
            bannerView.isHidden = true
            return
        }
        configureBanner(content)
        bannerView.alpha = 1
        bannerView.transform = .identity
        bannerView.isHidden = false
    }

    func configureBanner(_ content: BannerContent) {
        switch content {
        case .error(let text):
            bannerIconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
            bannerIconView.tintColor = UIColor(Color.feedbackWarning)
            bannerLabel.text = text
        case .instruction(let text):
            bannerIconView.image = UIImage(systemName: "hand.draw")
            bannerIconView.tintColor = UIColor.white.withAlphaComponent(0.74)
            bannerLabel.text = text
        }
    }

    func animateShowBanner(_ content: BannerContent) {
        stopBannerAnimations()
        view.layoutIfNeeded()
        configureBanner(content)
        bannerView.alpha = 0
        bannerView.transform = CGAffineTransform(translationX: 0, y: 6)
        bannerView.isHidden = false
        let token = nextBannerAnimationToken()
        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) { [weak self] in
            guard let self else { return }
            self.bannerView.alpha = 1
            self.bannerView.transform = .identity
            self.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self else { return }
            guard self.bannerAnimationToken == token else { return }
            self.bannerView.alpha = 1
            self.bannerView.transform = .identity
        }
    }

    func animateHideBanner() {
        guard !bannerView.isHidden else { return }
        stopBannerAnimations()
        view.layoutIfNeeded()
        let token = nextBannerAnimationToken()
        let snapshot = bannerView.snapshotView(afterScreenUpdates: false)
        if let snapshot {
            snapshot.frame = bannerView.convert(bannerView.bounds, to: view)
            snapshot.isUserInteractionEnabled = false
            view.addSubview(snapshot)
            bannerSnapshotView = snapshot
        }
        bannerView.alpha = 1
        bannerView.transform = .identity
        bannerView.isHidden = true
        UIView.animate(
            withDuration: 0.24,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) { [weak self] in
            guard let self else { return }
            snapshot?.alpha = 0
            snapshot?.transform = CGAffineTransform(translationX: 0, y: 6)
            self.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self else { return }
            snapshot?.removeFromSuperview()
            guard self.bannerAnimationToken == token else { return }
            self.bannerSnapshotView = nil
            self.bannerView.alpha = 1
            self.bannerView.transform = .identity
        }
    }

    func animateReplaceBannerContent(_ content: BannerContent) {
        guard !bannerView.isHidden else {
            applyBannerContent(content)
            return
        }
        stopBannerAnimations()
        let token = nextBannerAnimationToken()
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) { [weak self] in
            guard let self else { return }
            self.bannerView.alpha = 0
            self.bannerView.transform = CGAffineTransform(translationX: 0, y: 6)
        } completion: { [weak self] _ in
            guard let self else { return }
            guard self.bannerAnimationToken == token else { return }
            self.configureBanner(content)
            self.bannerView.alpha = 0
            self.bannerView.transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
            ) { [weak self] in
                guard let self else { return }
                self.bannerView.alpha = 1
                self.bannerView.transform = .identity
                self.view.layoutIfNeeded()
            } completion: { [weak self] _ in
                guard let self else { return }
                guard self.bannerAnimationToken == token else { return }
                self.bannerView.alpha = 1
                self.bannerView.transform = .identity
            }
        }
    }

    func stopBannerAnimations() {
        bannerView.layer.removeAllAnimations()
        if let snapshot = bannerSnapshotView {
            snapshot.layer.removeAllAnimations()
            snapshot.removeFromSuperview()
            bannerSnapshotView = nil
        }
    }

    func nextBannerAnimationToken() -> Int {
        bannerAnimationToken += 1
        return bannerAnimationToken
    }
}

private struct OCRSelectionOverlayRegionState: Equatable {
    let id: UUID
    let frame: CGRect
    let deleteButtonFrame: CGRect?
}

private struct OCRSelectionOverlayState: Equatable {
    let imageFrame: CGRect
    let selectionMode: NotePhotoOCRSelectionMode
    let singleFrame: CGRect?
    let freeformRegions: [OCRSelectionOverlayRegionState]
    let selectedFreeformRegionID: UUID?
    let draftFreeformRect: CGRect?
    let showsGrid: Bool
    let showsCropMask: Bool
    let showsDeleteButtons: Bool
    let shouldShowSingleHandles: Bool
    let singleHandleCenters: [CGPoint]
}

private enum OCRSelectionGeometry {
    static let minimumRecognitionPixelSize: CGFloat = 2
    static let deleteButtonSize: CGFloat = 28
    static let deleteButtonInset: CGFloat = 6
    static let externalDeleteButtonSpacing: CGFloat = 8
    static let handleVisibleMinimumDimension: CGFloat = 28

    static func deleteButtonFrame(for regionFrame: CGRect, imageFrame: CGRect) -> CGRect {
        let preferredInsideFrame = CGRect(
            x: regionFrame.maxX - deleteButtonSize - deleteButtonInset,
            y: regionFrame.minY + deleteButtonInset,
            width: deleteButtonSize,
            height: deleteButtonSize
        )

        let requiresExternalPlacement =
            regionFrame.width < deleteButtonSize + deleteButtonInset * 2
            || regionFrame.height < deleteButtonSize + deleteButtonInset * 2

        let resolvedFrame: CGRect
        if requiresExternalPlacement {
            let preferredExternalFrame = CGRect(
                x: regionFrame.maxX + externalDeleteButtonSpacing,
                y: regionFrame.minY - deleteButtonSize - externalDeleteButtonSpacing,
                width: deleteButtonSize,
                height: deleteButtonSize
            )

            resolvedFrame = preferredExternalFrame.translatedToFit(in: imageFrame)
        } else {
            resolvedFrame = preferredInsideFrame.translatedToFit(in: imageFrame)
        }

        return resolvedFrame
    }

    static func handleRect(center: CGPoint) -> CGRect {
        CGRect(
            x: center.x - 7,
            y: center.y - 7,
            width: 14,
            height: 14
        )
    }
}

private final class OCRSelectionOverlayView: UIView {
    var state: OCRSelectionOverlayState? {
        didSet {
            guard state != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let state else {
            return
        }

        context.clear(bounds)
        drawScene(in: context, state: state)
    }
}

private extension OCRSelectionOverlayView {
    var selectionCornerRadius: CGFloat {
        CornerRadius.inlaySmall
    }

    func drawScene(in context: CGContext, state: OCRSelectionOverlayState) {
        switch state.selectionMode {
        case .single:
            guard let cropFrame = state.singleFrame,
                  cropFrame.width > 0,
                  cropFrame.height > 0 else {
                return
            }

            if state.showsCropMask {
                drawCropMask(in: context, imageFrame: state.imageFrame, cropFrame: cropFrame)
            }

            let fillPath = UIBezierPath(
                roundedRect: cropFrame,
                cornerRadius: selectionCornerRadius
            )
            UIColor.white.withAlphaComponent(0.06).setFill()
            fillPath.fill()

            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: 4),
                blur: 10,
                color: UIColor.black.withAlphaComponent(0.18).cgColor
            )
            let strokePath = UIBezierPath(
                roundedRect: cropFrame,
                cornerRadius: selectionCornerRadius
            )
            strokePath.lineWidth = 1.5
            UIColor.white.withAlphaComponent(0.96).setStroke()
            strokePath.stroke()
            context.restoreGState()

            if state.showsGrid {
                drawCropGrid(in: context, cropFrame: cropFrame)
            }

            if state.shouldShowSingleHandles {
                drawHandles(in: context, centers: state.singleHandleCenters)
            }
        case .freeform:
            for region in state.freeformRegions {
                drawFreeformRegion(
                    in: context,
                    region: region,
                    selectedRegionID: state.selectedFreeformRegionID,
                    showsDeleteButtons: state.showsDeleteButtons
                )
            }

            if let draftRect = state.draftFreeformRect {
                let path = UIBezierPath(
                    roundedRect: draftRect,
                    cornerRadius: selectionCornerRadius
                )
                UIColor(Color.brand).withAlphaComponent(0.10).setFill()
                path.fill()

                UIColor(Color.brand).withAlphaComponent(0.94).setStroke()
                path.setLineDash([4, 4], count: 2, phase: 0)
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    func drawFreeformRegion(
        in context: CGContext,
        region: OCRSelectionOverlayRegionState,
        selectedRegionID: UUID?,
        showsDeleteButtons: Bool
    ) {
        let isSelected = region.id == selectedRegionID
        let path = UIBezierPath(
            roundedRect: region.frame,
            cornerRadius: selectionCornerRadius
        )
        (isSelected ? UIColor(Color.brand).withAlphaComponent(0.14) : UIColor.white.withAlphaComponent(0.08)).setFill()
        path.fill()

        (isSelected ? UIColor(Color.brand).withAlphaComponent(0.94) : UIColor.white.withAlphaComponent(0.82)).setStroke()
        path.lineWidth = isSelected ? 1.5 : 1
        path.stroke()

        if showsDeleteButtons,
           isSelected,
           let deleteButtonFrame = region.deleteButtonFrame {
            drawDeleteButton(in: context, buttonFrame: deleteButtonFrame)
        }
    }

    func drawDeleteButton(in context: CGContext, buttonFrame: CGRect) {
        let path = UIBezierPath(ovalIn: buttonFrame)
        UIColor.black.withAlphaComponent(0.34).setFill()
        path.fill()
        UIColor.white.withAlphaComponent(0.2).setStroke()
        path.lineWidth = 1
        path.stroke()

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let icon = UIImage(systemName: "trash", withConfiguration: iconConfig)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        icon?.draw(in: buttonFrame.insetBy(dx: 7, dy: 7))
    }

    func drawCropMask(in context: CGContext, imageFrame: CGRect, cropFrame: CGRect) {
        let cornerRadius = max(
            0,
            min(
                selectionCornerRadius,
                min(cropFrame.width, cropFrame.height) / 2
            )
        )
        let maskPath = UIBezierPath(rect: imageFrame)
        maskPath.append(UIBezierPath(roundedRect: cropFrame, cornerRadius: cornerRadius))
        maskPath.usesEvenOddFillRule = true

        context.saveGState()
        context.setFillColor(UIColor.black.withAlphaComponent(0.42).cgColor)
        context.addPath(maskPath.cgPath)
        context.drawPath(using: .eoFill)
        context.restoreGState()
    }

    func drawCropGrid(in context: CGContext, cropFrame: CGRect) {
        context.saveGState()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.68).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])

        for ratio in [1.0 / 3.0, 2.0 / 3.0] {
            let x = cropFrame.minX + cropFrame.width * ratio
            context.move(to: CGPoint(x: x, y: cropFrame.minY))
            context.addLine(to: CGPoint(x: x, y: cropFrame.maxY))
            context.strokePath()

            let y = cropFrame.minY + cropFrame.height * ratio
            context.move(to: CGPoint(x: cropFrame.minX, y: y))
            context.addLine(to: CGPoint(x: cropFrame.maxX, y: y))
            context.strokePath()
        }

        context.restoreGState()
    }

    func drawHandles(in context: CGContext, centers: [CGPoint]) {
        for center in centers {
            let handleRect = OCRSelectionGeometry.handleRect(center: center)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.24).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: handleRect).fill()
            context.restoreGState()
        }
    }
}

private final class OCRLoupeView: UIView {
    private let imageView = UIImageView()
    private let innerRingLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.24)
        clipsToBounds = true
        layer.cornerCurve = .continuous

        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = false
        addSubview(imageView)

        innerRingLayer.fillColor = UIColor.clear.cgColor
        innerRingLayer.strokeColor = UIColor.white.withAlphaComponent(0.24).cgColor
        innerRingLayer.lineWidth = 0.8
        layer.addSublayer(innerRingLayer)

        crosshairLayer.fillColor = UIColor.clear.cgColor
        crosshairLayer.strokeColor = UIColor.white.withAlphaComponent(0.82).cgColor
        crosshairLayer.lineWidth = 1
        layer.addSublayer(crosshairLayer)

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.white.withAlphaComponent(0.94).cgColor
        borderLayer.lineWidth = 1.5
        layer.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        layer.cornerRadius = bounds.width / 2

        let outerCircle = UIBezierPath(ovalIn: bounds).cgPath
        borderLayer.path = outerCircle
        innerRingLayer.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 14, dy: 14)).cgPath

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let crosshair = UIBezierPath()
        crosshair.move(to: CGPoint(x: center.x - 10, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 10, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 10))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 10))
        crosshairLayer.path = crosshair.cgPath
    }

    func apply(
        image: UIImage,
        imageFrame: CGRect,
        loupeState: OCRSelectionCanvasView.LoupeState,
        magnification: CGFloat
    ) {
        isHidden = false
        imageView.image = image
        let samplePoint = CGPoint(
            x: imageFrame.minX + imageFrame.width * loupeState.normalizedSamplePoint.x,
            y: imageFrame.minY + imageFrame.height * loupeState.normalizedSamplePoint.y
        )
        imageView.frame = CGRect(
            x: bounds.midX - (samplePoint.x - imageFrame.minX) * magnification,
            y: bounds.midY - (samplePoint.y - imageFrame.minY) * magnification,
            width: imageFrame.width * magnification,
            height: imageFrame.height * magnification
        )
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        imageView.image = nil
    }
}

private final class OCRSelectionCanvasView: UIView {
    struct Callbacks {
        let onSingleSelectionChanged: (CGRect?) -> Void
        let onRegionCreated: (CGRect) -> Void
        let onRegionSelected: (UUID?) -> Void
        let onRegionDeleted: (UUID) -> Void
        let onInteractionStateChanged: (Bool) -> Void
    }

    fileprivate enum Handle: CaseIterable {
        case topLeft
        case topCenter
        case topRight
        case middleLeft
        case middleRight
        case bottomLeft
        case bottomCenter
        case bottomRight
    }

    fileprivate enum LoupeSide: Equatable {
        case leading
        case trailing
    }

    fileprivate enum LoupeUpdateSource: Equatable {
        case singleDrawing
        case singlePendingOutsideRedraw
        case singlePendingMoveOrRedraw
        case singleMoving
        case singleResizing(handle: Handle)
        case freeformStart
        case freeformDrag
    }

    fileprivate enum SingleInteractionState {
        case idle
        case drawing(anchor: CGPoint)
        case pendingOutsideRedraw(anchor: CGPoint)
        case pendingMoveOrRedraw(origin: CGPoint, baseRect: CGRect, beganAt: Date)
        case moving(origin: CGPoint, baseRect: CGRect)
        case resizing(handle: Handle, baseRect: CGRect)
    }

    fileprivate struct TouchSample {
        let rawLocation: CGPoint
        let preciseLocation: CGPoint
        let majorRadius: CGFloat
        let type: UITouch.TouchType
    }

    fileprivate struct LoupeState {
        let normalizedSamplePoint: CGPoint
        let source: LoupeUpdateSource
        let side: LoupeSide
    }

    private struct PendingTouchUpdate {
        let sample: TouchSample
        let location: CGPoint
    }

    private var callbacks: Callbacks?
    private var image: UIImage?
    private var selectionMode: NotePhotoOCRSelectionMode = .single
    private var singleSelectionRect: CGRect?
    private var freeformRegions: [NotePhotoOCRSelectionRegion] = []
    private var selectedFreeformRegionID: UUID?
    private var showsGrid = true

    private var singleInteractionState: SingleInteractionState = .idle
    private var isInteractionActive = false
    private var activeTouchIdentifier: ObjectIdentifier?
    private var activeTouchStartPoint: CGPoint?
    private var freeformStartPoint: CGPoint?
    private var freeformCurrentPoint: CGPoint?
    private var hitRegionID: UUID?
    private var workingSingleSelectionRect: CGRect?
    private var localSelectedFreeformRegionID: UUID?
    private var loupeState: LoupeState?
    private var pendingTouchUpdate: PendingTouchUpdate?
    private var displayLink: CADisplayLink?

    private let imageView = UIImageView()
    private let overlayView = OCRSelectionOverlayView()
    private let loupeView = OCRLoupeView()

    private let touchSlop: CGFloat = 6
    private let moveActivationDelay: TimeInterval = 0.2
    private let handleHitDiameter: CGFloat = 56
    private let loupeDiameter: CGFloat = 110
    private let loupeMagnification: CGFloat = 3
    private let loupeTopPadding: CGFloat = 12
    private let loupeHorizontalPadding: CGFloat = 12
    private let loupeCollisionPadding: CGFloat = 8
    private var imagePixelSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        isMultipleTouchEnabled = false
        clipsToBounds = true

        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleToFill
        addSubview(imageView)

        overlayView.isUserInteractionEnabled = false
        addSubview(overlayView)

        addSubview(loupeView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopDisplayLink()
    }

    func apply(state: OCRCropRecognitionPageState, callbacks: Callbacks) {
        let previousMode = selectionMode
        let previousImage = image
        let shouldResetInteraction = previousMode != state.selectionMode || previousImage !== state.selectedImage

        self.callbacks = callbacks
        image = state.selectedImage
        imagePixelSize = Self.pixelSize(for: state.selectedImage)
        selectionMode = state.selectionMode
        showsGrid = state.showsGrid

        if shouldResetInteraction {
            singleSelectionRect = state.singleSelectionRect
            freeformRegions = state.freeformRegions
            selectedFreeformRegionID = state.selectedFreeformRegionID
            localSelectedFreeformRegionID = state.selectedFreeformRegionID
            resetAllInteractionState()
        } else if !isInteractionActive {
            singleSelectionRect = state.singleSelectionRect
            freeformRegions = state.freeformRegions
            selectedFreeformRegionID = state.selectedFreeformRegionID
            localSelectedFreeformRegionID = state.selectedFreeformRegionID
        }

        renderScene()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderScene()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouchIdentifier == nil,
              let touch = touches.first,
              let image else {
            return
        }

        let imageFrame = fittedImageFrame(in: bounds.size, imageSize: image.size)
        let sample = touchSample(from: touch)
        let point = sample.preciseLocation.clamped(to: imageFrame)

        guard imageFrame.contains(point) else {
            return
        }

        if selectionMode == .freeform,
           let deleteRegionID = deleteButtonRegionID(at: point, in: imageFrame) {
            freeformRegions.removeAll { $0.id == deleteRegionID }
            if localSelectedFreeformRegionID == deleteRegionID || selectedFreeformRegionID == deleteRegionID {
                localSelectedFreeformRegionID = nil
                selectedFreeformRegionID = nil
            }
            callbacks?.onRegionDeleted(deleteRegionID)
            renderScene()
            return
        }

        activeTouchIdentifier = ObjectIdentifier(touch)
        activeTouchStartPoint = point
        pendingTouchUpdate = nil
        beginInteraction()

        switch selectionMode {
        case .single:
            singleInteractionState = initialSingleInteractionState(at: point, in: imageFrame)
            handleSingleTouchMoved(sample: sample, location: point, imageFrame: imageFrame)
        case .freeform:
            updateLoupe(with: sample, in: imageFrame, source: .freeformStart)
            if let region = region(containing: point, in: imageFrame) {
                hitRegionID = region.id
                localSelectedFreeformRegionID = region.id
                selectedFreeformRegionID = region.id
                callbacks?.onRegionSelected(region.id)
            } else {
                localSelectedFreeformRegionID = nil
                selectedFreeformRegionID = nil
                callbacks?.onRegionSelected(nil)
                freeformStartPoint = point
                freeformCurrentPoint = point
            }
            renderScene()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              activeTouchIdentifier == ObjectIdentifier(touch),
              let image else {
            return
        }

        let imageFrame = fittedImageFrame(in: bounds.size, imageSize: image.size)
        let sample = touchSample(from: touch)
        let point = sample.preciseLocation.clamped(to: imageFrame)
        pendingTouchUpdate = PendingTouchUpdate(sample: sample, location: point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              activeTouchIdentifier == ObjectIdentifier(touch),
              let image else {
            return
        }

        flushPendingTouchUpdate()

        let imageFrame = fittedImageFrame(in: bounds.size, imageSize: image.size)
        let point = touchSample(from: touch).preciseLocation.clamped(to: imageFrame)

        switch selectionMode {
        case .single:
            finishSingleTouch(at: point, in: imageFrame)
        case .freeform:
            finishFreeformTouch(at: point, in: imageFrame)
        }

        activeTouchIdentifier = nil
        activeTouchStartPoint = nil
        pendingTouchUpdate = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pendingTouchUpdate = nil
        resetAllInteractionState()
        activeTouchIdentifier = nil
        activeTouchStartPoint = nil
    }
}

private extension OCRSelectionCanvasView {
    var effectiveSingleSelectionRect: CGRect? {
        workingSingleSelectionRect ?? singleSelectionRect
    }

    var effectiveSelectedFreeformRegionID: UUID? {
        localSelectedFreeformRegionID ?? selectedFreeformRegionID
    }

    var shouldShowSingleHandles: Bool {
        guard effectiveSingleSelectionRect != nil else { return false }
        if case .idle = singleInteractionState {
            return true
        }
        return false
    }

    func touchSample(from touch: UITouch) -> TouchSample {
        TouchSample(
            rawLocation: touch.location(in: self),
            preciseLocation: touch.preciseLocation(in: self),
            majorRadius: max(touch.majorRadius, 0),
            type: touch.type
        )
    }

    func beginInteraction() {
        guard !isInteractionActive else { return }
        isInteractionActive = true
        startDisplayLink()
        callbacks?.onInteractionStateChanged(true)
    }

    func endInteraction() {
        hideLoupe()
        stopDisplayLink()
        guard isInteractionActive else { return }
        isInteractionActive = false
        callbacks?.onInteractionStateChanged(false)
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLinkTick))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    func handleDisplayLinkTick() {
        flushPendingTouchUpdate()
    }

    func flushPendingTouchUpdate() {
        guard let pendingTouchUpdate,
              let image else {
            return
        }

        self.pendingTouchUpdate = nil
        let imageFrame = fittedImageFrame(in: bounds.size, imageSize: image.size)

        switch selectionMode {
        case .single:
            handleSingleTouchMoved(
                sample: pendingTouchUpdate.sample,
                location: pendingTouchUpdate.location,
                imageFrame: imageFrame
            )
        case .freeform:
            handleFreeformTouchMoved(
                sample: pendingTouchUpdate.sample,
                location: pendingTouchUpdate.location,
                imageFrame: imageFrame
            )
        }
    }

    func resetAllInteractionState() {
        pendingTouchUpdate = nil
        singleInteractionState = .idle
        workingSingleSelectionRect = nil
        freeformStartPoint = nil
        freeformCurrentPoint = nil
        hitRegionID = nil
        localSelectedFreeformRegionID = selectedFreeformRegionID
        endInteraction()
        renderScene()
    }

    func renderScene() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        backgroundColor = .black
        guard let image else {
            imageView.image = nil
            imageView.isHidden = true
            overlayView.isHidden = true
            loupeView.hide()
            return
        }

        let imageFrame = fittedImageFrame(in: bounds.size, imageSize: image.size)
        guard imageFrame.width > 0, imageFrame.height > 0 else {
            imageView.image = nil
            imageView.isHidden = true
            overlayView.isHidden = true
            loupeView.hide()
            return
        }

        imageView.isHidden = false
        imageView.image = image
        imageView.frame = imageFrame

        overlayView.isHidden = false
        overlayView.frame = bounds
        overlayView.state = makeOverlayState(
            imageFrame: imageFrame,
            showsCropMask: true,
            showsDeleteButtons: true,
            includeHandles: true
        )

        guard let loupeState else {
            loupeView.hide()
            return
        }

        let loupeFrame = loupeFrame(in: bounds.size, side: loupeState.side)
        loupeView.frame = loupeFrame
        loupeView.apply(
            image: image,
            imageFrame: imageFrame,
            loupeState: loupeState,
            magnification: loupeMagnification
        )
    }

    func makeOverlayState(
        imageFrame: CGRect,
        showsCropMask: Bool,
        showsDeleteButtons: Bool,
        includeHandles: Bool
    ) -> OCRSelectionOverlayState {
        let singleFrame = currentSingleFrame(in: imageFrame)
        return OCRSelectionOverlayState(
            imageFrame: imageFrame,
            selectionMode: selectionMode,
            singleFrame: singleFrame,
            freeformRegions: freeformRegions.map { region in
                let regionFrame = frame(for: region.normalizedRect, in: imageFrame)
                return OCRSelectionOverlayRegionState(
                    id: region.id,
                    frame: regionFrame,
                    deleteButtonFrame: region.id == effectiveSelectedFreeformRegionID && showsDeleteButtons
                        ? deleteButtonFrame(for: regionFrame, imageFrame: imageFrame)
                        : nil
                )
            },
            selectedFreeformRegionID: effectiveSelectedFreeformRegionID,
            draftFreeformRect: draftFreeformRect(in: imageFrame),
            showsGrid: showsGrid,
            showsCropMask: showsCropMask,
            showsDeleteButtons: showsDeleteButtons,
            shouldShowSingleHandles: includeHandles && shouldShowSingleHandles && shouldDisplaySingleHandles(in: singleFrame),
            singleHandleCenters: includeHandles ? handleCenters(in: singleFrame) : []
        )
    }

    func handleCenters(in cropFrame: CGRect?) -> [CGPoint] {
        guard let cropFrame else { return [] }
        return Handle.allCases.map { position(for: $0, in: cropFrame) }
    }

    func handleSingleTouchMoved(sample: TouchSample, location: CGPoint, imageFrame: CGRect) {
        switch singleInteractionState {
        case .idle:
            break
        case .drawing(let anchor):
            workingSingleSelectionRect = normalizedRect(from: anchor, to: location, in: imageFrame)
            updateLoupe(with: sample, in: imageFrame, source: .singleDrawing)
        case .pendingOutsideRedraw(let anchor):
            updateLoupe(with: sample, in: imageFrame, source: .singlePendingOutsideRedraw)
            guard distance(between: anchor, and: location) >= touchSlop else {
                renderScene()
                return
            }

            singleInteractionState = .drawing(anchor: anchor)
            workingSingleSelectionRect = normalizedRect(from: anchor, to: location, in: imageFrame)
        case .pendingMoveOrRedraw(let origin, let baseRect, let beganAt):
            updateLoupe(with: sample, in: imageFrame, source: .singlePendingMoveOrRedraw)
            guard distance(between: origin, and: location) >= touchSlop else {
                renderScene()
                return
            }

            if Date().timeIntervalSince(beganAt) >= moveActivationDelay {
                singleInteractionState = .moving(origin: origin, baseRect: baseRect)
                workingSingleSelectionRect = translatedRect(
                    from: baseRect,
                    startPoint: origin,
                    currentPoint: location,
                    in: imageFrame
                )
            } else {
                singleInteractionState = .drawing(anchor: location)
                workingSingleSelectionRect = normalizedRect(from: location, to: location, in: imageFrame)
            }
        case .moving(let origin, let baseRect):
            workingSingleSelectionRect = translatedRect(
                from: baseRect,
                startPoint: origin,
                currentPoint: location,
                in: imageFrame
            )
            updateLoupe(with: sample, in: imageFrame, source: .singleMoving)
        case .resizing(let handle, let baseRect):
            let nextRect = resizedRect(from: baseRect, handle: handle, location: location, in: imageFrame)
            workingSingleSelectionRect = nextRect

            let resizedFrame = frame(for: nextRect, in: imageFrame)
            updateLoupe(
                with: sample,
                in: imageFrame,
                source: .singleResizing(handle: handle),
                anchorOverride: position(for: handle, in: resizedFrame)
            )
        }

        renderScene()
    }

    func finishSingleTouch(at location: CGPoint, in imageFrame: CGRect) {
        defer {
            singleInteractionState = .idle
            workingSingleSelectionRect = nil
            endInteraction()
            renderScene()
        }

        switch singleInteractionState {
        case .idle, .pendingOutsideRedraw, .pendingMoveOrRedraw:
            return
        case .drawing(let anchor):
            let draftFrame = CGRect(
                x: min(anchor.x, location.x),
                y: min(anchor.y, location.y),
                width: abs(location.x - anchor.x),
                height: abs(location.y - anchor.y)
            )

            let normalized = normalizedRect(from: draftFrame, in: imageFrame).clampedToUnit
            guard isRecognitionRectValid(normalized) else {
                return
            }

            singleSelectionRect = normalized
            callbacks?.onSingleSelectionChanged(normalized)
        case .moving, .resizing:
            if let workingSingleSelectionRect,
               isRecognitionRectValid(workingSingleSelectionRect) {
                let normalized = workingSingleSelectionRect.clampedToUnit
                singleSelectionRect = normalized
                callbacks?.onSingleSelectionChanged(normalized)
            }
        }
    }

    func handleFreeformTouchMoved(sample: TouchSample, location: CGPoint, imageFrame: CGRect) {
        if hitRegionID != nil, freeformStartPoint == nil {
            updateLoupe(with: sample, in: imageFrame, source: .freeformDrag)

            let translation = distance(between: activeTouchStartPoint ?? location, and: location)
            guard translation >= touchSlop else {
                renderScene()
                return
            }

            hitRegionID = nil
            localSelectedFreeformRegionID = nil
            selectedFreeformRegionID = nil
            callbacks?.onRegionSelected(nil)
            freeformStartPoint = activeTouchStartPoint ?? location
            freeformCurrentPoint = location
            renderScene()
            return
        }

        guard freeformStartPoint != nil else {
            renderScene()
            return
        }

        updateLoupe(with: sample, in: imageFrame, source: .freeformDrag)
        freeformCurrentPoint = location
        renderScene()
    }

    func finishFreeformTouch(at location: CGPoint, in imageFrame: CGRect) {
        defer {
            hitRegionID = nil
            freeformStartPoint = nil
            freeformCurrentPoint = nil
            endInteraction()
            renderScene()
        }

        if let hitRegionID {
            localSelectedFreeformRegionID = hitRegionID
            selectedFreeformRegionID = hitRegionID
            callbacks?.onRegionSelected(hitRegionID)
            return
        }

        guard let freeformStartPoint,
              let freeformCurrentPoint else {
            callbacks?.onRegionSelected(nil)
            return
        }

        let draftRect = CGRect(
            x: min(freeformStartPoint.x, freeformCurrentPoint.x),
            y: min(freeformStartPoint.y, freeformCurrentPoint.y),
            width: abs(freeformCurrentPoint.x - freeformStartPoint.x),
            height: abs(freeformCurrentPoint.y - freeformStartPoint.y)
        )

        let normalized = normalizedRect(from: draftRect, in: imageFrame).clampedToUnit
        guard isRecognitionRectValid(normalized) else {
            callbacks?.onRegionSelected(nil)
            return
        }

        let region = NotePhotoOCRSelectionRegion(normalizedRect: normalized)
        freeformRegions.append(region)
        localSelectedFreeformRegionID = region.id
        selectedFreeformRegionID = region.id
        callbacks?.onRegionCreated(normalized)
    }

    func initialSingleInteractionState(at point: CGPoint, in imageFrame: CGRect) -> SingleInteractionState {
        guard let effectiveSingleSelectionRect,
              let cropFrame = currentSingleFrame(in: imageFrame) else {
            return .drawing(anchor: point)
        }

        if let handle = handle(containing: point, in: cropFrame) {
            return .resizing(handle: handle, baseRect: effectiveSingleSelectionRect)
        }

        if cropFrame.contains(point) {
            return .pendingMoveOrRedraw(origin: point, baseRect: effectiveSingleSelectionRect, beganAt: Date())
        }

        return .pendingOutsideRedraw(anchor: point)
    }

    func updateLoupe(
        with sample: TouchSample,
        in imageFrame: CGRect,
        source: LoupeUpdateSource,
        anchorOverride: CGPoint? = nil
    ) {
        let normalizedSamplePoint = normalizedLoupeSamplePoint(
            for: sample,
            in: imageFrame,
            anchorOverride: anchorOverride
        )
        var nextSide = loupeState?.side ?? .leading
        let currentLoupeFrame = loupeFrame(in: bounds.size, side: nextSide)
        if currentLoupeFrame.insetBy(dx: -loupeCollisionPadding, dy: -loupeCollisionPadding).contains(sample.preciseLocation) {
            nextSide = oppositeSide(of: nextSide)
        }

        let nextState = LoupeState(
            normalizedSamplePoint: normalizedSamplePoint,
            source: source,
            side: nextSide
        )
        loupeState = nextState
        logLoupeAnomalyIfNeeded(nextState, imageFrame: imageFrame)
    }

    func hideLoupe() {
        loupeState = nil
        loupeView.hide()
    }

    func normalizedLoupeSamplePoint(
        for sample: TouchSample,
        in imageFrame: CGRect,
        anchorOverride: CGPoint?
    ) -> CGPoint {
        let samplePoint = (anchorOverride ?? sample.preciseLocation).clamped(to: imageFrame)
        return normalizedPoint(from: samplePoint, in: imageFrame)
    }

    func logLoupeAnomalyIfNeeded(_ loupeState: LoupeState, imageFrame: CGRect) {
        let samplePoint = point(fromNormalizedPoint: loupeState.normalizedSamplePoint, in: imageFrame)
        guard imageFrame.width > 0,
              imageFrame.height > 0,
              !imageFrame.insetBy(dx: -1, dy: -1).contains(samplePoint) else {
            return
        }

        print(
            "[BaiduOCRLoupe][Anomaly] source=\(loupeSourceDescription(loupeState.source)) " +
            "sample=(\(roundedInt(samplePoint.x)),\(roundedInt(samplePoint.y))) " +
            "imageFrame=(\(roundedInt(imageFrame.minX)),\(roundedInt(imageFrame.minY)),\(roundedInt(imageFrame.width)),\(roundedInt(imageFrame.height)))"
        )
    }

    func currentSingleFrame(in imageFrame: CGRect) -> CGRect? {
        guard let effectiveSingleSelectionRect else { return nil }
        return frame(for: effectiveSingleSelectionRect, in: imageFrame)
    }

    func draftFreeformRect(in imageFrame: CGRect) -> CGRect? {
        guard let freeformStartPoint,
              let freeformCurrentPoint else {
            return nil
        }

        return CGRect(
            x: min(freeformStartPoint.x, freeformCurrentPoint.x),
            y: min(freeformStartPoint.y, freeformCurrentPoint.y),
            width: abs(freeformCurrentPoint.x - freeformStartPoint.x),
            height: abs(freeformCurrentPoint.y - freeformStartPoint.y)
        )
        .intersection(imageFrame)
    }

    func fittedImageFrame(in containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    func frame(for normalizedRect: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + imageFrame.width * normalizedRect.minX,
            y: imageFrame.minY + imageFrame.height * normalizedRect.minY,
            width: imageFrame.width * normalizedRect.width,
            height: imageFrame.height * normalizedRect.height
        )
    }

    func normalizedRect(from frame: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: (frame.minX - imageFrame.minX) / imageFrame.width,
            y: (frame.minY - imageFrame.minY) / imageFrame.height,
            width: frame.width / imageFrame.width,
            height: frame.height / imageFrame.height
        )
    }

    func normalizedRect(from start: CGPoint, to end: CGPoint, in imageFrame: CGRect) -> CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        return CGRect(
            x: (minX - imageFrame.minX) / imageFrame.width,
            y: (minY - imageFrame.minY) / imageFrame.height,
            width: (maxX - minX) / imageFrame.width,
            height: (maxY - minY) / imageFrame.height
        )
    }

    func normalizedPoint(from point: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - imageFrame.minX) / imageFrame.width,
            y: (point.y - imageFrame.minY) / imageFrame.height
        )
    }

    func point(fromNormalizedPoint point: CGPoint, in imageFrame: CGRect) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + imageFrame.width * point.x,
            y: imageFrame.minY + imageFrame.height * point.y
        )
    }

    func position(for handle: Handle, in cropFrame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topCenter:
            return CGPoint(x: cropFrame.midX, y: cropFrame.minY)
        case .topRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .middleLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.midY)
        case .middleRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.midY)
        case .bottomLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomCenter:
            return CGPoint(x: cropFrame.midX, y: cropFrame.maxY)
        case .bottomRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        }
    }

    func handle(containing point: CGPoint, in cropFrame: CGRect) -> Handle? {
        Handle.allCases.first { handle in
            distance(between: point, and: position(for: handle, in: cropFrame)) <= handleHitDiameter / 2
        }
    }

    func region(containing point: CGPoint, in imageFrame: CGRect) -> NotePhotoOCRSelectionRegion? {
        freeformRegions
            .reversed()
            .first { region in
                frame(for: region.normalizedRect, in: imageFrame)
                    .insetBy(dx: -12, dy: -12)
                    .contains(point)
            }
    }

    func deleteButtonRegionID(at point: CGPoint, in imageFrame: CGRect) -> UUID? {
        freeformRegions.first { region in
            region.id == effectiveSelectedFreeformRegionID
                && deleteButtonFrame(for: frame(for: region.normalizedRect, in: imageFrame), imageFrame: imageFrame)
                .insetBy(dx: -10, dy: -10)
                .contains(point)
        }?.id
    }

    func deleteButtonFrame(for regionFrame: CGRect, imageFrame: CGRect) -> CGRect {
        OCRSelectionGeometry.deleteButtonFrame(for: regionFrame, imageFrame: imageFrame)
    }

    func translatedRect(
        from baseRect: CGRect,
        startPoint: CGPoint,
        currentPoint: CGPoint,
        in imageFrame: CGRect
    ) -> CGRect {
        let baseFrame = frame(for: baseRect, in: imageFrame)
        let deltaX = currentPoint.x - startPoint.x
        let deltaY = currentPoint.y - startPoint.y

        let unclampedFrame = baseFrame.offsetBy(dx: deltaX, dy: deltaY)
        let clampedOriginX = min(max(unclampedFrame.minX, imageFrame.minX), imageFrame.maxX - baseFrame.width)
        let clampedOriginY = min(max(unclampedFrame.minY, imageFrame.minY), imageFrame.maxY - baseFrame.height)
        let movedFrame = CGRect(
            x: clampedOriginX,
            y: clampedOriginY,
            width: baseFrame.width,
            height: baseFrame.height
        )
        return normalizedRect(from: movedFrame, in: imageFrame)
    }

    func resizedRect(
        from baseRect: CGRect,
        handle: Handle,
        location: CGPoint,
        in imageFrame: CGRect
    ) -> CGRect {
        let startFrame = frame(for: baseRect, in: imageFrame)
        var minX = startFrame.minX
        var minY = startFrame.minY
        var maxX = startFrame.maxX
        var maxY = startFrame.maxY

        switch handle {
        case .topLeft:
            minX = min(max(location.x, imageFrame.minX), maxX - minimumDisplayDimension(in: imageFrame, axis: .horizontal))
            minY = min(max(location.y, imageFrame.minY), maxY - minimumDisplayDimension(in: imageFrame, axis: .vertical))
        case .topCenter:
            minY = min(max(location.y, imageFrame.minY), maxY - minimumDisplayDimension(in: imageFrame, axis: .vertical))
        case .topRight:
            maxX = max(min(location.x, imageFrame.maxX), minX + minimumDisplayDimension(in: imageFrame, axis: .horizontal))
            minY = min(max(location.y, imageFrame.minY), maxY - minimumDisplayDimension(in: imageFrame, axis: .vertical))
        case .middleLeft:
            minX = min(max(location.x, imageFrame.minX), maxX - minimumDisplayDimension(in: imageFrame, axis: .horizontal))
        case .middleRight:
            maxX = max(min(location.x, imageFrame.maxX), minX + minimumDisplayDimension(in: imageFrame, axis: .horizontal))
        case .bottomLeft:
            minX = min(max(location.x, imageFrame.minX), maxX - minimumDisplayDimension(in: imageFrame, axis: .horizontal))
            maxY = max(min(location.y, imageFrame.maxY), minY + minimumDisplayDimension(in: imageFrame, axis: .vertical))
        case .bottomCenter:
            maxY = max(min(location.y, imageFrame.maxY), minY + minimumDisplayDimension(in: imageFrame, axis: .vertical))
        case .bottomRight:
            maxX = max(min(location.x, imageFrame.maxX), minX + minimumDisplayDimension(in: imageFrame, axis: .horizontal))
            maxY = max(min(location.y, imageFrame.maxY), minY + minimumDisplayDimension(in: imageFrame, axis: .vertical))
        }

        let resizedFrame = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        return normalizedRect(from: resizedFrame, in: imageFrame)
    }

    func distance(between start: CGPoint, and end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    func minimumDisplayDimension(in imageFrame: CGRect, axis: NSLayoutConstraint.Axis) -> CGFloat {
        let pixelDimension: CGFloat
        let displayDimension: CGFloat
        switch axis {
        case .horizontal:
            pixelDimension = imagePixelSize.width
            displayDimension = imageFrame.width
        case .vertical:
            pixelDimension = imagePixelSize.height
            displayDimension = imageFrame.height
        @unknown default:
            pixelDimension = imagePixelSize.width
            displayDimension = imageFrame.width
        }

        guard pixelDimension > 0, displayDimension > 0 else {
            return 0
        }

        return OCRSelectionGeometry.minimumRecognitionPixelSize / pixelDimension * displayDimension
    }

    func isRecognitionRectValid(_ normalizedRect: CGRect) -> Bool {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return false
        }

        let clamped = normalizedRect.clampedToUnit
        let pixelRect = CGRect(
            x: clamped.minX * imagePixelSize.width,
            y: clamped.minY * imagePixelSize.height,
            width: clamped.width * imagePixelSize.width,
            height: clamped.height * imagePixelSize.height
        )
        .integral
        .intersection(CGRect(origin: .zero, size: imagePixelSize))

        return pixelRect.width >= OCRSelectionGeometry.minimumRecognitionPixelSize
            && pixelRect.height >= OCRSelectionGeometry.minimumRecognitionPixelSize
    }

    func shouldDisplaySingleHandles(in cropFrame: CGRect?) -> Bool {
        guard let cropFrame else { return false }
        return min(cropFrame.width, cropFrame.height) >= OCRSelectionGeometry.handleVisibleMinimumDimension
    }

    func loupeFrame(in containerSize: CGSize, side: LoupeSide) -> CGRect {
        let width = max(containerSize.width, loupeDiameter + loupeHorizontalPadding * 2)
        let x: CGFloat = switch side {
        case .leading:
            loupeHorizontalPadding
        case .trailing:
            width - loupeDiameter - loupeHorizontalPadding
        }

        return CGRect(
            x: max(x, 0),
            y: max(loupeTopPadding, 0),
            width: loupeDiameter,
            height: loupeDiameter
        )
    }

    func oppositeSide(of side: LoupeSide) -> LoupeSide {
        switch side {
        case .leading:
            .trailing
        case .trailing:
            .leading
        }
    }

    func loupeSourceDescription(_ source: LoupeUpdateSource) -> String {
        switch source {
        case .singleDrawing:
            "singleDrawing"
        case .singlePendingOutsideRedraw:
            "singlePendingOutsideRedraw"
        case .singlePendingMoveOrRedraw:
            "singlePendingMoveOrRedraw"
        case .singleMoving:
            "singleMoving"
        case .singleResizing(let handle):
            "singleResizing-\(handleDescription(handle))"
        case .freeformStart:
            "freeformStart"
        case .freeformDrag:
            "freeformDrag"
        }
    }

    func handleDescription(_ handle: Handle) -> String {
        switch handle {
        case .topLeft:
            "topLeft"
        case .topCenter:
            "topCenter"
        case .topRight:
            "topRight"
        case .middleLeft:
            "middleLeft"
        case .middleRight:
            "middleRight"
        case .bottomLeft:
            "bottomLeft"
        case .bottomCenter:
            "bottomCenter"
        case .bottomRight:
            "bottomRight"
        }
    }

    func roundedInt(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }

    static func pixelSize(for image: UIImage?) -> CGSize {
        guard let image else { return .zero }
        if let cgImage = image.cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
}

private struct OCRSettingsScreen: View {
    @Bindable var viewModel: NotePhotoOCRFlowViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                credentialCard
                switchesCard
                cacheCard
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("OCR 设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .navigationPopGuard(canPop: !viewModel.isRecognizing, onBlockedAttempt: { })
    }
}

private extension OCRSettingsScreen {
    var credentialCard: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader(
                    title: "凭据",
                    description: "默认已预置 Android 同源 Debug 配置。这里的改写只保存在当前 iOS Debug 环境。"
                )

                inputField(
                    title: "API Key",
                    text: apiKeyBinding,
                    isSecure: false
                )

                inputField(
                    title: "Secret Key",
                    text: secretKeyBinding,
                    isSecure: true
                )
            }
            .padding(Spacing.contentEdge)
        }
    }

    var switchesCard: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader(
                    title: "识别策略",
                    description: "与 Android 设置保持同源：高精度、标点优化、中英混排优化与对齐网格线。"
                )

                Toggle("高精度 OCR", isOn: preferenceBinding(\.isHighPrecisionEnabled))
                Toggle("标点优化", isOn: preferenceBinding(\.isPunctuationOptimizationEnabled))
                Toggle("中英混排优化", isOn: preferenceBinding(\.isChineseEnglishSpacingOptimizationEnabled))
                Toggle("显示选择框网格线", isOn: preferenceBinding(\.showsCropGrid))
            }
            .padding(Spacing.contentEdge)
        }
    }

    var cacheCard: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader(
                    title: "调试工具",
                    description: "切换凭据或 SDK 状态异常时，可手动清理百度 OCR 的鉴权缓存。"
                )

                if let message = viewModel.errorMessage {
                    statusRow(text: message, tint: Color.feedbackWarning, icon: "exclamationmark.triangle.fill")
                } else if let message = viewModel.statusMessage {
                    statusRow(text: message, tint: Color.brand, icon: "checkmark.circle.fill")
                }

                Button("清除鉴权缓存") {
                    viewModel.clearAuthorizationCache()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brand)
                .disabled(viewModel.isRecognizing)
            }
            .padding(Spacing.contentEdge)
        }
    }

    func inputField(
        title: String,
        text: Binding<String>,
        isSecure: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            Group {
                if isSecure {
                    SecureField("输入\(title)", text: text)
                } else {
                    TextField("输入\(title)", text: text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        }
    }

    func sectionHeader(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            Text(description)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    func statusRow(text: String, tint: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.half) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
    }

    func preferenceBinding<Value>(_ keyPath: WritableKeyPath<OCRPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.preferences[keyPath: keyPath] },
            set: { newValue in
                var preferences = viewModel.preferences
                preferences[keyPath: keyPath] = newValue
                viewModel.preferences = preferences
            }
        )
    }

    var apiKeyBinding: Binding<String> {
        Binding(
            get: { viewModel.preferences.credentials.apiKey },
            set: { newValue in
                var preferences = viewModel.preferences
                preferences.credentials.apiKey = newValue
                viewModel.preferences = preferences
            }
        )
    }

    var secretKeyBinding: Binding<String> {
        Binding(
            get: { viewModel.preferences.credentials.secretKey },
            set: { newValue in
                var preferences = viewModel.preferences
                preferences.credentials.secretKey = newValue
                viewModel.preferences = preferences
            }
        )
    }
}

private struct OCRSelectionEditor: View {
    enum Handle: CaseIterable {
        case topLeft
        case topCenter
        case topRight
        case middleLeft
        case middleRight
        case bottomLeft
        case bottomCenter
        case bottomRight
    }

    private enum LoupeSide: Equatable {
        case leading
        case trailing
    }

    private enum LoupeUpdateSource: Equatable {
        case singleDrawing
        case singlePendingOutsideRedraw
        case singlePendingMoveOrRedraw
        case singleMoving
        case singleResizing(handle: Handle)
        case freeformStart
        case freeformDrag
    }

    private enum SingleInteractionState {
        case idle
        case drawing(anchor: CGPoint)
        case pendingOutsideRedraw(anchor: CGPoint)
        case pendingMoveOrRedraw(origin: CGPoint, baseRect: CGRect, beganAt: Date)
        case moving(origin: CGPoint, baseRect: CGRect)
        case resizing(handle: Handle, baseRect: CGRect)
    }

    let image: UIImage
    let selectionMode: NotePhotoOCRSelectionMode
    @Binding var singleSelectionRect: CGRect?
    @Binding var freeformRegions: [NotePhotoOCRSelectionRegion]
    @Binding var selectedFreeformRegionID: UUID?
    let showsGrid: Bool
    let onRegionCreated: (CGRect) -> Void
    let onRegionSelected: (UUID?) -> Void
    let onRegionDelete: (UUID) -> Void
    let onInteractionStateChanged: (Bool) -> Void

    @State private var singleInteractionState: SingleInteractionState = .idle
    @State private var isInteractionActive = false
    @State private var freeformStartPoint: CGPoint?
    @State private var freeformCurrentPoint: CGPoint?
    @State private var hitRegionID: UUID?
    @State private var loupeSamplePoint: CGPoint?
    @State private var isLoupeVisible = false
    @State private var loupeSide: LoupeSide = .leading
    @State private var lastLoupeLogMessage: String?

    private let minimumSingleSelectionPointSize: CGFloat = 24
    private let minimumFreeformSelectionPointSize: CGFloat = 24
    private let touchSlop: CGFloat = 6
    private let moveActivationDelay: TimeInterval = 0.2
    private let handleSize: CGFloat = 14
    private let handleHitDiameter: CGFloat = 56
    private let loupeDiameter: CGFloat = 110
    private let loupeMagnification: CGFloat = 3
    private let loupeTopPadding: CGFloat = 12
    private let loupeHorizontalPadding: CGFloat = 12
    private let loupeCollisionPadding: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let imageFrame = fittedImageFrame(in: proxy.size, imageSize: image.size)

            ZStack(alignment: .topLeading) {
                Color.black

                editorContent(
                    imageFrame: imageFrame,
                    containerSize: containerSize,
                    showsCropMask: true,
                    showsDeleteButtons: true,
                    allowsGestures: true
                )

                loupeOverlay(imageFrame: imageFrame, containerSize: containerSize)
            }
        }
        .clipped()
        .onChange(of: selectionMode) { _, _ in
            resetAllInteractionState()
        }
        .onDisappear {
            resetAllInteractionState()
        }
    }
}

private extension OCRSelectionEditor {
    @ViewBuilder
    func editorContent(
        imageFrame: CGRect,
        containerSize: CGSize,
        showsCropMask: Bool,
        showsDeleteButtons: Bool,
        allowsGestures: Bool
    ) -> some View {
        imageLayer(imageFrame: imageFrame)

        switch selectionMode {
        case .single:
            singleSelectionLayer(
                imageFrame: imageFrame,
                containerSize: containerSize,
                showsCropMask: showsCropMask,
                allowsGestures: allowsGestures
            )
        case .freeform:
            freeformSelectionLayer(
                imageFrame: imageFrame,
                containerSize: containerSize,
                showsDeleteButtons: showsDeleteButtons,
                allowsGestures: allowsGestures
            )
        }
    }

    func imageLayer(imageFrame: CGRect) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: imageFrame.width, height: imageFrame.height)
            .position(x: imageFrame.midX, y: imageFrame.midY)
    }

    var shouldShowSingleHandles: Bool {
        guard singleSelectionRect != nil else { return false }
        if case .idle = singleInteractionState {
            return true
        }
        return false
    }

    @ViewBuilder
    func singleSelectionLayer(
        imageFrame: CGRect,
        containerSize: CGSize,
        showsCropMask: Bool,
        allowsGestures: Bool
    ) -> some View {
        if allowsGestures {
            Color.clear
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .contentShape(Rectangle())
                .highPriorityGesture(singleSelectionGesture(within: imageFrame, containerSize: containerSize))
        }

        if let cropFrame = currentSingleFrame(in: imageFrame),
           cropFrame.width > 0,
           cropFrame.height > 0 {
            if showsCropMask {
                cropMask(imageFrame: imageFrame, cropFrame: cropFrame)
            }

            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.white.opacity(0.96), lineWidth: 1.5)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .allowsHitTesting(false)

            if showsGrid {
                cropGrid(cropFrame: cropFrame)
                    .allowsHitTesting(false)
            }

            if shouldShowSingleHandles {
                ForEach(Handle.allCases, id: \.self) { handle in
                    Circle()
                        .fill(Color.white)
                        .frame(width: handleSize, height: handleSize)
                        .shadow(color: .black.opacity(0.24), radius: 6, y: 2)
                        .position(position(for: handle, in: cropFrame))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    func freeformSelectionLayer(
        imageFrame: CGRect,
        containerSize: CGSize,
        showsDeleteButtons: Bool,
        allowsGestures: Bool
    ) -> some View {
        if allowsGestures {
            Color.clear
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .contentShape(Rectangle())
                .highPriorityGesture(freeformCreationGesture(within: imageFrame, containerSize: containerSize))
        }

        ForEach(freeformRegions, id: \.id) { region in
            freeformRegionLayer(
                region: region,
                imageFrame: imageFrame,
                containerSize: containerSize,
                showsDeleteButtons: showsDeleteButtons,
                allowsGestures: allowsGestures
            )
        }

        if let draftRect = draftFreeformRect(in: imageFrame) {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .fill(Color.brand.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.brand.opacity(0.94), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .frame(width: draftRect.width, height: draftRect.height)
                .position(x: draftRect.midX, y: draftRect.midY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func freeformRegionLayer(
        region: NotePhotoOCRSelectionRegion,
        imageFrame: CGRect,
        containerSize: CGSize,
        showsDeleteButtons: Bool,
        allowsGestures: Bool
    ) -> some View {
        let regionFrame = frame(for: region.normalizedRect, in: imageFrame)

        if allowsGestures {
            ZStack(alignment: .topTrailing) {
                freeformRegionDecoration(region: region)
                    .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    .highPriorityGesture(freeformCreationGesture(within: imageFrame, containerSize: containerSize))

                if showsDeleteButtons, region.id == selectedFreeformRegionID {
                    freeformDeleteButton(for: region.id)
                }
            }
            .frame(width: regionFrame.width, height: regionFrame.height)
            .position(x: regionFrame.midX, y: regionFrame.midY)
        } else {
            ZStack(alignment: .topTrailing) {
                freeformRegionDecoration(region: region)
            }
            .frame(width: regionFrame.width, height: regionFrame.height)
            .position(x: regionFrame.midX, y: regionFrame.midY)
        }
    }

    func freeformRegionDecoration(region: NotePhotoOCRSelectionRegion) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .fill(region.id == selectedFreeformRegionID ? Color.brand.opacity(0.14) : Color.white.opacity(0.08))
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(
                    region.id == selectedFreeformRegionID ? Color.brand.opacity(0.94) : Color.white.opacity(0.82),
                    lineWidth: region.id == selectedFreeformRegionID ? 1.5 : 1
                )
        }
    }

    func freeformDeleteButton(for regionID: UUID) -> some View {
        Button {
            withAnimation(.snappy) {
                onRegionDelete(regionID)
            }
        } label: {
            Image(systemName: "trash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("删除该选择框")
    }

    @ViewBuilder
    func loupeOverlay(imageFrame: CGRect, containerSize: CGSize) -> some View {
        if isLoupeVisible, let loupeSamplePoint {
            let loupePosition = loupePosition(in: containerSize, side: loupeSide)
            let loupeContentOffset = loupeContentOffset(for: loupeSamplePoint)

            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(Color.black.opacity(0.28))

                ZStack(alignment: .topLeading) {
                    editorContent(
                        imageFrame: imageFrame,
                        containerSize: containerSize,
                        showsCropMask: false,
                        showsDeleteButtons: false,
                        allowsGestures: false
                    )
                }
                    .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
                    .compositingGroup()
                    .scaleEffect(loupeMagnification, anchor: .topLeading)
                    .offset(x: loupeContentOffset.width, y: loupeContentOffset.height)

                Circle()
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.8)
                    .padding(14)

                Path { path in
                    let center = loupeDiameter / 2
                    path.move(to: CGPoint(x: center - 10, y: center))
                    path.addLine(to: CGPoint(x: center + 10, y: center))
                    path.move(to: CGPoint(x: center, y: center - 10))
                    path.addLine(to: CGPoint(x: center, y: center + 10))
                }
                .stroke(Color.white.opacity(0.82), lineWidth: 1)
            }
            .frame(width: loupeDiameter, height: loupeDiameter)
            .background {
                Circle()
                    .fill(Color.black.opacity(0.24))
            }
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(0.94), lineWidth: 1.5)
            }
            .shadow(color: .black.opacity(0.26), radius: 14, y: 8)
            .position(loupePosition)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .allowsHitTesting(false)
        }
    }

    func cropMask(imageFrame: CGRect, cropFrame: CGRect) -> some View {
        let cornerRadius = max(
            0,
            min(
                CornerRadius.blockMedium,
                min(cropFrame.width, cropFrame.height) / 2
            )
        )
        return Path { path in
            path.addRect(imageFrame)
            path.addPath(
                Path(
                    roundedRect: cropFrame,
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
        }
        .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
    }

    func cropGrid(cropFrame: CGRect) -> some View {
        ZStack {
            ForEach([1.0 / 3.0, 2.0 / 3.0], id: \.self) { ratio in
                Path { path in
                    let x = cropFrame.minX + cropFrame.width * ratio
                    path.move(to: CGPoint(x: x, y: cropFrame.minY))
                    path.addLine(to: CGPoint(x: x, y: cropFrame.maxY))
                }
                .stroke(Color.white.opacity(0.68), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                Path { path in
                    let y = cropFrame.minY + cropFrame.height * ratio
                    path.move(to: CGPoint(x: cropFrame.minX, y: y))
                    path.addLine(to: CGPoint(x: cropFrame.maxX, y: y))
                }
                .stroke(Color.white.opacity(0.68), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    func singleSelectionGesture(within imageFrame: CGRect, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageFrame.contains(value.startLocation) else { return }

                let startPoint = value.startLocation.clamped(to: imageFrame)
                let location = value.location.clamped(to: imageFrame)

                if case .idle = singleInteractionState {
                    beginInteraction()
                    singleInteractionState = initialSingleInteractionState(at: startPoint, in: imageFrame)
                }

                handleSingleGestureChanged(location: location, in: imageFrame, containerSize: containerSize)
            }
            .onEnded { value in
                guard isInteractionActive else { return }
                let location = value.location.clamped(to: imageFrame)
                finishSingleGesture(at: location, in: imageFrame)
            }
    }

    func freeformCreationGesture(within imageFrame: CGRect, containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard imageFrame.contains(value.startLocation) else { return }

                let clampedStart = value.startLocation.clamped(to: imageFrame)
                let clampedLocation = value.location.clamped(to: imageFrame)

                if hitRegionID == nil, freeformStartPoint == nil {
                    beginInteraction()
                    updateLoupe(
                        at: clampedStart,
                        in: imageFrame,
                        containerSize: containerSize,
                        source: .freeformStart
                    )

                    if let region = region(containing: clampedStart, in: imageFrame) {
                        hitRegionID = region.id
                        onRegionSelected(region.id)
                        return
                    }

                    onRegionSelected(nil)
                    freeformStartPoint = clampedStart
                    freeformCurrentPoint = clampedStart
                }

                if hitRegionID != nil, freeformStartPoint == nil {
                    updateLoupe(
                        at: clampedLocation,
                        in: imageFrame,
                        containerSize: containerSize,
                        source: .freeformDrag
                    )

                    let translation = distance(between: clampedStart, and: clampedLocation)
                    guard translation >= touchSlop else { return }
                    hitRegionID = nil
                    onRegionSelected(nil)
                    freeformStartPoint = clampedStart
                    freeformCurrentPoint = clampedLocation
                    return
                }

                guard freeformStartPoint != nil else { return }
                updateLoupe(
                    at: clampedLocation,
                    in: imageFrame,
                    containerSize: containerSize,
                    source: .freeformDrag
                )
                freeformCurrentPoint = clampedLocation
            }
            .onEnded { value in
                defer {
                    hitRegionID = nil
                    freeformStartPoint = nil
                    freeformCurrentPoint = nil
                    endInteraction()
                }

                guard imageFrame.contains(value.startLocation) else { return }

                if let hitRegionID {
                    onRegionSelected(hitRegionID)
                    return
                }

                guard let freeformStartPoint,
                      let freeformCurrentPoint else {
                    onRegionSelected(nil)
                    return
                }

                let draftRect = CGRect(
                    x: min(freeformStartPoint.x, freeformCurrentPoint.x),
                    y: min(freeformStartPoint.y, freeformCurrentPoint.y),
                    width: abs(freeformCurrentPoint.x - freeformStartPoint.x),
                    height: abs(freeformCurrentPoint.y - freeformStartPoint.y)
                )

                guard isLargeEnough(draftRect, minimumPointSize: minimumFreeformSelectionPointSize) else {
                    onRegionSelected(nil)
                    return
                }

                onRegionCreated(normalizedRect(from: draftRect, in: imageFrame).clampedToUnit)
            }
    }

    func beginInteraction() {
        guard !isInteractionActive else { return }
        isInteractionActive = true
        onInteractionStateChanged(true)
    }

    func endInteraction() {
        hideLoupe()
        guard isInteractionActive else { return }
        isInteractionActive = false
        onInteractionStateChanged(false)
    }

    func resetAllInteractionState() {
        singleInteractionState = .idle
        freeformStartPoint = nil
        freeformCurrentPoint = nil
        hitRegionID = nil
        endInteraction()
    }

    private func initialSingleInteractionState(at point: CGPoint, in imageFrame: CGRect) -> SingleInteractionState {
        guard let singleSelectionRect,
              let cropFrame = currentSingleFrame(in: imageFrame) else {
            return .drawing(anchor: point)
        }

        if let handle = handle(containing: point, in: cropFrame) {
            return .resizing(handle: handle, baseRect: singleSelectionRect)
        }

        if cropFrame.contains(point) {
            return .pendingMoveOrRedraw(origin: point, baseRect: singleSelectionRect, beganAt: Date())
        }

        return .pendingOutsideRedraw(anchor: point)
    }

    func handleSingleGestureChanged(location: CGPoint, in imageFrame: CGRect, containerSize: CGSize) {
        switch singleInteractionState {
        case .idle:
            break
        case .drawing(let anchor):
            singleSelectionRect = normalizedRect(from: anchor, to: location, in: imageFrame)
            updateLoupe(
                at: location,
                in: imageFrame,
                containerSize: containerSize,
                source: .singleDrawing
            )
        case .pendingOutsideRedraw(let anchor):
            updateLoupe(
                at: location,
                in: imageFrame,
                containerSize: containerSize,
                source: .singlePendingOutsideRedraw
            )
            guard distance(between: anchor, and: location) >= touchSlop else { return }
            singleInteractionState = .drawing(anchor: anchor)
            singleSelectionRect = normalizedRect(from: anchor, to: location, in: imageFrame)
        case .pendingMoveOrRedraw(let origin, let baseRect, let beganAt):
            updateLoupe(
                at: location,
                in: imageFrame,
                containerSize: containerSize,
                source: .singlePendingMoveOrRedraw
            )
            guard distance(between: origin, and: location) >= touchSlop else { return }

            if Date().timeIntervalSince(beganAt) >= moveActivationDelay {
                singleInteractionState = .moving(origin: origin, baseRect: baseRect)
                singleSelectionRect = translatedRect(from: baseRect, startPoint: origin, currentPoint: location, in: imageFrame)
            } else {
                singleInteractionState = .drawing(anchor: location)
                singleSelectionRect = normalizedRect(from: location, to: location, in: imageFrame)
            }
        case .moving(let origin, let baseRect):
            singleSelectionRect = translatedRect(from: baseRect, startPoint: origin, currentPoint: location, in: imageFrame)
            updateLoupe(
                at: location,
                in: imageFrame,
                containerSize: containerSize,
                source: .singleMoving
            )
        case .resizing(let handle, let baseRect):
            let resizedRect = resizedRect(from: baseRect, handle: handle, location: location, in: imageFrame)
            singleSelectionRect = resizedRect
            let resizedFrame = frame(for: resizedRect, in: imageFrame)
            updateLoupe(
                at: position(for: handle, in: resizedFrame),
                in: imageFrame,
                containerSize: containerSize,
                source: .singleResizing(handle: handle)
            )
        }
    }

    func finishSingleGesture(at location: CGPoint, in imageFrame: CGRect) {
        defer {
            singleInteractionState = .idle
            endInteraction()
        }

        switch singleInteractionState {
        case .idle, .pendingOutsideRedraw, .pendingMoveOrRedraw:
            return
        case .drawing(let anchor):
            let draftFrame = CGRect(
                x: min(anchor.x, location.x),
                y: min(anchor.y, location.y),
                width: abs(location.x - anchor.x),
                height: abs(location.y - anchor.y)
            )

            guard isLargeEnough(draftFrame, minimumPointSize: minimumSingleSelectionPointSize) else {
                singleSelectionRect = nil
                return
            }

            singleSelectionRect = normalizedRect(from: draftFrame, in: imageFrame).clampedToUnit
        case .moving, .resizing:
            if let singleSelectionRect {
                self.singleSelectionRect = singleSelectionRect.clampedToUnit
            }
        }
    }

    func translatedRect(
        from baseRect: CGRect,
        startPoint: CGPoint,
        currentPoint: CGPoint,
        in imageFrame: CGRect
    ) -> CGRect {
        let baseFrame = frame(for: baseRect, in: imageFrame)
        let deltaX = currentPoint.x - startPoint.x
        let deltaY = currentPoint.y - startPoint.y

        let unclampedFrame = baseFrame.offsetBy(dx: deltaX, dy: deltaY)
        let clampedOriginX = min(max(unclampedFrame.minX, imageFrame.minX), imageFrame.maxX - baseFrame.width)
        let clampedOriginY = min(max(unclampedFrame.minY, imageFrame.minY), imageFrame.maxY - baseFrame.height)
        let movedFrame = CGRect(
            x: clampedOriginX,
            y: clampedOriginY,
            width: baseFrame.width,
            height: baseFrame.height
        )
        return normalizedRect(from: movedFrame, in: imageFrame)
    }

    func resizedRect(
        from baseRect: CGRect,
        handle: Handle,
        location: CGPoint,
        in imageFrame: CGRect
    ) -> CGRect {
        let startFrame = frame(for: baseRect, in: imageFrame)
        var minX = startFrame.minX
        var minY = startFrame.minY
        var maxX = startFrame.maxX
        var maxY = startFrame.maxY

        switch handle {
        case .topLeft:
            minX = min(max(location.x, imageFrame.minX), maxX - minimumSingleSelectionPointSize)
            minY = min(max(location.y, imageFrame.minY), maxY - minimumSingleSelectionPointSize)
        case .topCenter:
            minY = min(max(location.y, imageFrame.minY), maxY - minimumSingleSelectionPointSize)
        case .topRight:
            maxX = max(min(location.x, imageFrame.maxX), minX + minimumSingleSelectionPointSize)
            minY = min(max(location.y, imageFrame.minY), maxY - minimumSingleSelectionPointSize)
        case .middleLeft:
            minX = min(max(location.x, imageFrame.minX), maxX - minimumSingleSelectionPointSize)
        case .middleRight:
            maxX = max(min(location.x, imageFrame.maxX), minX + minimumSingleSelectionPointSize)
        case .bottomLeft:
            minX = min(max(location.x, imageFrame.minX), maxX - minimumSingleSelectionPointSize)
            maxY = max(min(location.y, imageFrame.maxY), minY + minimumSingleSelectionPointSize)
        case .bottomCenter:
            maxY = max(min(location.y, imageFrame.maxY), minY + minimumSingleSelectionPointSize)
        case .bottomRight:
            maxX = max(min(location.x, imageFrame.maxX), minX + minimumSingleSelectionPointSize)
            maxY = max(min(location.y, imageFrame.maxY), minY + minimumSingleSelectionPointSize)
        }

        let resizedFrame = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        return normalizedRect(from: resizedFrame, in: imageFrame)
    }

    private func updateLoupe(
        at point: CGPoint,
        in imageFrame: CGRect,
        containerSize: CGSize,
        source: LoupeUpdateSource
    ) {
        let clampedPoint = point.clamped(to: imageFrame)
        loupeSamplePoint = clampedPoint
        let currentLoupeFrame = loupeFrame(in: containerSize, side: loupeSide)
        if currentLoupeFrame.insetBy(dx: -loupeCollisionPadding, dy: -loupeCollisionPadding).contains(clampedPoint) {
            loupeSide = oppositeSide(of: loupeSide)
        }
        isLoupeVisible = true
        logLoupeState(
            inputPoint: point,
            samplePoint: clampedPoint,
            source: source,
            imageFrame: imageFrame,
            containerSize: containerSize
        )
    }

    func hideLoupe() {
        isLoupeVisible = false
        loupeSamplePoint = nil
        loupeSide = .leading
        lastLoupeLogMessage = nil
    }

    private func loupePosition(in containerSize: CGSize, side: LoupeSide) -> CGPoint {
        let frame = loupeFrame(in: containerSize, side: side)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func loupeFrame(in containerSize: CGSize, side: LoupeSide) -> CGRect {
        let width = max(containerSize.width, loupeDiameter + loupeHorizontalPadding * 2)
        let x: CGFloat
        switch side {
        case .leading:
            x = loupeHorizontalPadding
        case .trailing:
            x = width - loupeDiameter - loupeHorizontalPadding
        }
        let y = loupeTopPadding

        return CGRect(
            x: max(x, 0),
            y: max(y, 0),
            width: loupeDiameter,
            height: loupeDiameter
        )
    }

    private func oppositeSide(of side: LoupeSide) -> LoupeSide {
        switch side {
        case .leading:
            .trailing
        case .trailing:
            .leading
        }
    }

    private func loupeContentOffset(for samplePoint: CGPoint) -> CGSize {
        CGSize(
            width: loupeDiameter / 2 - samplePoint.x * loupeMagnification,
            height: loupeDiameter / 2 - samplePoint.y * loupeMagnification
        )
    }

    private func logLoupeState(
        inputPoint: CGPoint,
        samplePoint: CGPoint,
        source: LoupeUpdateSource,
        imageFrame: CGRect,
        containerSize: CGSize
    ) {
        let offset = loupeContentOffset(for: samplePoint)
        let message =
            "[BaiduOCRLoupe] source=\(loupeSourceDescription(source)) " +
            "input=(\(roundedInt(inputPoint.x)),\(roundedInt(inputPoint.y))) " +
            "sample=(\(roundedInt(samplePoint.x)),\(roundedInt(samplePoint.y))) " +
            "imageOrigin=(\(roundedInt(imageFrame.minX)),\(roundedInt(imageFrame.minY))) " +
            "imageSize=(\(roundedInt(imageFrame.width))x\(roundedInt(imageFrame.height))) " +
            "container=(\(roundedInt(containerSize.width))x\(roundedInt(containerSize.height))) " +
            "offset=(\(roundedInt(offset.width)),\(roundedInt(offset.height))) " +
            "side=\(loupeSideDescription(loupeSide))"

        guard lastLoupeLogMessage != message else { return }
        lastLoupeLogMessage = message
        print(message)
    }

    private func loupeSideDescription(_ side: LoupeSide) -> String {
        switch side {
        case .leading:
            "leading"
        case .trailing:
            "trailing"
        }
    }

    private func loupeSourceDescription(_ source: LoupeUpdateSource) -> String {
        switch source {
        case .singleDrawing:
            "singleDrawing"
        case .singlePendingOutsideRedraw:
            "singlePendingOutsideRedraw"
        case .singlePendingMoveOrRedraw:
            "singlePendingMoveOrRedraw"
        case .singleMoving:
            "singleMoving"
        case .singleResizing(let handle):
            "singleResizing-\(handleDescription(handle))"
        case .freeformStart:
            "freeformStart"
        case .freeformDrag:
            "freeformDrag"
        }
    }

    private func handleDescription(_ handle: Handle) -> String {
        switch handle {
        case .topLeft:
            "topLeft"
        case .topCenter:
            "topCenter"
        case .topRight:
            "topRight"
        case .middleLeft:
            "middleLeft"
        case .middleRight:
            "middleRight"
        case .bottomLeft:
            "bottomLeft"
        case .bottomCenter:
            "bottomCenter"
        case .bottomRight:
            "bottomRight"
        }
    }

    private func roundedInt(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }

    func currentSingleFrame(in imageFrame: CGRect) -> CGRect? {
        guard let singleSelectionRect else { return nil }
        return frame(for: singleSelectionRect, in: imageFrame)
    }

    func handle(containing point: CGPoint, in cropFrame: CGRect) -> Handle? {
        Handle.allCases.first { handle in
            distance(between: point, and: position(for: handle, in: cropFrame)) <= handleHitDiameter / 2
        }
    }

    func fittedImageFrame(in containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: (containerSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    func frame(for normalizedRect: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + imageFrame.width * normalizedRect.minX,
            y: imageFrame.minY + imageFrame.height * normalizedRect.minY,
            width: imageFrame.width * normalizedRect.width,
            height: imageFrame.height * normalizedRect.height
        )
    }

    func normalizedRect(from frame: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: (frame.minX - imageFrame.minX) / imageFrame.width,
            y: (frame.minY - imageFrame.minY) / imageFrame.height,
            width: frame.width / imageFrame.width,
            height: frame.height / imageFrame.height
        )
    }

    func position(for handle: Handle, in cropFrame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topCenter:
            return CGPoint(x: cropFrame.midX, y: cropFrame.minY)
        case .topRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .middleLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.midY)
        case .middleRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.midY)
        case .bottomLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomCenter:
            return CGPoint(x: cropFrame.midX, y: cropFrame.maxY)
        case .bottomRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        }
    }

    func draftFreeformRect(in imageFrame: CGRect) -> CGRect? {
        guard let freeformStartPoint,
              let freeformCurrentPoint else {
            return nil
        }

        return CGRect(
            x: min(freeformStartPoint.x, freeformCurrentPoint.x),
            y: min(freeformStartPoint.y, freeformCurrentPoint.y),
            width: abs(freeformCurrentPoint.x - freeformStartPoint.x),
            height: abs(freeformCurrentPoint.y - freeformStartPoint.y)
        )
        .intersection(imageFrame)
    }

    func normalizedRect(from start: CGPoint, to end: CGPoint, in imageFrame: CGRect) -> CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        return CGRect(
            x: (minX - imageFrame.minX) / imageFrame.width,
            y: (minY - imageFrame.minY) / imageFrame.height,
            width: (maxX - minX) / imageFrame.width,
            height: (maxY - minY) / imageFrame.height
        )
    }

    func region(containing point: CGPoint, in imageFrame: CGRect) -> NotePhotoOCRSelectionRegion? {
        freeformRegions
            .reversed()
            .first { region in
                frame(for: region.normalizedRect, in: imageFrame)
                    .insetBy(dx: -12, dy: -12)
                    .contains(point)
            }
    }

    func distance(between start: CGPoint, and end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    func isLargeEnough(_ rect: CGRect, minimumPointSize: CGFloat) -> Bool {
        rect.width >= minimumPointSize && rect.height >= minimumPointSize
    }
}

private struct OCRCameraPreview: UIViewRepresentable {
    @ObservedObject var controller: OCRCameraSessionController
    let onTapToFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let previewView = PreviewView()
        previewView.previewLayer.videoGravity = .resizeAspectFill
        previewView.previewLayer.session = controller.session
        previewView.onLayoutChanged = { [weak controller] previewLayer, bounds in
            controller?.updatePreviewVisibleRect(previewLayer: previewLayer, bounds: bounds)
        }
        controller.updatePreviewVisibleRect(previewLayer: previewView.previewLayer, bounds: previewView.bounds)

        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        previewView.addGestureRecognizer(tapGesture)

        context.coordinator.previewView = previewView
        return previewView
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== controller.session {
            uiView.previewLayer.session = controller.session
        }
        uiView.onLayoutChanged = { [weak controller] previewLayer, bounds in
            controller?.updatePreviewVisibleRect(previewLayer: previewLayer, bounds: bounds)
        }
        controller.updatePreviewVisibleRect(previewLayer: uiView.previewLayer, bounds: uiView.bounds)
        context.coordinator.previewView = uiView
        context.coordinator.controller = controller
        context.coordinator.onTapToFocus = onTapToFocus
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onTapToFocus: onTapToFocus)
    }

    final class Coordinator: NSObject {
        weak var previewView: PreviewView?
        weak var controller: OCRCameraSessionController?
        var onTapToFocus: (CGPoint) -> Void

        init(
            controller: OCRCameraSessionController,
            onTapToFocus: @escaping (CGPoint) -> Void
        ) {
            self.controller = controller
            self.onTapToFocus = onTapToFocus
        }

        @objc func handleTap(_ gestureRecognizer: UITapGestureRecognizer) {
            guard let previewView else { return }
            let point = gestureRecognizer.location(in: previewView)
            onTapToFocus(point)
            controller?.focus(atLayerPoint: point, previewLayer: previewView.previewLayer)
        }
    }
}

private final class PreviewView: UIView {
    var onLayoutChanged: ((AVCaptureVideoPreviewLayer, CGRect) -> Void)?

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutChanged?(previewLayer, bounds)
    }
}

private final class OCRCameraSessionController: NSObject, ObservableObject {
    fileprivate struct OCRCapturedPhotoPayload {
        let imageData: Data
        let orientation: CGImagePropertyOrientation
        let previewBoundsSize: CGSize
    }

    enum State: Equatable {
        case idle
        case preparing
        case ready
        case denied
        case restricted
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isCapturing = false
    @Published private(set) var isFlashAvailable = false
    @Published var flashMode: AVCaptureDevice.FlashMode = .off

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "debug.baidu.ocr.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var hasPreparedSession = false
    private var captureDelegates: [Int64: OCRPhotoCaptureProcessor] = [:]
    private var previewBoundsSize: CGSize = .zero

    var isReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    var hasPreparedPreview: Bool {
        hasPreparedSession
    }

    var shouldShowFailurePlaceholder: Bool {
        switch state {
        case .denied, .restricted, .unavailable, .failed:
            true
        case .idle, .preparing, .ready:
            false
        }
    }

    var canCapturePhoto: Bool {
        isReady && !isCapturing
    }

    var placeholderIconName: String {
        switch state {
        case .denied, .restricted:
            return "camera.fill.badge.xmark"
        case .unavailable:
            return "camera.slash.fill"
        case .failed:
            return "exclamationmark.camera.fill"
        case .idle, .preparing, .ready:
            return "camera.aperture"
        }
    }

    var stateMessage: String {
        switch state {
        case .idle, .preparing:
            return "正在准备相机…"
        case .ready:
            return "点击预览区域可重新对焦"
        case .denied:
            return "相机权限已关闭，请在系统设置中允许 XMNote 使用相机。"
        case .restricted:
            return "当前设备限制了相机权限，无法进入拍照模式。"
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    func prepareSession() {
        guard !hasPreparedSession else {
            startSession()
            return
        }

        DispatchQueue.main.async {
            self.state = .preparing
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSessionIfNeeded()
                } else {
                    DispatchQueue.main.async {
                        self.state = .denied
                    }
                }
            }
        case .denied:
            DispatchQueue.main.async {
                self.state = .denied
            }
        case .restricted:
            DispatchQueue.main.async {
                self.state = .restricted
            }
        @unknown default:
            DispatchQueue.main.async {
                self.state = .failed("遇到了未知的相机权限状态。")
            }
        }
    }

    func startSession() {
        guard hasPreparedSession else { return }
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        guard hasPreparedSession else { return }
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func toggleFlashMode() {
        guard isFlashAvailable else { return }
        flashMode = flashMode == .on ? .off : .on
    }

    func updatePreviewVisibleRect(previewLayer: AVCaptureVideoPreviewLayer, bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        configureConnectionOrientation(for: previewLayer.connection)
        previewBoundsSize = bounds.size
    }

    func focus(atLayerPoint point: CGPoint, previewLayer: AVCaptureVideoPreviewLayer) {
        guard let videoInput else { return }
        configureConnectionOrientation(for: previewLayer.connection)
        let captureDevicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        sessionQueue.async {
            let device = videoInput.device
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = captureDevicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = captureDevicePoint
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isSubjectAreaChangeMonitoringEnabled {
                    device.isSubjectAreaChangeMonitoringEnabled = true
                }
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed("相机对焦失败，请重新尝试。")
                }
            }
        }
    }

    func capturePhoto() async throws -> UIImage {
        guard canCapturePhoto else {
            throw OCRCameraControllerError.cameraUnavailable(reason: stateMessage)
        }

        let currentPreviewBoundsSize = previewBoundsSize

        DispatchQueue.main.async {
            self.isCapturing = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: OCRCameraControllerError.cameraUnavailable(reason: "相机会话已释放。"))
                    return
                }

                let settings = AVCapturePhotoSettings()
                if self.isFlashAvailable {
                    settings.flashMode = self.flashMode
                }
                if #available(iOS 16.0, *) {
                    settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                } else {
                    settings.isHighResolutionPhotoEnabled = true
                }

                let delegate = OCRPhotoCaptureProcessor { [weak self] result in
                    DispatchQueue.main.async {
                        self?.isCapturing = false
                    }
                    continuation.resume(
                        with: result.flatMap { payload in
                            let enrichedPayload = OCRCapturedPhotoPayload(
                                imageData: payload.imageData,
                                orientation: payload.orientation,
                                previewBoundsSize: currentPreviewBoundsSize
                            )
                            if let image = self?.makePreviewMatchedImage(from: enrichedPayload)
                                ?? self?.fallbackImage(from: enrichedPayload) {
                                return .success(image)
                            }
                            return .failure(OCRCameraControllerError.invalidPhotoData)
                        }
                    )
                } onFinish: { [weak self] uniqueID in
                    self?.sessionQueue.async {
                        self?.captureDelegates.removeValue(forKey: uniqueID)
                    }
                }

                self.captureDelegates[settings.uniqueID] = delegate
                Task { @MainActor [weak self] in
                    self?.configureConnectionOrientation(for: self?.photoOutput.connection(with: .video))
                    self?.photoOutput.capturePhoto(with: settings, delegate: delegate)
                }
            }
        }
    }
}

private extension OCRCameraSessionController {
    func configureSessionIfNeeded() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.hasPreparedSession {
                self.startSession()
                DispatchQueue.main.async {
                    self.state = .ready
                }
                return
            }

            do {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        self.state = .unavailable("当前设备没有可用的后置相机。")
                    }
                    return
                }

                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        self.state = .failed("无法将相机输入添加到当前会话。")
                    }
                    return
                }
                self.session.addInput(input)

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async {
                        self.state = .failed("无法创建拍照输出，请重新启动调试页。")
                    }
                    return
                }
                self.session.addOutput(self.photoOutput)
                self.configureConnectionOrientation(for: self.photoOutput.connection(with: .video))
                self.session.commitConfiguration()

                self.videoInput = input
                self.hasPreparedSession = true
                self.startSession()

                DispatchQueue.main.async {
                    self.isFlashAvailable = device.hasFlash
                    self.state = .ready
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.state = .failed("相机初始化失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func configureConnectionOrientation(for connection: AVCaptureConnection?) {
        guard let connection else { return }
        if #available(iOS 17.0, *) {
            guard connection.isVideoRotationAngleSupported(90) else { return }
            connection.videoRotationAngle = 90
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    func makePreviewMatchedImage(from payload: OCRCapturedPhotoPayload) -> UIImage? {
        guard let uprightImage = Self.makeUprightImage(from: payload.imageData, orientation: payload.orientation) else {
            return nil
        }

        let cropRect = Self.aspectFillVisibleRect(
            imageSize: uprightImage.size,
            containerSize: payload.previewBoundsSize
        )

        return Self.cropImage(uprightImage, to: cropRect) ?? uprightImage
    }

    func fallbackImage(from payload: OCRCapturedPhotoPayload) -> UIImage? {
        Self.makeUprightImage(from: payload.imageData, orientation: payload.orientation)
    }

    static func makeUprightImage(from imageData: Data, orientation: CGImagePropertyOrientation) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let ciImage = CIImage(cgImage: cgImage)
            .oriented(forExifOrientation: Int32(orientation.rawValue))
        let extent = ciImage.extent.integral
        guard extent.width > 0,
              extent.height > 0,
              let uprightCGImage = CIContext(options: nil).createCGImage(ciImage, from: extent) else {
            return nil
        }

        return UIImage(cgImage: uprightCGImage, scale: 1, orientation: .up)
    }

    static func aspectFillVisibleRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        if containerAspect > imageAspect {
            let visibleHeight = imageSize.width / containerAspect
            let originY = max((imageSize.height - visibleHeight) / 2, 0)
            return CGRect(x: 0, y: originY, width: imageSize.width, height: visibleHeight)
        }

        let visibleWidth = imageSize.height * containerAspect
        let originX = max((imageSize.width - visibleWidth) / 2, 0)
        return CGRect(x: originX, y: 0, width: visibleWidth, height: imageSize.height)
    }

    static func cropImage(_ image: UIImage, to cropRect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let scaledCropRect = CGRect(
            x: cropRect.minX * image.scale,
            y: cropRect.minY * image.scale,
            width: cropRect.width * image.scale,
            height: cropRect.height * image.scale
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard scaledCropRect.width > 1,
              scaledCropRect.height > 1,
              let croppedCGImage = cgImage.cropping(to: scaledCropRect) else {
            return nil
        }

        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: .up)
    }
}

private final class OCRPhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<OCRCameraSessionController.OCRCapturedPhotoPayload, Error>) -> Void
    private let onFinish: (Int64) -> Void
    private var didComplete = false

    init(
        completion: @escaping (Result<OCRCameraSessionController.OCRCapturedPhotoPayload, Error>) -> Void,
        onFinish: @escaping (Int64) -> Void
    ) {
        self.completion = completion
        self.onFinish = onFinish
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            finish(.failure(OCRCameraControllerError.invalidPhotoData))
            return
        }

        let orientation = Self.photoOrientation(from: photo.metadata)
        finish(
            .success(
                OCRCameraSessionController.OCRCapturedPhotoPayload(
                    imageData: imageData,
                    orientation: orientation,
                    previewBoundsSize: .zero
                )
            )
        )
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            finish(.failure(error))
        }
        onFinish(resolvedSettings.uniqueID)
    }

    private func finish(_ result: Result<OCRCameraSessionController.OCRCapturedPhotoPayload, Error>) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }

    static func photoOrientation(from metadata: [String: Any]) -> CGImagePropertyOrientation {
        if let rawValue = metadata[kCGImagePropertyOrientation as String] as? UInt32,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue) {
            return orientation
        }
        if let rawValue = metadata[kCGImagePropertyOrientation as String] as? Int,
           let orientation = CGImagePropertyOrientation(rawValue: UInt32(rawValue)) {
            return orientation
        }
        return .right
    }
}

private enum OCRCameraControllerError: LocalizedError {
    case invalidPhotoData
    case cameraUnavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidPhotoData:
            return "拍摄结果无法转换为可用图片，请重新拍摄。"
        case .cameraUnavailable(let reason):
            return reason
        }
    }
}

private extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(x, rect.minX), rect.maxX),
            y: min(max(y, rect.minY), rect.maxY)
        )
    }
}

private extension CGRect {
    var clampedToUnit: CGRect {
        let width = min(max(size.width, 0), 1)
        let height = min(max(size.height, 0), 1)
        let x = min(max(origin.x, 0), 1 - width)
        let y = min(max(origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func translatedToFit(in bounds: CGRect) -> CGRect {
        guard width <= bounds.width, height <= bounds.height else {
            return CGRect(
                x: bounds.minX + max((bounds.width - width) / 2, 0),
                y: bounds.minY + max((bounds.height - height) / 2, 0),
                width: min(width, bounds.width),
                height: min(height, bounds.height)
            )
        }

        let clampedMinX = min(max(minX, bounds.minX), bounds.maxX - width)
        let clampedMinY = min(max(minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: clampedMinX, y: clampedMinY, width: width, height: height)
    }
}
