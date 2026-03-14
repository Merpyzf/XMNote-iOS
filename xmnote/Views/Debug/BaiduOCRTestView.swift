#if DEBUG
/**
 * [INPUT]: 依赖 RepositoryContainer 注入 OCR 仓储，依赖 BaiduOCRTestViewModel 驱动状态，依赖 RichTextEditor 承接识别结果回填
 * [OUTPUT]: 对外提供 BaiduOCRTestView（百度 OCR SDK 调试页）
 * [POS]: Debug 模块百度 OCR 完整功能测试入口，覆盖图片选择、裁切、识别、设置持久化与富文本回填链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

struct BaiduOCRTestView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BaiduOCRTestViewModel?

    var body: some View {
        Group {
            if let viewModel {
                BaiduOCRTestContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = BaiduOCRTestViewModel(repository: repositories.ocrRepository)
        }
    }
}

private struct BaiduOCRTestContentView: View {
    @Bindable var viewModel: BaiduOCRTestViewModel
    @State private var isSourceDialogPresented = false
    @State private var activePicker: OCRImagePicker.Source?
    @State private var isCropInteractionActive = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                capabilitySection
                credentialSection
                imageSection
                settingSection
                editorSection
                resultSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .scrollDisabled(isCropInteractionActive)
        .background(Color.surfacePage)
        .navigationTitle("百度 OCR")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "选择图片来源",
            isPresented: $isSourceDialogPresented,
            titleVisibility: .visible
        ) {
            if viewModel.canUseCamera {
                Button("拍照") {
                    activePicker = .camera
                }
            }
            Button("相册") {
                activePicker = .photoLibrary
            }
        } message: {
            Text("拍照使用系统相机，相册选择将直接回到裁切预览。")
        }
        .sheet(item: $activePicker) { source in
            OCRImagePicker(source: source) { image in
                viewModel.selectImage(image, sourceTitle: source.title)
            }
        }
    }
}

private extension BaiduOCRTestContentView {
    var capabilitySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .center, spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("运行状态")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(viewModel.runtimeHintText)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    capabilityBadge(
                        title: viewModel.isRuntimeSupported ? "真机可用" : "模拟器受限",
                        tint: viewModel.isRuntimeSupported ? Color.brand : Color.feedbackWarning
                    )
                }

                HStack(spacing: Spacing.half) {
                    capabilityBadge(
                        title: "来源 \(viewModel.selectedSourceTitle)",
                        tint: Color.brand
                    )
                    capabilityBadge(
                        title: "回填 \(viewModel.selectedTargetTitle)",
                        tint: Color.brandDeep
                    )
                }

                if let statusMessage = viewModel.statusMessage {
                    statusRow(
                        icon: "checkmark.circle.fill",
                        text: statusMessage,
                        color: Color.brand
                    )
                }

                if let errorMessage = viewModel.errorMessage {
                    statusRow(
                        icon: "exclamationmark.triangle.fill",
                        text: errorMessage,
                        color: Color.feedbackWarning
                    )
                }

                Button("清除鉴权缓存") {
                    viewModel.clearAuthorizationCache()
                }
                .buttonStyle(.bordered)
                .tint(Color.brand)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var credentialSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionTitle("凭据")

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    TextField("输入百度 OCR API Key", text: $viewModel.preferences.credentials.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("Secret Key")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    SecureField("输入百度 OCR Secret Key", text: $viewModel.preferences.credentials.secretKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                }

                Text("当前已预置 Android 同源默认 OCR 配置，可直接识别；你在这里的改写只会保存在本机 Debug 环境的 UserDefaults。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var imageSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack {
                    sectionTitle("图片与裁切")
                    Spacer()
                    Button("选择图片") {
                        isSourceDialogPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.brand)
                }

                if let image = viewModel.selectedImage {
                    OCRCropEditor(
                        image: image,
                        normalizedRect: $viewModel.cropRectNormalized,
                        showsGrid: viewModel.preferences.showsCropGrid,
                        onInteractionStateChanged: handleCropInteractionChange
                    )
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))

                    HStack(spacing: Spacing.base) {
                        Button("重置裁切") {
                            withAnimation(.snappy) {
                                viewModel.resetCrop()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.brand)

                        Button {
                            Task {
                                await viewModel.recognizeCurrentSelection()
                            }
                        } label: {
                            if viewModel.isRecognizing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("识别并回填")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.brand)
                        .disabled(!viewModel.canRecognize)
                    }
                } else {
                    VStack(alignment: .center, spacing: Spacing.base) {
                        Image(systemName: "viewfinder.rectangular")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(Color.brand.opacity(0.45))
                        Text("先选择拍照或相册图片，再拖拽裁切区域。")
                            .font(.subheadline)
                            .foregroundStyle(Color.textSecondary)
                        Text("裁切框支持整体拖动与四角缩放，识别时只提交框内区域。")
                            .font(.caption)
                            .foregroundStyle(Color.textHint)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var settingSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionTitle("识别设置")

                Picker("识别语言", selection: $viewModel.preferences.language) {
                    ForEach(OCRLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)

                Toggle("高精度 OCR", isOn: $viewModel.preferences.isHighPrecisionEnabled)
                Toggle("标点优化", isOn: $viewModel.preferences.isPunctuationOptimizationEnabled)
                Toggle("中英混排优化", isOn: $viewModel.preferences.isChineseEnglishSpacingOptimizationEnabled)
                Toggle("显示裁切网格线", isOn: $viewModel.preferences.showsCropGrid)

                Text("高精度切换对齐 Android OCR 设置；标点与中英混排优化会在 SDK 返回后再做文本后处理。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var editorSection: some View {
        VStack(spacing: Spacing.base) {
            editorCard(
                title: "书摘内容",
                placeholder: "聚焦这里后，识别结果会优先回填到书摘内容。",
                text: $viewModel.contentText,
                formats: $viewModel.contentFormats,
                field: .content,
                height: 210
            )

            editorCard(
                title: "想法",
                placeholder: "切换焦点后，识别结果会回填到想法编辑器。",
                text: $viewModel.ideaText,
                formats: $viewModel.ideaFormats,
                field: .idea,
                height: 180
            )

            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    sectionTitle("高亮色板")
                    HighlightColorPicker(selectedARGB: $viewModel.selectedHighlightARGB)
                }
                .padding(Spacing.contentEdge)
            }
        }
    }

    func editorCard(
        title: String,
        placeholder: String,
        text: Binding<NSAttributedString>,
        formats: Binding<Set<RichTextFormat>>,
        field: BaiduOCRTestViewModel.FocusField,
        height: CGFloat
    ) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack {
                    sectionTitle(title)
                    Spacer()
                    capabilityBadge(
                        title: viewModel.focusedField == field ? "当前回填目标" : "点击聚焦切换目标",
                        tint: viewModel.focusedField == field ? Color.brand : Color.textSecondary
                    )
                }

                RichTextEditor(
                    attributedText: text,
                    activeFormats: formats,
                    placeholder: placeholder,
                    isEditable: true,
                    highlightARGB: viewModel.selectedHighlightARGB,
                    allowsCameraTextCapture: true,
                    onFocusChange: { isFocused in
                        viewModel.updateFocus(isFocused: isFocused, field: field)
                    }
                )
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                )
            }
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    var resultSection: some View {
        if let result = viewModel.recognitionResult {
            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    sectionTitle("识别结果")

                    HStack(spacing: Spacing.half) {
                        capabilityBadge(title: "\(result.lineCount) 行", tint: Color.brand)
                        capabilityBadge(title: "\(result.characterCount) 字", tint: Color.brandDeep)
                        if let logID = result.logID, !logID.isEmpty {
                            capabilityBadge(title: "log_id \(logID)", tint: Color.textSecondary)
                        }
                    }

                    Text(result.text)
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.base)
                        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("原始 JSON")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                        Text(result.rawJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.base)
                            .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    }
                }
                .padding(Spacing.contentEdge)
            }
        }
    }

    func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.textPrimary)
    }

    func capabilityBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    func statusRow(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.half) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    func handleCropInteractionChange(_ isActive: Bool) {
        guard isCropInteractionActive != isActive else { return }
        isCropInteractionActive = isActive
    }
}

private struct OCRCropEditor: View {
    enum Handle: CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    let image: UIImage
    @Binding var normalizedRect: CGRect
    let showsGrid: Bool
    let onInteractionStateChanged: (Bool) -> Void

    @State private var dragStartRect: CGRect?
    @State private var isInteractionActive = false
    private let minimumSize: CGFloat = 0.18
    private let handleSize: CGFloat = 16
    private let handleHitSize: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let imageFrame = fittedImageFrame(in: proxy.size, imageSize: image.size)
            let cropFrame = frame(for: normalizedRect, in: imageFrame)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.04)

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                cropMask(imageFrame: imageFrame, cropFrame: cropFrame)

                Color.clear
                    .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    .frame(width: cropFrame.width, height: cropFrame.height)
                    .position(x: cropFrame.midX, y: cropFrame.midY)
                    .highPriorityGesture(moveGesture(within: imageFrame))

                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: cropFrame.width, height: cropFrame.height)
                    .position(x: cropFrame.midX, y: cropFrame.midY)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .allowsHitTesting(false)

                if showsGrid {
                    cropGrid(cropFrame: cropFrame)
                        .allowsHitTesting(false)
                }

                ForEach(Handle.allCases, id: \.self) { handle in
                    Circle()
                        .fill(Color.clear)
                        .frame(width: handleHitSize, height: handleHitSize)
                        .overlay {
                            Circle()
                                .fill(Color.white)
                                .frame(width: handleSize, height: handleSize)
                                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                        }
                        .contentShape(Circle())
                        .position(position(for: handle, in: cropFrame))
                        .highPriorityGesture(resizeGesture(for: handle, within: imageFrame))
                }
            }
        }
        .background(Color.surfacePage)
        .onDisappear {
            finishInteraction()
        }
    }
}

private extension OCRCropEditor {
    func cropMask(imageFrame: CGRect, cropFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: imageFrame.width, height: max(cropFrame.minY - imageFrame.minY, 0))
                .offset(x: imageFrame.minX, y: imageFrame.minY)

            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: imageFrame.width, height: max(imageFrame.maxY - cropFrame.maxY, 0))
                .offset(x: imageFrame.minX, y: cropFrame.maxY)

            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: max(cropFrame.minX - imageFrame.minX, 0), height: cropFrame.height)
                .offset(x: imageFrame.minX, y: cropFrame.minY)

            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(width: max(imageFrame.maxX - cropFrame.maxX, 0), height: cropFrame.height)
                .offset(x: cropFrame.maxX, y: cropFrame.minY)
        }
    }

    func cropGrid(cropFrame: CGRect) -> some View {
        ZStack {
            ForEach([1.0 / 3.0, 2.0 / 3.0], id: \.self) { ratio in
                Path { path in
                    let x = cropFrame.minX + cropFrame.width * ratio
                    path.move(to: CGPoint(x: x, y: cropFrame.minY))
                    path.addLine(to: CGPoint(x: x, y: cropFrame.maxY))
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                Path { path in
                    let y = cropFrame.minY + cropFrame.height * ratio
                    path.move(to: CGPoint(x: cropFrame.minX, y: y))
                    path.addLine(to: CGPoint(x: cropFrame.maxX, y: y))
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    func moveGesture(within imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartRect == nil {
                    dragStartRect = normalizedRect
                    beginInteraction()
                }
                guard let dragStartRect else { return }
                let dx = value.translation.width / imageFrame.width
                let dy = value.translation.height / imageFrame.height
                let newX = min(max(dragStartRect.minX + dx, 0), 1 - dragStartRect.width)
                let newY = min(max(dragStartRect.minY + dy, 0), 1 - dragStartRect.height)
                normalizedRect = CGRect(
                    x: newX,
                    y: newY,
                    width: dragStartRect.width,
                    height: dragStartRect.height
                )
            }
            .onEnded { _ in
                finishInteraction()
            }
    }

    func resizeGesture(for handle: Handle, within imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartRect == nil {
                    dragStartRect = normalizedRect
                    beginInteraction()
                }
                guard let startRect = dragStartRect else { return }
                let dx = value.translation.width / imageFrame.width
                let dy = value.translation.height / imageFrame.height
                normalizedRect = resizedRect(from: startRect, handle: handle, dx: dx, dy: dy)
            }
            .onEnded { _ in
                finishInteraction()
            }
    }

    func beginInteraction() {
        guard !isInteractionActive else { return }
        isInteractionActive = true
        onInteractionStateChanged(true)
    }

    func finishInteraction() {
        dragStartRect = nil
        guard isInteractionActive else { return }
        isInteractionActive = false
        onInteractionStateChanged(false)
    }

    func resizedRect(from startRect: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = startRect.minX
        var minY = startRect.minY
        var maxX = startRect.maxX
        var maxY = startRect.maxY

        switch handle {
        case .topLeft:
            minX = min(max(startRect.minX + dx, 0), startRect.maxX - minimumSize)
            minY = min(max(startRect.minY + dy, 0), startRect.maxY - minimumSize)
        case .topRight:
            maxX = max(min(startRect.maxX + dx, 1), startRect.minX + minimumSize)
            minY = min(max(startRect.minY + dy, 0), startRect.maxY - minimumSize)
        case .bottomLeft:
            minX = min(max(startRect.minX + dx, 0), startRect.maxX - minimumSize)
            maxY = max(min(startRect.maxY + dy, 1), startRect.minY + minimumSize)
        case .bottomRight:
            maxX = max(min(startRect.maxX + dx, 1), startRect.minX + minimumSize)
            maxY = max(min(startRect.maxY + dy, 1), startRect.minY + minimumSize)
        }

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    func fittedImageFrame(in containerSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
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

    func position(for handle: Handle, in cropFrame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .bottomLeft:
            return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomRight:
            return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        }
    }
}

private struct OCRImagePicker: UIViewControllerRepresentable {
    enum Source: String, Identifiable {
        case camera
        case photoLibrary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .camera:
                return "拍照"
            case .photoLibrary:
                return "相册"
            }
        }

        var sourceType: UIImagePickerController.SourceType {
            switch self {
            case .camera:
                return .camera
            case .photoLibrary:
                return .photoLibrary
            }
        }
    }

    let source: Source
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.delegate = context.coordinator
        controller.sourceType = source.sourceType
        controller.modalPresentationStyle = .fullScreen
        controller.allowsEditing = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImagePicked: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImagePicked = onImagePicked
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }
            dismiss()
        }
    }
}

#Preview {
    BaiduOCRTestView()
        .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
#endif
