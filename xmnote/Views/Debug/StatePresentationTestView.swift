#if DEBUG
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖公共状态目录与 OCR/AI/附件/导入业务展示单元，接收测试人员选择的外观、字号、宽度和 Reduce Motion 配置
 * [OUTPUT]: 对外提供 StatePresentationTestView，集中展示真实生产状态及其公共或业务专用实现
 * [POS]: Views/Debug 的生产状态验收页，仅存在于 DEBUG 构建，不进入生产导航
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 生产状态测试页把验收控制限制在目录区域，避免改变测试中心自身环境。
struct StatePresentationTestView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var selectedAppearance: StatePresentationTestAppearance = .system
    @State private var selectedTextSize: StatePresentationTestTextSize = .standard
    @State private var selectedPreviewWidth: StatePresentationTestWidth = .current
    @State private var forcesReduceMotion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                controls
                previewRegion
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .scrollBounceBehavior(.always)
        .background(Color.surfacePage)
        .navigationTitle("状态展示")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controls: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text("验收控制")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text("以下设置只作用于生产状态预览，测试中心控制区继续跟随系统")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("外观", selection: $selectedAppearance) {
                    ForEach(StatePresentationTestAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                Picker("字号", selection: $selectedTextSize) {
                    ForEach(StatePresentationTestTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                Picker("预览宽度", selection: $selectedPreviewWidth) {
                    ForEach(StatePresentationTestWidth.allCases) { width in
                        Text(width.title).tag(width)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("模拟 Reduce Motion", isOn: $forcesReduceMotion)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textPrimary)

                Text(reduceMotionDescription)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var previewRegion: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text("生产状态预览")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text("当前：\(selectedAppearance.title) · \(selectedTextSize.title) · \(selectedPreviewWidth.title) · \(effectiveReduceMotion ? "Reduce Motion" : "标准动效")")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .dynamicTypeSize(.large)

            StatePresentationCatalogView()
            BusinessStateScenarioCatalogView()
        }
        .frame(maxWidth: selectedPreviewWidth.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.base)
        .background(Color.surfacePage)
        .environment(\.colorScheme, previewColorScheme)
        .environment(\.dynamicTypeSize, selectedTextSize.dynamicTypeSize)
        .transaction { transaction in
            if effectiveReduceMotion {
                transaction.disablesAnimations = true
            }
        }
    }

    private var previewColorScheme: ColorScheme {
        selectedAppearance.colorScheme ?? systemColorScheme
    }

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcesReduceMotion
    }

    private var reduceMotionDescription: String {
        if systemReduceMotion {
            return "系统已开启 Reduce Motion；预览会保持无动画切换"
        }
        return forcesReduceMotion
            ? "预览区域已强制使用无动画状态切换"
            : "预览区域使用组件默认的 0.16 秒淡入淡出"
    }
}

/// 测试页宽度选项覆盖当前容器、紧凑 iPhone 基线和规则宽度上限。
private enum StatePresentationTestWidth: String, CaseIterable, Identifiable {
    case current
    case compact
    case regular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "当前"
        case .compact: "320pt"
        case .regular: "规则"
        }
    }

    var maxWidth: CGFloat? {
        switch self {
        case .current: nil
        case .compact: 320
        case .regular: 600
        }
    }
}

/// 强业务状态目录直接复用生产展示单元，明确这些状态不属于公共 XMStateRole。
private struct BusinessStateScenarioCatalogView: View {
    @State private var markdownInteractionController = AIMarkdownInteractionController()
    @State private var lastActionFeedback = "尚未触发业务状态操作"
    @State private var selectedOCRFixture: OCRUnavailableFixture = .permissionDenied
    @State private var selectedAIFixture: AIGenerationFixture = .waiting

    private let attachmentItems = BusinessStateScenarioFixture.attachmentItems

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text("业务专用状态")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text("这些状态具有领域生命周期或特殊容器，不提升为公共状态角色")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .dynamicTypeSize(.large)

            businessSample(
                title: "OCR 相机不可用",
                production: "书摘图片 OCR · 深色取景器",
                trigger: "相机权限或设备能力不可用，但相册回退仍可用",
                implementation: "OCRCameraUnavailableStateView · 业务专用"
            ) {
                Picker("相机状态", selection: $selectedOCRFixture) {
                    ForEach(OCRUnavailableFixture.allCases) { fixture in
                        Text(fixture.title).tag(fixture)
                    }
                }
                .pickerStyle(.segmented)
                .dynamicTypeSize(.large)

                OCRCameraUnavailableStateView(
                    iconName: selectedOCRFixture.iconName,
                    message: selectedOCRFixture.message
                )
                .frame(height: 240)
                .clipShape(.rect(cornerRadius: CornerRadius.blockLarge))
            }

            businessSample(
                title: "AI 标签生成阶段",
                production: "AI 标签",
                trigger: "等待、流式输出、空结果、完全失败与保留部分结果",
                implementation: "AI 标签生产展示 owner"
            ) {
                Picker("AI 状态", selection: $selectedAIFixture) {
                    ForEach(AIGenerationFixture.allCases) { fixture in
                        Text(fixture.title).tag(fixture)
                    }
                }
                .pickerStyle(.menu)
                .dynamicTypeSize(.large)

                aiFixturePreview
            }

            businessSample(
                title: "附件上传生命周期",
                production: "书摘编辑 · 附图上传条",
                trigger: "同一批附件分别处于上传中、成功和失败",
                implementation: "XMAttachmentUploadStrip · 公共媒体组件"
            ) {
                XMAttachmentUploadStrip(
                    items: attachmentItems,
                    showsRemoveButton: false,
                    accessibilityNamespace: "state_presentation_fixture",
                    onMove: { _, _ in },
                    onRemove: { _ in },
                    onRetry: { _ in lastActionFeedback = "已触发「重试上传」" }
                )
                .frame(height: 84)
            }

            businessSample(
                title: "微信读书批次状态",
                production: "分批导入 · 单批次尾部状态",
                trigger: "确定进度、失败恢复与完成结果",
                implementation: "WereadImportBatchStatusView · 业务专用"
            ) {
                VStack(spacing: Spacing.none) {
                    batchStatusRow("第 1 批", detail: "未开始", status: .notStarted)
                    Divider()
                    batchStatusRow("第 2 批", detail: "加载 48%", status: .loading(percent: 48))
                    Divider()
                    batchStatusRow("第 3 批", detail: "加载失败", status: .failed)
                    Divider()
                    batchStatusRow("第 4 批", detail: "加载完成", status: .success)
                }
            }

            Label(lastActionFeedback, systemImage: "hand.tap")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .dynamicTypeSize(.large)
        }
    }

    @ViewBuilder
    private var aiFixturePreview: some View {
        switch selectedAIFixture {
        case .waiting:
            AIGenerationWaitingView(
                "分析中…",
                accessibilityLabel: "正在分析书摘"
            )
        case .streaming:
            AIMarkdownResultView(
                markdown: "## 建议标签\n\n- 阅读方法\n- 产品设计",
                isStreaming: true,
                interactionController: markdownInteractionController
            )
        case .empty:
            AIAutoTagEmptyStateView {
                lastActionFeedback = "已触发「重新生成」"
            }
        case .fullFailure:
            AIAutoTagGenerationFailureView(
                message: "暂时无法生成标签建议",
                partialContent: nil,
                interactionController: markdownInteractionController,
                onRetry: { lastActionFeedback = "已触发「重新生成」" }
            )
        case .partialFailure:
            AIAutoTagGenerationFailureView(
                message: "生成中断，已保留当前结果",
                partialContent: "## 建议标签\n\n- 阅读方法\n- 产品设计",
                interactionController: markdownInteractionController,
                onRetry: { lastActionFeedback = "已触发「重新生成」" }
            )
        }
    }

    private func businessSample<Content: View>(
        title: String,
        production: String,
        trigger: String,
        implementation: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(title)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                Text("\(production)｜\(trigger)｜\(implementation)")
            }
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(.large)

            content()
            Divider()
        }
    }

    private func batchStatusRow(
        _ title: String,
        detail: String,
        status: WereadImportBatchStatus
    ) -> some View {
        Button {
            lastActionFeedback = "已触发「打开\(title)」"
        } label: {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(title)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textPrimary)
                    Text(detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer(minLength: Spacing.base)
                WereadImportBatchStatusView(status: status)
            }
            .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开该批次的导入结果")
    }
}

/// OCR 目录只切换生产组件已支持的图标与文案，不复制取景器状态 UI。
private enum OCRUnavailableFixture: String, CaseIterable, Identifiable {
    case permissionDenied
    case restricted
    case unavailable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .permissionDenied: "权限关闭"
        case .restricted: "设备受限"
        case .unavailable: "相机不可用"
        }
    }

    var iconName: String {
        switch self {
        case .permissionDenied, .restricted: "camera.fill.badge.xmark"
        case .unavailable: "camera.slash.fill"
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            "相机权限已关闭，请在系统设置中允许 XMNote 使用相机"
        case .restricted:
            "当前设备限制了相机权限，无法进入拍照模式"
        case .unavailable:
            "当前设备没有可用的后置相机"
        }
    }
}

/// AI 目录覆盖从等待到结果恢复的五种视觉阶段，全部直接使用生产展示 owner。
private enum AIGenerationFixture: String, CaseIterable, Identifiable {
    case waiting
    case streaming
    case empty
    case fullFailure
    case partialFailure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waiting: "等待"
        case .streaming: "流式输出"
        case .empty: "空结果"
        case .fullFailure: "完全失败"
        case .partialFailure: "部分失败"
        }
    }
}

/// 附件目录将应用内确定图片落到临时文件，供生产上传条验证状态遮罩在真实明暗像素上的对比度。
private enum BusinessStateScenarioFixture {
    static let attachmentItems: [XMAttachmentUploadItem] = {
        let imagePath = attachmentImagePath
        return [
            XMAttachmentUploadItem(
                id: "state-fixture-uploading",
                localFilePath: imagePath,
                remoteURL: nil,
                uploadState: .uploading
            ),
            XMAttachmentUploadItem(
                id: "state-fixture-success",
                localFilePath: imagePath,
                remoteURL: nil,
                uploadState: .success
            ),
            XMAttachmentUploadItem(
                id: "state-fixture-failed",
                localFilePath: imagePath,
                remoteURL: nil,
                uploadState: .failed
            )
        ]
    }()

    private static let attachmentImagePath: String? = {
        guard let data = UIImage(named: "AppQRCode")?.pngData() else { return nil }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmnote-state-presentation-attachment.png", isDirectory: false)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return fileURL.path
    }()
}

/// 测试页外观选项只覆盖预览子树的 colorScheme 环境。
private enum StatePresentationTestAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "系统"
        case .light:
            "浅色"
        case .dark:
            "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

/// 测试页提供三个有代表性的动态字号档位，覆盖普通与辅助功能排版。
private enum StatePresentationTestTextSize: String, CaseIterable, Identifiable {
    case standard
    case extraLarge
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            "标准"
        case .extraLarge:
            "特大"
        case .accessibility:
            "辅助"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard:
            .large
        case .extraLarge:
            .xxxLarge
        case .accessibility:
            .accessibility3
        }
    }
}

#Preview {
    NavigationStack {
        StatePresentationTestView()
    }
}
#endif
