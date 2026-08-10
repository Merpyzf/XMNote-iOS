/**
 * [INPUT]: 依赖章节移动/排序/批量/远端同步状态，依赖现有 DesignTokens、LoadingGate、XMSystemAlert、OCRRepository 与系统相机/照片入口
 * [OUTPUT]: 对外提供章节移动、排序、手工批量录入与文曲目录选择 Sheet，覆盖选区缩进、预览、文本历史、OCR 追加和写入反馈
 * [POS]: Views/Book/Sheets 的目录管理辅助任务页，由 ChapterManagerView 以 sheet(item:) 展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@preconcurrency import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// 移动目的地选择 Sheet；禁用目标保留可见并解释循环或深度限制。
struct ChapterMoveSheet: View {
    let request: ChapterMoveRequest
    let targets: [ChapterMoveTarget]
    let onSelect: (Int64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var visibleTargets: [ChapterMoveTarget] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return targets }
        return targets.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.pathText.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleTargets.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(visibleTargets) { target in
                        Button {
                            onSelect(target.id)
                        } label: {
                            ChapterMoveTargetRow(target: target)
                        }
                        .buttonStyle(.plain)
                        .disabled(!target.isEnabled)
                        .accessibilityHint(target.disabledReason ?? "移动到此目录末尾")
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索目标目录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 移动目标行，使用路径和禁用原因消除同名章节歧义。
private struct ChapterMoveTargetRow: View {
    let target: ChapterMoveTarget

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: target.isRoot ? "books.vertical" : "folder")
                .foregroundStyle(target.isEnabled ? Color.brand : Color.textHint)
                .frame(width: Spacing.double)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(target.title)
                    .font(AppTypography.body)
                    .foregroundStyle(target.isEnabled ? Color.textPrimary : Color.textHint)
                    .lineLimit(1)

                Text(target.disabledReason ?? target.pathText)
                    .font(AppTypography.caption)
                    .foregroundStyle(target.disabledReason == nil ? Color.textSecondary : Color.textHint)
                    .lineLimit(2)
            }

            Spacer(minLength: Spacing.cozy)

            if target.isEnabled {
                Image(systemName: "chevron.right")
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.textHint)
            }
        }
        .contentShape(Rectangle())
        .padding(.leading, CGFloat(max(0, min(target.level, 4))) * Spacing.compact)
    }
}

/// 同父级排序 Sheet；本地拖动只修改草稿，点击完成后一次性提交完整 ID 顺序。
struct ChapterSiblingOrderSheet: View {
    let request: ChapterSiblingOrderRequest
    let onSave: ([Int64]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftItems: [ChapterManagementItem]

    /// 以打开 Sheet 时的仓储快照建立独立拖动草稿；外部并发变化由提交时的集合校验拦截。
    init(
        request: ChapterSiblingOrderRequest,
        onSave: @escaping ([Int64]) -> Void
    ) {
        self.request = request
        self.onSave = onSave
        _draftItems = State(initialValue: request.siblings)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(draftItems) { item in
                    HStack(spacing: Spacing.base) {
                        Image(systemName: item.isStarred ? "star.fill" : "line.3.horizontal")
                            .foregroundStyle(item.isStarred ? Color.ratingActive : Color.textHint)
                            .frame(width: Spacing.double)

                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(item.displayTitle)
                                .font(AppTypography.body)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            Text("\(item.descendantNoteCount) 条书摘")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .onMove(perform: move)
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(draftItems.map(\.id))
                    }
                    .disabled(draftItems.map(\.id) == request.siblings.map(\.id))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 更新本地排序草稿；成功保存由列表稳定位置表达，不额外弹成功提示。
    private func move(from source: IndexSet, to destination: Int) {
        draftItems.move(fromOffsets: source, toOffset: destination)
    }
}

/// 手工批量目录录入 Sheet；多行编辑、层级预览和 OCR 追加共用同一可撤销全文草稿。
struct ChapterBatchImportSheet: View {
    @Bindable var viewModel: ChapterBatchImportViewModel
    let onComplete: (ChapterBatchImportResult) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var isEditorFocused: Bool
    @State private var textSelection: TextSelection?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isReadingPhoto = false
    @State private var showsCamera = false
    @State private var cameraAlert: ChapterBatchCameraAlert?
    @State private var cameraAuthorizationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Form {
                    inputSection
                    editingToolsSection
                    previewSection
                }
                .scrollContentBackground(.hidden)
                .background(Color.surfacePage)
                .scrollDismissesKeyboard(.interactively)

                if isBusy {
                    LoadingStateView(
                        busyTitle,
                        style: .card
                    )
                    .padding(.top, Spacing.cozy)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .navigationTitle("批量录入目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy)
        .task(id: selectedPhotoItem) {
            await consumeSelectedPhoto()
        }
        .fullScreenCover(isPresented: $showsCamera) {
            ChapterBatchCameraPicker(onComplete: handleCameraResult)
                .ignoresSafeArea()
        }
        .xmSystemAlert(
            isPresented: operationErrorBinding,
            descriptor: operationErrorDescriptor
        )
        .xmSystemAlert(item: $cameraAlert, descriptor: cameraAlertDescriptor)
        .onChange(of: viewModel.importResult) { _, result in
            guard let result else { return }
            onComplete(result)
            dismiss()
        }
        .onDisappear {
            cameraAuthorizationTask?.cancel()
            cameraAuthorizationTask = nil
            viewModel.cancelPendingWork()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: viewModel.previewEntries.map(\.id)
        )
    }
}

private extension ChapterBatchImportSheet {
    var isBusy: Bool {
        isReadingPhoto || viewModel.isBusy
    }

    var busyTitle: String {
        if isReadingPhoto { return "正在读取照片…" }
        return viewModel.isRecognizing ? "正在识别目录…" : "正在导入目录…"
    }

    var inputSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                TextEditor(text: textBinding, selection: $textSelection)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .focused($isEditorFocused)
                    .frame(minHeight: 220)
                    .disabled(isBusy)

                if viewModel.text.isEmpty {
                    Text(placeholderText)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textHint)
                        .padding(.horizontal, Spacing.compact)
                        .padding(.vertical, Spacing.tight)
                        .allowsHitTesting(false)
                }
            }
        } header: {
            Text("每行一个章节")
                .font(AppTypography.caption)
        } footer: {
            Text("行首每两个全角或半角空格、一个 Tab 代表一级缩进，最多支持 \(ChapterManagementPolicy.maximumDepth) 级。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    var editingToolsSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.cozy) {
                    historyControls
                    indentButton
                    periodMenu
                    cameraButton
                    photoPicker
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        } footer: {
            Text("照片或拍照识别的文本会追加到当前草稿，并可直接撤销。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    @ViewBuilder
    var previewSection: some View {
        Section {
            if let parseErrorMessage = viewModel.parseErrorMessage {
                Label {
                    Text(parseErrorMessage)
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.textSecondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.feedbackWarning)
                }
                .transition(.opacity)
            } else if viewModel.previewEntries.isEmpty {
                Text("输入目录后会在这里预览层级和顺序。")
                    .font(AppTypography.callout)
                    .foregroundStyle(Color.textHint)
            } else {
                ForEach(viewModel.previewEntries) { entry in
                    ChapterBatchPreviewRow(entry: entry)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        } header: {
            HStack {
                Text("目录预览")
                    .font(AppTypography.caption)
                Spacer(minLength: Spacing.compact)
                if let draft = viewModel.draft {
                    Text("\(draft.rootCount) 个一级 · \(draft.entries.count) 个章节")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    @ViewBuilder
    var historyControls: some View {
        Button(action: viewModel.undoTextChange) {
            Label("撤销", systemImage: "arrow.uturn.backward")
                .font(AppTypography.subheadline)
                .frame(minHeight: 44)
        }
        .disabled(!viewModel.canUndo || isReadingPhoto)

        Button(action: viewModel.redoTextChange) {
            Label("重做", systemImage: "arrow.uturn.forward")
                .font(AppTypography.subheadline)
                .frame(minHeight: 44)
        }
        .disabled(!viewModel.canRedo || isReadingPhoto)
    }

    var periodMenu: some View {
        Menu {
            Button("统一为中文句点", systemImage: "textformat") {
                viewModel.normalizeToChinesePeriods()
            }
            Button("统一为英文句点", systemImage: "textformat") {
                viewModel.normalizeToEnglishPeriods()
            }
        } label: {
            Label("句点", systemImage: "arrow.left.arrow.right")
                .font(AppTypography.subheadline)
                .frame(minHeight: 44)
        }
        .disabled(viewModel.text.isEmpty || isBusy)
    }

    var indentButton: some View {
        Button(action: increaseSelectedIndent) {
            Label("增加层级", systemImage: "increase.indent")
                .font(AppTypography.subheadline)
                .frame(minHeight: 44)
        }
        .disabled(viewModel.text.isEmpty || isBusy)
    }

    var cameraButton: some View {
        Button(action: requestCameraPresentation) {
            Label("拍照识字", systemImage: "camera.viewfinder")
                .font(AppTypography.subheadline)
                .frame(minHeight: 44)
        }
        .disabled(isBusy)
    }

    var photoPicker: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("照片识字", systemImage: "photo.badge.magnifyingglass")
                .font(AppTypography.subheadline)
                .frame(minHeight: 44)
        }
        .disabled(isBusy)
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
                .disabled(isBusy)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("导入", action: viewModel.importChapters)
                .disabled(!viewModel.canImport || isReadingPhoto)
        }
    }

    var textBinding: Binding<String> {
        Binding(
            get: { viewModel.text },
            set: viewModel.replaceText
        )
    }

    var placeholderText: String {
        [
            "第一章",
            "\(ChapterBatchImportParser.indentUnit)1.1 小节",
            "\(String(repeating: ChapterBatchImportParser.indentUnit, count: 2))1.1.1 主题",
            "第二章"
        ].joined(separator: "\n")
    }

    var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented { viewModel.consumeOperationError() }
            }
        )
    }

    var operationErrorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.operationErrorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "操作未完成",
            message: message,
            actions: [
                XMSystemAlertAction(title: "好", role: .cancel) {
                    viewModel.consumeOperationError()
                }
            ]
        )
    }

    /// 将 SwiftUI 原生选区转为 Android EditText 同口径的 UTF-16 范围，完成缩进后恢复光标与聚焦。
    func increaseSelectedIndent() {
        let sourceText = viewModel.text
        let selectedRange: NSRange
        if let textSelection {
            switch textSelection.indices {
            case .selection(let range):
                selectedRange = NSRange(range, in: sourceText)
            case .multiSelection:
                // 批量解析器返回单个连续 UTF-16 选区；多段选区改为全文操作，避免丢失未能恢复的选区段。
                selectedRange = NSRange(location: 0, length: (sourceText as NSString).length)
            @unknown default:
                selectedRange = NSRange(location: (sourceText as NSString).length, length: 0)
            }
        } else {
            selectedRange = NSRange(location: (sourceText as NSString).length, length: 0)
        }
        guard let result = viewModel.increaseIndent(
            selectionLocation: selectedRange.location,
            selectionLength: selectedRange.length
        ) else {
            return
        }
        let updatedRange = NSRange(
            location: result.selectionLocation,
            length: result.selectionLength
        )
        if let range = Range(updatedRange, in: result.text) {
            textSelection = TextSelection(range: range)
        }
        isEditorFocused = true
    }

    /// 相册数据只在内存中交给 OCRRepository；取消或离场后不再追加迟到结果。
    func consumeSelectedPhoto() async {
        guard let selectedPhotoItem else { return }
        isReadingPhoto = true
        defer {
            isReadingPhoto = false
            self.selectedPhotoItem = nil
        }
        do {
            guard !Task.isCancelled,
                  let data = try await selectedPhotoItem.loadTransferable(type: Data.self) else {
                return
            }
            guard !Task.isCancelled else { return }
            viewModel.recognizeAndAppend(imageData: data)
        } catch {
            guard !Task.isCancelled else { return }
            viewModel.presentOperationError("读取照片失败：\(error.localizedDescription)")
        }
    }

    /// 拍照入口复用项目既有权限分层；只有硬件与授权均可用时才呈现系统相机。
    func requestCameraPresentation() {
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

    /// 将系统相机结果转换为 OCR 输入；用户取消保持安静，处理失败给出可行动反馈。
    func handleCameraResult(_ result: ChapterBatchCameraResult) {
        showsCamera = false
        switch result {
        case .captured(let data):
            viewModel.recognizeAndAppend(imageData: data)
        case .cancelled:
            break
        case .processingFailed:
            cameraAlert = .processingFailed
        }
    }

    /// 把相机权限回调桥接为可取消任务结果；页面离场后调用方会忽略迟到值。
    nonisolated static func requestCameraAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { isGranted in
                continuation.resume(returning: isGranted)
            }
        }
    }

    /// 以项目标准系统弹窗解释相机异常，明确保留“照片识字”替代路径。
    func cameraAlertDescriptor(_ alert: ChapterBatchCameraAlert) -> XMSystemAlertDescriptor {
        switch alert {
        case .unavailable:
            return XMSystemAlertDescriptor(
                title: "当前无法拍照",
                message: "未检测到可用相机，你仍可从照片中识别目录。",
                actions: [XMSystemAlertAction(title: "知道了", role: .cancel) { }]
            )
        case .denied:
            return XMSystemAlertDescriptor(
                title: "需要相机权限",
                message: "请在系统设置中允许“纸间书摘”使用相机，然后返回继续识别目录。",
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
                message: "当前设备策略限制了相机访问，你仍可从照片中识别目录。",
                actions: [XMSystemAlertAction(title: "知道了", role: .cancel) { }]
            )
        case .processingFailed:
            return XMSystemAlertDescriptor(
                title: "照片处理失败",
                message: "没有获得可识别的照片数据，请重新拍摄或改从照片选择。",
                actions: [XMSystemAlertAction(title: "知道了", role: .cancel) { }]
            )
        }
    }
}

/// 目录预览行沿用管理页的真实层级缩进，不引入独立卡片或视觉语言。
private struct ChapterBatchPreviewRow: View {
    let entry: ChapterBatchImportEntry

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Text("\(entry.level)")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textSecondary)
                .frame(width: Spacing.double, height: Spacing.double)
                .background(Color.surfaceNested, in: Circle())

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(entry.title)
                    .font(entry.level == 1 ? AppTypography.bodyMedium : AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                Text("第 \(entry.sourceLineNumber) 行 · 同级第 \(entry.siblingOrder) 项")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(.leading, CGFloat(max(0, entry.level - 1)) * Spacing.base)
        .accessibilityElement(children: .combine)
    }
}

/// 批量目录相机异常状态，以稳定 ID 驱动 XMSystemAlert。
private enum ChapterBatchCameraAlert: String, Identifiable {
    case unavailable
    case denied
    case restricted
    case processingFailed

    var id: String { rawValue }
}

/// 系统相机结果明确区分取消与处理失败，避免把取消误报成异常。
private enum ChapterBatchCameraResult {
    case captured(Data)
    case cancelled
    case processingFailed
}

/// 章节批量录入页面私有的系统相机桥接，只回传内存 JPEG 数据。
private struct ChapterBatchCameraPicker: UIViewControllerRepresentable {
    let onComplete: (ChapterBatchCameraResult) -> Void

    /// 建立系统全屏相机并启用原生裁剪，目录识别无需维护自定义相机状态机。
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

    /// 系统相机由 UIKit 自身维护状态，SwiftUI 更新无需重复配置控制器。
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    /// 创建只负责一次结果桥接的 delegate 协调器。
    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    /// 视图拆除时先解除 delegate，避免 UIKit 在页面离场后继续回调旧 Sheet。
    static func dismantleUIViewController(
        _ uiViewController: UIImagePickerController,
        coordinator: Coordinator
    ) {
        uiViewController.delegate = nil
    }

    /// UIKit delegate 仅完成一次结果回传，不持久化图片也不直接访问 OCR 网络。
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onComplete: (ChapterBatchCameraResult) -> Void
        private var hasCompleted = false

        /// 注入一次性结果回调；实际 OCR 仍由 ViewModel 经 Repository 发起。
        init(onComplete: @escaping (ChapterBatchCameraResult) -> Void) {
            self.onComplete = onComplete
        }

        /// 用户取消拍照时回传安静结束语义。
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completeOnce(.cancelled)
        }

        /// 优先读取裁剪图并编码内存 JPEG；失败时返回可行动错误语义。
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9) else {
                completeOnce(.processingFailed)
                return
            }
            completeOnce(.captured(data))
        }

        /// 保护 delegate 的取消/完成竞态，确保宿主只消费一次结果。
        private func completeOnce(_ result: ChapterBatchCameraResult) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onComplete(result)
        }
    }
}

/// 文曲目录同步业务 Sheet；候选选择、目录预览与导入写反馈都保留在当前辅助任务内。
struct ChapterRemoteSyncSheet: View {
    @Bindable var viewModel: ChapterRemoteSyncViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadingGate = LoadingGate()

    private var visibleCandidates: [ChapterRemoteCatalogCandidate] {
        let keyword = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return viewModel.candidates }
        return viewModel.candidates.filter { candidate in
            candidate.title.localizedCaseInsensitiveContains(keyword)
                || candidate.author.localizedCaseInsensitiveContains(keyword)
                || candidate.press.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                phaseContent
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))

                if viewModel.isImporting {
                    LoadingStateView("正在导入目录…", style: .card)
                        .padding(.top, Spacing.cozy)
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.updatesFrequently)
                        .transition(.opacity)
                        .zIndex(2)
                }
            }
            .background(Color.surfacePage)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.searchText, prompt: searchPrompt)
            .toolbar { toolbarContent }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(viewModel.isImporting)
        .xmSystemAlert(
            isPresented: importErrorBinding,
            descriptor: importErrorDescriptor
        )
        .onAppear(perform: syncLoadingGate)
        .onChange(of: viewModel.phase) { _, _ in syncLoadingGate() }
        .onChange(of: viewModel.isCompleted) { _, isCompleted in
            if isCompleted { dismiss() }
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: viewModel.phase
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.18),
            value: viewModel.selectedItemIDs
        )
    }

    private var navigationTitle: String {
        switch viewModel.phase {
        case .candidates:
            return "选择匹配书籍"
        case .catalog, .empty:
            return viewModel.selectedCandidate?.title.nonEmpty ?? "远端目录"
        case .loading, .error:
            return "远端目录"
        }
    }

    private var searchPrompt: String {
        viewModel.phase == .candidates ? "筛选候选书籍" : "筛选目录"
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .loading:
            if loadingGate.isVisible {
                LoadingStateView("正在获取远端目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        case .candidates:
            candidateList
        case .catalog:
            catalogList
        case .empty(let message):
            unavailableContent(
                title: viewModel.selectedCandidate == nil ? "未找到目录" : "暂无目录",
                message: message,
                systemImage: "list.bullet.indent"
            )
        case .error(let message):
            unavailableContent(
                title: "目录暂时无法获取",
                message: message,
                systemImage: "exclamationmark.triangle"
            )
        }
    }

    private var candidateList: some View {
        List {
            configurationSection
            Section {
                if visibleCandidates.isEmpty {
                    ContentUnavailableView.search(text: viewModel.searchText)
                } else {
                    ForEach(visibleCandidates) { candidate in
                        Button {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                                viewModel.selectCandidate(candidate)
                            }
                        } label: {
                            ChapterRemoteCandidateRow(candidate: candidate)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("请选择与“\(viewModel.discovery?.bookTitle ?? "当前书籍")”对应的版本")
                    .font(AppTypography.caption)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var catalogList: some View {
        List {
            if viewModel.canReturnToCandidates {
                Section {
                    Button("重新选择匹配书籍", systemImage: "chevron.backward") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            viewModel.returnToCandidates()
                        }
                    }
                    .font(AppTypography.callout)
                }
            }

            configurationSection

            Section {
                Button(viewModel.isAllSelected ? "取消全选" : "全选") {
                    viewModel.toggleSelectAll()
                }
                .font(AppTypography.callout)
                .disabled(viewModel.isImporting)
            } header: {
                Text("已选 \(viewModel.selectedCount) / \(viewModel.catalogItems.count)")
                    .font(AppTypography.caption)
            }

            Section {
                if viewModel.visibleCatalogItems.isEmpty {
                    ContentUnavailableView.search(text: viewModel.searchText)
                } else {
                    ForEach(viewModel.visibleCatalogItems) { item in
                        Button {
                            viewModel.toggleItem(item.id)
                        } label: {
                            HStack(spacing: Spacing.base) {
                                Image(systemName: viewModel.selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        viewModel.selectedItemIDs.contains(item.id)
                                            ? Color.brand
                                            : Color.textHint
                                    )
                                    .frame(width: Spacing.double)

                                Text(item.title)
                                    .font(AppTypography.body)
                                    .foregroundStyle(Color.textPrimary)
                                    .multilineTextAlignment(.leading)

                                Spacer(minLength: Spacing.cozy)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isImporting)
                        .accessibilityLabel(item.title)
                        .accessibilityValue(viewModel.selectedItemIDs.contains(item.id) ? "已选择" : "未选择")
                    }
                }
            } header: {
                Text("目录预览")
                    .font(AppTypography.caption)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var configurationSection: some View {
        if viewModel.configurationState == .unavailable {
            Section {
                Label {
                    Text("部分扩展配置暂不可用，不影响本次目录查询。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.textHint)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func unavailableContent(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if viewModel.canReturnToCandidates {
                Button("返回候选书籍", action: viewModel.returnToCandidates)
                    .buttonStyle(.bordered)
            } else {
                Button("重新获取", action: viewModel.load)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { dismiss() }
                .disabled(viewModel.isImporting)
        }

        if viewModel.phase == .catalog {
            ToolbarItem(placement: .confirmationAction) {
                Button("导入") { viewModel.importSelected() }
                    .disabled(viewModel.selectedItemIDs.isEmpty || viewModel.isImporting)
            }
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.phase == .loading ? .read : .none)
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.importErrorMessage != nil },
            set: { isPresented in
                if !isPresented { viewModel.consumeImportError() }
            }
        )
    }

    private var importErrorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.importErrorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "目录未导入",
            message: message,
            actions: [
                XMSystemAlertAction(title: "好", role: .cancel) {
                    viewModel.consumeImportError()
                }
            ]
        )
    }
}

/// 文曲候选书籍行，复用现有列表层级展示版本信息与可导入目录数量。
private struct ChapterRemoteCandidateRow: View {
    let candidate: ChapterRemoteCatalogCandidate

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "book.closed")
                .foregroundStyle(Color.brand)
                .frame(width: Spacing.double)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(candidate.title.nonEmpty ?? "未命名书籍")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(candidate.subtitle.nonEmpty ?? "暂无作者与出版社信息")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: Spacing.cozy)

            Text("\(candidate.catalogTitles.count) 章")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)

            Image(systemName: "chevron.forward")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textHint)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    /// 返回 trim 后的非空字符串，供远端可选字段在页面层采用语义化兜底。
    var nonEmpty: String? {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
