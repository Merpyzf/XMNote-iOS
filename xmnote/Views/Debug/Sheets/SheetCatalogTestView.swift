#if DEBUG
/**
 * [INPUT]: 依赖 SheetCatalogTestViewModel、SheetPreviewSnapshotRepository、生产 RepositoryContainer、113 个生产目标定义与设计系统令牌
 * [OUTPUT]: 对外提供 SheetCatalogTestView，以常驻一级操作打开真实生产 Sheet，并用可展开二级详情展示逐目标配置、数据与跨端证据
 * [POS]: Views/Debug/Sheets 的 Sheet 生产目录与隔离验收入口，不修改正式数据库、正式偏好或外部服务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

struct SheetCatalogTestView: View {
    let repositories: RepositoryContainer

    @State private var viewModel = SheetCatalogTestViewModel()
    @State private var snapshotController: SheetCatalogSnapshotController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        repositories: RepositoryContainer,
        databaseManager: DatabaseManager
    ) {
        self.repositories = repositories
        _snapshotController = State(
            initialValue: SheetCatalogSnapshotController(databaseManager: databaseManager)
        )
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: Spacing.base)]
        }
        return [GridItem(.adaptive(minimum: 160), spacing: Spacing.base, alignment: .top)]
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.section) {
                SheetCatalogSummaryCard(
                    totalCount: viewModel.callSites.count,
                    targetCount: viewModel.targetCount,
                    productionCount: viewModel.productionCount,
                    debugCount: viewModel.debugCount,
                    hostFileCount: viewModel.hostFileCount,
                    androidBaseline: SheetCatalogTestViewModel.androidBaseline
                )

                SheetCatalogSnapshotCard(controller: snapshotController)

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("迁移前结构分类")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)

                    Text("类型卡保留治理启动时的结构分类与数量，用来追踪迁移覆盖；当前生产样式统一按 Apple 系统标准验收。")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.visibleFamilySummaries.isEmpty {
                    XMContentStateView(
                        role: .noResults,
                        title: "未找到 Sheet 类型",
                        message: "没有与“\(viewModel.normalizedSearchText)”匹配的用途、目标组件、Android 场景或源码路径。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.base) {
                        ForEach(viewModel.visibleFamilySummaries) { summary in
                            NavigationLink {
                                SheetCatalogFamilyDetailView(
                                    family: summary.family,
                                    viewModel: viewModel,
                                    snapshotController: snapshotController
                                )
                            } label: {
                                SheetCatalogFamilyCard(summary: summary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("Sheet 样式校准")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索用途、目标或 Android 场景"
        )
        .task {
            if snapshotController.phase == .idle {
                await snapshotController.refresh()
            }
        }
    }
}

private struct SheetCatalogSnapshotCard: View {
    @Bindable var controller: SheetCatalogSnapshotController

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .center, spacing: Spacing.base) {
                    Label("生产数据快照", systemImage: "externaldrive.badge.checkmark")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)

                    Spacer(minLength: Spacing.compact)

                    Button {
                        Task { await controller.refresh() }
                    } label: {
                        if controller.phase == .loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: controller.snapshot == nil ? "arrow.clockwise" : "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.phase == .loading)
                    .accessibilityLabel(controller.snapshot == nil ? "重试生产快照" : "刷新生产快照")
                }

                switch controller.phase {
                case .idle, .loading:
                    HStack(spacing: Spacing.half) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在复制当前 App 数据…")
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }
                case .failed(let message):
                    XMInlineStatusBanner(message, tone: .warning)
                case .loaded:
                    if let snapshot = controller.snapshot {
                        SheetCatalogFactView(
                            label: "快照时间",
                            value: Self.dateFormatter.string(from: snapshot.createdAt)
                        )
                        SheetCatalogFactView(
                            label: "实际数据数量",
                            value: snapshot.counts.summary
                        )
                        SheetCatalogFactView(
                            label: "偏好与补充",
                            value: "复制 \(snapshot.copiedPreferenceCount) 项非敏感偏好；基础快照补充夹具 \(snapshot.supplementalFixtureCount) 项"
                        )
                    }
                }

                Text("每次打开都会从该快照生成独立数据库与偏好副本；关闭后销毁。AI、在线、备份恢复和远端写入只使用安全模拟。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SheetCatalogSummaryCard: View {
    let totalCount: Int
    let targetCount: Int
    let productionCount: Int
    let debugCount: Int
    let hostFileCount: Int
    let androidBaseline: String

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                        totalTitle
                        Text("·")
                            .foregroundStyle(Color.textHint)
                        Text("\(targetCount) 个目标分支")
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        totalTitle
                        Text("\(targetCount) 个目标分支")
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .monospacedDigit()
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.base) {
                        metric("生产", value: productionCount)
                        metric("Debug", value: debugCount)
                        metric("宿主文件", value: hostFileCount)
                    }

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        metric("生产", value: productionCount)
                        metric("Debug", value: debugCount)
                        metric("宿主文件", value: hostFileCount)
                    }
                }

                Text("不计入：fullScreenCover、fileImporter、PhotosPicker、Alert，以及本校准页自身的代表样例承载。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("生产迁移状态：统一系统工具栏结构已接入；逐目标截图验收进行中", systemImage: "checkmark.seal")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Android 类比基线：\(androidBaseline)。仅表示最相近的业务任务，不代表两端容器、视觉或交互完全一致。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
        .accessibilityElement(children: .combine)
    }

    private var totalTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
            Text("\(totalCount)")
                .font(AppTypography.largeTitle)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
            Text("个既有 Sheet 调用点")
                .font(AppTypography.headline)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func metric(_ title: String, value: Int) -> some View {
        HStack(spacing: Spacing.compact) {
            Text("\(value)")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
            Text(title)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

private struct SheetCatalogFamilyCard: View {
    let summary: SheetCatalogFamilySummary

    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 184

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .center, spacing: Spacing.cozy) {
                Image(systemName: summary.family.systemImage)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(
                        width: InteractionMetrics.minimumTouchTarget,
                        height: InteractionMetrics.minimumTouchTarget
                    )
                    .background(Color.controlFillSecondary, in: Circle())
                    .accessibilityHidden(true)

                Spacer(minLength: Spacing.compact)

                Text(String(format: "%02d", summary.family.index))
                    .font(AppTypography.caption2Medium)
                    .foregroundStyle(Color.textHint)
                    .monospacedDigit()
            }

            Text(summary.family.shortTitle)
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(summary.family.summary)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.compact)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.half) {
                    countLabel("生产", count: summary.productionCount)
                    countLabel("Debug", count: summary.debugCount)
                }

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    countLabel("生产", count: summary.productionCount)
                    countLabel("Debug", count: summary.debugCount)
                }
            }

            Text("\(summary.targetOwnerCount) 个目标组件")
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textHint)
                .monospacedDigit()
        }
        .padding(Spacing.contentEdge)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(summary.family.title)，生产 \(summary.productionCount) 个，Debug \(summary.debugCount) 个，\(summary.targetOwnerCount) 个目标组件。\(summary.family.summary)"
        )
        .accessibilityHint("打开调用点详情")
    }

    private func countLabel(_ title: String, count: Int) -> some View {
        Text("\(title) \(count)")
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textSecondary)
            .monospacedDigit()
    }
}

private struct SheetCatalogFamilyDetailView: View {
    let family: SheetCatalogFamily
    @Bindable var viewModel: SheetCatalogTestViewModel
    @Bindable var snapshotController: SheetCatalogSnapshotController
    @State private var expansionMode = SheetCatalogExpansionMode.smoothPrototype
    @State private var expandedTargetIDs: Set<String> = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Label(family.title, systemImage: family.systemImage)
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)

                    SheetCatalogFactView(
                        label: "迁移前结构",
                        value: family.summary,
                        valueFont: AppTypography.subheadline,
                        valueColor: Color.textSecondary
                    )

                    SheetCatalogFactView(
                        label: "当前生产状态",
                        value: family == .systemControllerBridge
                            ? "继续由系统控制器完整持有外观与操作。"
                            : "已统一接入 NavigationStack、系统 Toolbar 与按任务语义配置的顶部操作。",
                        valueFont: AppTypography.footnote,
                        valueColor: Color.textSecondary
                    )

                    SheetCatalogFactView(
                        label: "校准验收方向",
                        value: family.appleCalibrationGuidance,
                        valueFont: AppTypography.footnote,
                        valueColor: Color.textSecondary
                    )

                    Text("历史九类只用于定位结构来源；以下每个生产目标均以该调用点的生产 View、生产配置和隔离数据单独打开，不再提供通用外壳样例。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.compact)
            }

            Section("实现详情展开实证") {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Picker("实现详情展开方式", selection: $expansionMode) {
                        ForEach(SheetCatalogExpansionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(expansionMode.explanation)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.compact)
            }

            if viewModel.hasVisibleCallSites(for: family) {
                ForEach(SheetCatalogOrigin.allCases) { origin in
                    let sites = viewModel.callSites(for: family, origin: origin)
                    if !sites.isEmpty {
                        Section("\(origin.rawValue) · \(sites.count)") {
                            ForEach(sites) { site in
                                SheetCatalogCallSiteRow(
                                    site: site,
                                    expansionMode: expansionMode,
                                    expandedTargetIDs: $expandedTargetIDs,
                                    viewModel: viewModel,
                                    snapshotController: snapshotController
                                )
                            }
                        }
                    }
                }
            } else {
                Section {
                    XMContentStateView(
                        role: .noResults,
                        title: "未找到调用点",
                        message: "没有与“\(viewModel.normalizedSearchText)”匹配的用途、目标组件、Android 场景或源码路径。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.surfacePage)
        .navigationTitle(family.shortTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索用途、目标或 Android 场景"
        )
        .sheet(item: $viewModel.presentedPreview) { request in
            SheetProductionTargetPreviewHost(
                request: request,
                snapshotController: snapshotController
            )
            .onDisappear {
                snapshotController.releaseActiveWorkspace()
            }
        }
    }
}

private enum SheetCatalogExpansionMode: String, CaseIterable, Identifiable {
    case smoothPrototype
    case native

    var id: Self { self }

    var title: String {
        switch self {
        case .smoothPrototype: "平滑基建"
        case .native: "原生"
        }
    }

    var explanation: String {
        switch self {
        case .smoothPrototype:
            "只控制二级实现详情：保持内容固有高度，以裁切方式逐帧改变 List 行高，并让相邻间距沿同一时间线收敛。"
        case .native:
            "只控制二级实现详情：使用绑定版 DisclosureGroup 保留系统默认行为，作为同一数据和展开状态下的对照基线。"
        }
    }
}

private struct SheetCatalogCallSiteRow: View {
    let site: SheetCatalogCallSite
    let expansionMode: SheetCatalogExpansionMode
    @Binding var expandedTargetIDs: Set<String>
    @Bindable var viewModel: SheetCatalogTestViewModel
    @Bindable var snapshotController: SheetCatalogSnapshotController

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(site.host)
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                    Text("\(site.module) · \(site.presentationKind.rawValue)")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer(minLength: Spacing.compact)

                if site.isNested {
                    Text("嵌套")
                        .font(AppTypography.caption2Medium)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            SheetCatalogFactView(
                label: "App 用途",
                value: site.appPurpose,
                valueFont: AppTypography.footnote,
                valueColor: Color.textSecondary
            )

            Text(site.sourceLocation)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textHint)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(site.targets) { target in
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Rectangle()
                        .fill(Color.surfaceDividerSubtle)
                        .frame(height: StrokeWidth.hairline)
                        .accessibilityHidden(true)

                    SheetCatalogTargetFactsView(
                        target: target,
                        snapshot: snapshotController.snapshot,
                        previewActionState: SheetCatalogPreviewActionState(
                            phase: snapshotController.phase
                        ),
                        expansionMode: expansionMode,
                        isExpanded: expansionBinding(for: target.id),
                        onOpen: { viewModel.presentPreview(for: target) }
                    )
                }
            }
        }
        .padding(.vertical, Spacing.compact)
        .accessibilityElement(children: .contain)
    }

    private func expansionBinding(for targetID: String) -> Binding<Bool> {
        Binding(
            get: { expandedTargetIDs.contains(targetID) },
            set: { isExpanded in
                if isExpanded {
                    expandedTargetIDs.insert(targetID)
                } else {
                    expandedTargetIDs.remove(targetID)
                }
            }
        )
    }
}

private struct SheetCatalogTargetFactsView: View {
    let target: SheetCatalogTarget
    let snapshot: SheetPreviewSnapshot?
    let previewActionState: SheetCatalogPreviewActionState
    let expansionMode: SheetCatalogExpansionMode
    @Binding var isExpanded: Bool
    let onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            SheetCatalogTargetPrimaryRow(
                target: target,
                snapshot: snapshot,
                previewActionState: previewActionState,
                onOpen: onOpen
            )

            switch expansionMode {
            case .native:
                DisclosureGroup(isExpanded: $isExpanded) {
                    targetDetails
                        .padding(.top, Spacing.half)
                } label: {
                    HStack(spacing: Spacing.compact) {
                        Text("实现详情")
                            .font(AppTypography.footnoteMedium)
                            .foregroundStyle(Color.textSecondary)

                        Spacer(minLength: 0)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: InteractionMetrics.minimumTouchTarget,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(target.owner) 实现详情")
                    .accessibilityValue(isExpanded ? "已展开" : "已收起")
                    .accessibilityHint(disclosureHint)
                }

            case .smoothPrototype:
                CollapseAwareVStackPrototype(alignment: .leading, spacing: Spacing.half) {
                    Button(action: toggleExpansion) {
                        HStack(alignment: .center, spacing: Spacing.half) {
                            Image(systemName: "chevron.right")
                                .font(AppTypography.caption2Semibold)
                                .foregroundStyle(Color.textHint)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .animation(structuralAnimation, value: isExpanded)
                                .accessibilityHidden(true)

                            Text("实现详情")
                                .font(AppTypography.footnoteMedium)
                                .foregroundStyle(Color.textSecondary)

                            Spacer(minLength: Spacing.compact)
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: InteractionMetrics.minimumTouchTarget,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(target.owner) 实现详情")
                    .accessibilityValue(isExpanded ? "已展开" : "已收起")
                    .accessibilityHint(disclosureHint)

                    AnimatedPresencePrototype(
                        isPresented: isExpanded,
                        animation: structuralAnimation,
                        contentTransition: .opacity
                    ) {
                        targetDetails
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var targetDetails: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if let preview = target.productionPreview {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("生产数据与界面")
                        .font(AppTypography.caption2Medium)
                        .foregroundStyle(Color.textHint)

                    SheetCatalogFactView(label: "生产数据来源", value: preview.dataSource)
                    SheetCatalogFactView(
                        label: "本次实际数据",
                        value: snapshot.map { preview.actualDataDescription(in: $0) } ?? "生产快照准备中"
                    )
                    SheetCatalogFactView(
                        label: "数据模式",
                        value: snapshot.map { preview.dataMode(for: $0).rawValue } ?? "等待快照"
                    )
                    SheetCatalogFactView(label: "生产调用配置", value: preview.productionConfiguration)
                    SheetCatalogFactView(label: "当前界面结构", value: preview.currentStructure)
                }
            }

            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("当前 iOS 呈现")
                    .font(AppTypography.caption2Medium)
                    .foregroundStyle(Color.textHint)

                SheetCatalogFactView(label: "Detent", value: target.facts.detents)
                SheetCatalogFactView(label: "拖拽指示器", value: target.facts.dragIndicator)
                SheetCatalogFactView(label: "背景", value: target.facts.background)
                SheetCatalogFactView(label: "背景交互", value: target.facts.backgroundInteraction)
                SheetCatalogFactView(label: "内容交互", value: target.facts.contentInteraction)
                SheetCatalogFactView(label: "操作位置", value: target.facts.actionPlacement)
                SheetCatalogFactView(label: "交互收起锁定", value: target.facts.interactiveDismissal)
            }

            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("Android 对照")
                    .font(AppTypography.caption2Medium)
                    .foregroundStyle(Color.textHint)

                SheetCatalogFactView(
                    label: "最相近 Android 场景",
                    value: target.androidAnalogue.scene
                )

                ForEach(target.androidAnalogue.references, id: \.self) { reference in
                    SheetCatalogAndroidReferenceView(reference: reference)
                }
            }
        }
    }

    private var disclosureHint: String {
        if isExpanded {
            return "收起详情"
        }

        return target.productionPreview == nil
            ? "展开查看 iOS 呈现与 Android 对照"
            : "展开查看生产数据、iOS 呈现与 Android 对照"
    }

    private var structuralAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28)
    }

    private func toggleExpansion() {
        isExpanded.toggle()
    }
}

private struct SheetCatalogTargetPrimaryRow: View {
    let target: SheetCatalogTarget
    let snapshot: SheetPreviewSnapshot?
    let previewActionState: SheetCatalogPreviewActionState
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if target.productionPreview != nil {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    targetSummary
                    openButton
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.base) {
                    targetSummary

                    Spacer(minLength: Spacing.compact)

                    openButton
                }
            }
        } else {
            targetSummary
        }
    }

    private var targetSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(target.owner)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(target.sheetPurpose)
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let previewStatusText {
                Text(previewStatusText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var openButton: some View {
        Button(action: onOpen) {
            Label(previewActionState.title, systemImage: previewActionState.systemImage)
                .font(AppTypography.subheadlineMedium)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Color.textPrimary)
        .disabled(!previewActionState.isEnabled)
        .xmMinimumHitTarget(
            anchor: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing
        )
        .accessibilityLabel("打开 \(target.owner) 生产 Sheet")
        .accessibilityValue(previewActionState.accessibilityValue)
        .accessibilityHint(previewActionState.accessibilityHint)
    }

    private var previewStatusText: String? {
        guard let preview = target.productionPreview else { return nil }

        switch previewActionState {
        case .available:
            guard let snapshot else { return "预览数据 · 生产快照可用" }
            return "预览数据 · \(preview.dataMode(for: snapshot).rawValue)"
        case .preparing:
            return "预览数据 · 生产快照准备中"
        case .unavailable:
            return "预览数据 · 生产快照不可用"
        }
    }
}

private enum SheetCatalogPreviewActionState: Equatable {
    case preparing
    case available
    case unavailable

    init(phase: SheetCatalogSnapshotPhase) {
        switch phase {
        case .idle, .loading:
            self = .preparing
        case .loaded:
            self = .available
        case .failed:
            self = .unavailable
        }
    }

    var title: String {
        switch self {
        case .preparing: "准备中"
        case .available: "打开"
        case .unavailable: "不可用"
        }
    }

    var systemImage: String {
        switch self {
        case .preparing: "clock"
        case .available: "rectangle.portrait.and.arrow.forward"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    var isEnabled: Bool {
        self == .available
    }

    var accessibilityValue: String {
        switch self {
        case .preparing: "生产快照准备中"
        case .available: "可以打开"
        case .unavailable: "生产快照不可用"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .preparing:
            "生产快照准备完成后可打开"
        case .available:
            "从隔离生产数据副本打开，不会修改正式数据"
        case .unavailable:
            "请先在页面顶部重试生产快照"
        }
    }
}

private struct SheetCatalogAndroidReferenceView: View {
    let reference: SheetCatalogAndroidReference

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.micro) {
            Text("\(reference.role.rawValue) · \(reference.owner)")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(reference.sourceLocation)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textHint)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SheetCatalogFactView: View {
    let label: String
    let value: String
    var valueFont: Font = AppTypography.caption
    var valueColor: Color = Color.textSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.micro) {
            Text(label)
                .font(AppTypography.caption2Medium)
                .foregroundStyle(Color.textHint)
            Text(value)
                .font(valueFont)
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SheetCatalogRepresentativeSheet: View {
    let family: SheetCatalogFamily

    var body: some View {
        SheetCatalogAppleStandardRepresentativeSheet(family: family)
    }
}

private struct SheetCatalogAppleStandardRepresentativeSheet: View {
    private enum ConfirmationPresentation: Equatable {
        case none
        case checkmark
        case text(String)
    }

    let family: SheetCatalogFamily

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var selectedIDs: Set<Int> = [1, 3]
    @State private var isConfirming = false
    @State private var confirmationTask: Task<Void, Never>?

    private let items = SheetCatalogSampleItem.samples

    private var filteredItems: [SheetCatalogSampleItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.subtitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var showsSearch: Bool {
        switch family {
        case .scaffoldTopControl,
             .scaffoldTopAndBottom,
             .scaffoldDynamicSubtitle,
             .nativeToolbar,
             .customBusinessShell:
            true
        case .scaffoldClose,
             .scaffoldPairedActions,
             .scaffoldBottomAction,
             .systemControllerBridge:
            false
        }
    }

    private var showsSelectionSummary: Bool {
        switch family {
        case .scaffoldTopAndBottom,
             .scaffoldDynamicSubtitle,
             .nativeToolbar,
             .customBusinessShell:
            true
        case .scaffoldClose,
             .scaffoldPairedActions,
             .scaffoldBottomAction,
             .scaffoldTopControl,
             .systemControllerBridge:
            false
        }
    }

    private var confirmationPresentation: ConfirmationPresentation {
        switch family {
        case .scaffoldClose, .scaffoldTopControl, .systemControllerBridge:
            .none
        case .scaffoldPairedActions:
            .text("确认")
        case .scaffoldBottomAction:
            .text("保存")
        case .scaffoldTopAndBottom,
             .scaffoldDynamicSubtitle,
             .nativeToolbar,
             .customBusinessShell:
            .checkmark
        }
    }

    private var hasTopBar: Bool {
        showsSearch || showsSelectionSummary
    }

    var body: some View {
        NavigationStack {
            appleChrome
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.surfaceSheet.ignoresSafeArea())
                .navigationTitle(family.shortTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    appleToolbar
                }
        }
        .interactiveDismissDisabled(isConfirming)
        .onDisappear {
            confirmationTask?.cancel()
            confirmationTask = nil
        }
    }

    @ViewBuilder
    private var appleChrome: some View {
        if hasTopBar {
            XMScrollEdgeChrome(
                presentation: .overlaySoft,
                edges: [.top, .bottom],
                topBar: { contentTopBar },
                bottomBar: { bottomEdgeBar }
            ) {
                resultsList
            }
        } else {
            XMScrollEdgeChrome(
                presentation: .overlaySoft,
                edges: .bottom,
                bottomBar: { bottomEdgeBar }
            ) {
                resultsList
            }
        }
    }

    @ToolbarContentBuilder
    private var appleToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .tint(Color.textSecondary)
                .disabled(isConfirming)
                .accessibilityIdentifier("sheet.catalog.apple.close")
        }

        if confirmationPresentation != .none {
            ToolbarItem(placement: .confirmationAction) {
                confirmationButton
            }
        }
    }

    @ViewBuilder
    private var confirmationButton: some View {
        switch confirmationPresentation {
        case .none:
            EmptyView()
        case .checkmark:
            Button(action: simulateConfirmation) {
                Image(systemName: "checkmark")
                    .opacity(isConfirming ? 0 : 1)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.primaryActionForeground)
                            .opacity(isConfirming ? 1 : 0)
                    }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appTint)
            .disabled(selectedIDs.isEmpty || isConfirming)
            .accessibilityLabel(isConfirming ? "正在确认" : "确认")
            .accessibilityValue("已选择 \(selectedIDs.count) 本书")
            .accessibilityIdentifier("sheet.catalog.apple.confirm")
        case .text(let title):
            Button(action: simulateConfirmation) {
                Text(title)
                    .opacity(isConfirming ? 0 : 1)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.primaryActionForeground)
                            .opacity(isConfirming ? 1 : 0)
                    }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.appTint)
            .disabled(selectedIDs.isEmpty || isConfirming)
            .accessibilityLabel(isConfirming ? "正在\(title)" : title)
            .accessibilityValue("已选择 \(selectedIDs.count) 本书")
            .accessibilityIdentifier("sheet.catalog.apple.confirm")
        }
    }

    private var contentTopBar: some View {
        VStack(spacing: Spacing.none) {
            if showsSearch {
                SheetCatalogSystemSearchBar(
                    text: $searchText,
                    isActive: $isSearchActive,
                    prompt: "搜索书名或作者",
                    isEnabled: !isConfirming
                )
                .padding(.horizontal, Spacing.cozy)
            }

            if showsSelectionSummary {
                HStack(spacing: Spacing.base) {
                    Spacer(minLength: Spacing.none)

                    Text("已选 \(selectedIDs.count) 本")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .monospacedDigit()
                        .accessibilityLabel("已选择 \(selectedIDs.count) 本书")
                }
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                .padding(.horizontal, Spacing.screenEdge)
            }
        }
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.half)
        .disabled(isConfirming)
    }

    private var bottomEdgeBar: some View {
        Color.surfaceSheet
            .frame(height: Spacing.half)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var resultsList: some View {
        List {
            if filteredItems.isEmpty {
                XMContentStateView(
                    role: .noResults,
                    title: "未找到书籍",
                    message: "请尝试其他书名或作者"
                )
                .frame(maxWidth: .infinity, minHeight: 280)
                .listRowInsets(SheetCatalogAppleListLayout.stateInsets)
                .listRowBackground(Color.surfaceSheet)
                .listRowSeparator(.hidden)
            } else {
                ForEach(filteredItems) { item in
                    Button {
                        toggleSelection(item.id)
                    } label: {
                        SheetCatalogAppleBookRow(
                            item: item,
                            isSelected: selectedIDs.contains(item.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isConfirming)
                    .modifier(
                        SheetCatalogAppleListRowModifier(
                            showsSeparator: item.id != filteredItems.last?.id
                        )
                    )
                    .accessibilityAddTraits(
                        selectedIDs.contains(item.id) ? .isSelected : []
                    )
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.surfaceSheet)
        .allowsHitTesting(!isConfirming)
    }

    private func toggleSelection(_ id: Int) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func close() {
        guard !isConfirming else { return }
        dismiss()
    }

    private func simulateConfirmation() {
        guard !selectedIDs.isEmpty, !isConfirming else { return }
        confirmationTask?.cancel()
        isConfirming = true
        confirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            isConfirming = false
            confirmationTask = nil
        }
    }
}

private enum SheetCatalogAppleListLayout {
    static let rowInsets = EdgeInsets(
        top: Spacing.cozy,
        leading: Spacing.screenEdge,
        bottom: Spacing.cozy,
        trailing: Spacing.screenEdge
    )
    static let stateInsets = EdgeInsets(
        top: Spacing.none,
        leading: Spacing.none,
        bottom: Spacing.none,
        trailing: Spacing.none
    )
    static let coverWidth: CGFloat = 44
    static let separatorLeading = coverWidth + Spacing.base
}

private struct SheetCatalogAppleListRowModifier: ViewModifier {
    let showsSeparator: Bool

    func body(content: Content) -> some View {
        content
            .listRowInsets(SheetCatalogAppleListLayout.rowInsets)
            .listRowBackground(Color.surfaceSheet)
            .listRowSeparator(showsSeparator ? .visible : .hidden)
            .listRowSeparatorTint(Color.surfaceDividerSubtle)
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading] + SheetCatalogAppleListLayout.separatorLeading
            }
    }
}

private struct SheetCatalogAppleBookRow: View {
    let item: SheetCatalogSampleItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                SheetCatalogAppleListLayout.coverWidth,
                urlString: "",
                cornerRadius: CornerRadius.inlayHairline,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.half) {
                Text(item.title)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                Text(item.subtitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            XMSelectionIndicator(
                style: .checkbox,
                isSelected: isSelected,
                font: AppTypography.body,
                showsUnselectedBase: true
            )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title)，\(item.subtitle)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

@MainActor
private struct SheetCatalogSystemSearchBar: UIViewRepresentable {
    @Binding private var text: String
    @Binding private var isActive: Bool
    private let prompt: String
    private let isEnabled: Bool

    init(
        text: Binding<String>,
        isActive: Binding<Bool>,
        prompt: String,
        isEnabled: Bool = true
    ) {
        self._text = text
        self._isActive = isActive
        self.prompt = prompt
        self.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISearchBar {
        let searchBar = UISearchBar(frame: .zero)
        searchBar.delegate = context.coordinator
        searchBar.searchBarStyle = .minimal
        searchBar.showsCancelButton = false
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.spellCheckingType = .no
        searchBar.returnKeyType = .search
        searchBar.searchTextField.clearButtonMode = .whileEditing
        searchBar.searchTextField.adjustsFontForContentSizeCategory = true
        searchBar.searchTextField.accessibilityIdentifier = "sheet.catalog.apple.search"
        return searchBar
    }

    func updateUIView(_ searchBar: UISearchBar, context: Context) {
        context.coordinator.parent = self

        if searchBar.text != text {
            searchBar.text = text
        }
        if searchBar.placeholder != prompt {
            searchBar.placeholder = prompt
        }
        if searchBar.isEnabled != isEnabled {
            searchBar.isEnabled = isEnabled
        }
        searchBar.searchTextField.accessibilityLabel = prompt

        context.coordinator.synchronizeFocus(
            of: searchBar,
            shouldBeActive: isEnabled && isActive
        )
    }

    static func dismantleUIView(_ searchBar: UISearchBar, coordinator: Coordinator) {
        coordinator.invalidatePendingFocusRequest()
        searchBar.searchTextField.resignFirstResponder()
        searchBar.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SheetCatalogSystemSearchBar
        private var focusRequestID = UUID()

        init(parent: SheetCatalogSystemSearchBar) {
            self.parent = parent
        }

        func synchronizeFocus(of searchBar: UISearchBar, shouldBeActive: Bool) {
            let isFirstResponder = searchBar.searchTextField.isFirstResponder
            guard isFirstResponder != shouldBeActive else {
                invalidatePendingFocusRequest()
                return
            }

            let requestID = UUID()
            focusRequestID = requestID
            DispatchQueue.main.async { [weak self, weak searchBar] in
                guard let self, let searchBar, self.focusRequestID == requestID else { return }
                if shouldBeActive {
                    searchBar.searchTextField.becomeFirstResponder()
                } else {
                    searchBar.searchTextField.resignFirstResponder()
                }
            }
        }

        func invalidatePendingFocusRequest() {
            focusRequestID = UUID()
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard parent.text != searchText else { return }
            parent.text = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if !parent.isActive {
                parent.isActive = true
            }
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            invalidatePendingFocusRequest()
            if parent.isActive {
                parent.isActive = false
            }
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            if parent.isActive {
                parent.isActive = false
            }
            searchBar.searchTextField.resignFirstResponder()
        }
    }
}

private struct SheetCatalogSampleItem: Identifiable {
    let id: Int
    let title: String
    let subtitle: String

    static let samples = [
        SheetCatalogSampleItem(id: 1, title: "设计中的设计", subtitle: "原研哉"),
        SheetCatalogSampleItem(id: 2, title: "写给大家看的设计书", subtitle: "Robin Williams"),
        SheetCatalogSampleItem(id: 3, title: "点石成金", subtitle: "Steve Krug"),
        SheetCatalogSampleItem(id: 4, title: "About Face 4", subtitle: "Alan Cooper"),
        SheetCatalogSampleItem(id: 5, title: "用户体验要素", subtitle: "Jesse James Garrett"),
        SheetCatalogSampleItem(id: 6, title: "设计心理学", subtitle: "Donald Norman")
    ]
}

#Preview {
    let databaseManager = DatabaseManager(database: try! .empty())
    let repositories = RepositoryContainer(databaseManager: databaseManager)
    NavigationStack {
        SheetCatalogTestView(
            repositories: repositories,
            databaseManager: databaseManager
        )
    }
}
#endif
