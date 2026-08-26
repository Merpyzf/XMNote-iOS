#if DEBUG
import OSLog
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 SwiftUI TabView、Bottom Accessory、系统 Zoom、Debug UIKit Zoom 桥接/纯 UIKit 宿主与 ReadingTimerAccessoryView/DesignTokens
 * [OUTPUT]: 对外提供 AppleMusicTransitionLabView（Bottom Accessory 液态玻璃退场的 XMNote 对照与纯系统最小复现入口）
 * [POS]: Debug 测试页，以生产近似路径和纯 Apple 路径隔离来源表面、SwiftUI 桥接与 UIKit 系统容器差异
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 测试中心入口页，以固定入口启动互不串扰的 XMNote 对照与框架归因实验壳。
struct AppleMusicTransitionLabView: View {
    @State private var activeRoute: AppleMusicTransitionLabRoute?

    var body: some View {
        ZStack {
            Color.surfacePage
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    overviewCard
                    xmnoteComparisonCard
                    frameworkAttributionCard
                    attributionRulesCard
                    checklistCard
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
                .safeAreaPadding(.bottom)
            }
        }
        .navigationTitle("Apple Music 转场")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeRoute) { route in
            experimentShell(for: route)
                .presentationBackground(Color.surfacePage)
        }
    }

    private var overviewCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Label("Accessory 液态玻璃退场对照", systemImage: "music.note.list")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text("A/B/C 保留真实计时 Accessory 作为生产近似对照；D/E 移除 XMNote 组件和自定义表面，分别验证纯 SwiftUI 与纯 UIKit 系统路径。")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var xmnoteComparisonCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("XMNote 实现对照")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text("请分别录制相同的 regular Accessory 打开与按钮关闭。A 用于复现生产现状；B 只移除来源自有表面；C 改由纯 SwiftUI FullScreen Zoom 呈现。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AppleMusicTransitionLabMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(mode.title)
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)

                        Text(mode.summary)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            activeRoute = .xmnote(mode)
                        } label: {
                            Label(mode.launchTitle, systemImage: mode.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .font(AppTypography.captionMedium)
                        .accessibilityIdentifier(mode.launchAccessibilityIdentifier)
                    }

                    if mode != AppleMusicTransitionLabMode.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var frameworkAttributionCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("框架归因")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text("D/E 不复用真实计时组件、设计令牌或自定义 Presenter，只保留 Apple 公开的 Bottom Accessory 与系统 Zoom。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(AppleMusicTransitionFrameworkMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(mode.title)
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)

                        Text(mode.summary)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            activeRoute = .framework(mode)
                        } label: {
                            Label(mode.launchTitle, systemImage: mode.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .font(AppTypography.captionMedium)
                        .accessibilityIdentifier(mode.launchAccessibilityIdentifier)
                    }

                    if mode != AppleMusicTransitionFrameworkMode.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var attributionRulesCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("固定归因规则")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                AppleMusicTransitionLabBulletRow(text: "D、E 都复现：系统 Tab Accessory / Liquid Glass 交互式转场合成风险")
                AppleMusicTransitionLabBulletRow(text: "仅 D 复现：SwiftUI tabViewBottomAccessory 桥接风险")
                AppleMusicTransitionLabBulletRow(text: "仅 E 复现：UIKit UITabAccessory + preferredTransition.zoom 上下文风险。")
                AppleMusicTransitionLabBulletRow(text: "D、E 均不复现而 A/B/C 复现：回到 XMNote 来源承载或呈现生命周期排查")
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var checklistCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("观察目标")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                AppleMusicTransitionLabBulletRow(text: "按钮关闭只作为非交互基线；主判据改为真实鼠标下拉完成后的至少 1.5 秒尾帧。")
                AppleMusicTransitionLabBulletRow(text: "分别记录几何归位与系统玻璃重新稳定的时刻，glassTail 必须不超过 50ms")
                AppleMusicTransitionLabBulletRow(text: "下拉完成通过后，再验证 inline、半程取消、快速反向和 Reduce Motion")
                AppleMusicTransitionLabBulletRow(text: "任何双份来源、矩形边界、白闪或末段二次修正都判为失败")
                AppleMusicTransitionLabBulletRow(text: "本轮只有模拟器证据，结论只能标记为框架风险，不能称为 Apple 已确认 BUG")
            }
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    private func experimentShell(for route: AppleMusicTransitionLabRoute) -> some View {
        switch route {
        case .xmnote(let mode):
            AppleMusicTransitionLabSwiftUIShell(
                mode: mode,
                onClose: { activeRoute = nil }
            )
        case .framework(.swiftUI):
            AppleMusicTransitionFrameworkSwiftUIShell(
                onClose: { activeRoute = nil }
            )
        case .framework(.uiKit):
            AppleMusicTransitionFrameworkUIKitHost(
                onClose: { activeRoute = nil }
            )
        }
    }
}

/// 将生产近似与纯系统实验路由分离，避免两类夹具共享状态或视图身份。
private enum AppleMusicTransitionLabRoute: Identifiable {
    case xmnote(AppleMusicTransitionLabMode)
    case framework(AppleMusicTransitionFrameworkMode)

    var id: String {
        switch self {
        case .xmnote(let mode):
            "xmnote-\(mode.rawValue)"
        case .framework(let mode):
            "framework-\(mode.rawValue)"
        }
    }
}

/// 两条纯系统路径分别隔离 SwiftUI 桥接层与 UIKit 原生 Tab Accessory 容器。
private enum AppleMusicTransitionFrameworkMode: String, CaseIterable, Equatable, Identifiable {
    case swiftUI
    case uiKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swiftUI:
            "D · 纯 SwiftUI"
        case .uiKit:
            "E · 纯 UIKit"
        }
    }

    var summary: String {
        switch self {
        case .swiftUI:
            "仅使用 TabView、tabViewBottomAccessory、FullScreenCover 与系统 Zoom。"
        case .uiKit:
            "仅使用 UITabBarController、UITabAccessory、UIViewController 与系统 Zoom。"
        }
    }

    var launchTitle: String {
        switch self {
        case .swiftUI:
            "启动 D 组"
        case .uiKit:
            "启动 E 组"
        }
    }

    var systemImage: String {
        switch self {
        case .swiftUI:
            "swift"
        case .uiKit:
            "apple.logo"
        }
    }

    var launchAccessibilityIdentifier: String {
        "apple-music-transition-framework-launch-\(rawValue)"
    }
}

/// 固定三种实验变量，避免录屏阶段临时组合出不可比较的状态。
private enum AppleMusicTransitionLabMode: String, CaseIterable, Equatable, Identifiable {
    case uiKitOpaqueSource
    case uiKitTransparentSource
    case swiftUIFullScreen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uiKitOpaqueSource:
            "A · UIKit 不透明来源"
        case .uiKitTransparentSource:
            "B · UIKit 透明来源"
        case .swiftUIFullScreen:
            "C · SwiftUI FullScreen Zoom"
        }
    }

    var summary: String {
        switch self {
        case .uiKitOpaqueSource:
            "生产基线：来源自带 surfaceCard、离屏合成和圆角裁切"
        case .uiKitTransparentSource:
            "保留 UIKit Zoom，只让系统 Bottom Accessory 持有液态玻璃表面"
        case .swiftUIFullScreen:
            "透明来源与目标均由 SwiftUI 系统 Zoom 管理"
        }
    }

    var launchTitle: String {
        switch self {
        case .uiKitOpaqueSource:
            "启动 A 组"
        case .uiKitTransparentSource:
            "启动 B 组"
        case .swiftUIFullScreen:
            "启动 C 组"
        }
    }

    var systemImage: String {
        switch self {
        case .uiKitOpaqueSource:
            "rectangle.fill"
        case .uiKitTransparentSource:
            "rectangle"
        case .swiftUIFullScreen:
            "swift"
        }
    }

    var launchAccessibilityIdentifier: String {
        "apple-music-transition-lab-launch-\(rawValue)"
    }

    var usesUIKit: Bool {
        self != .swiftUIFullScreen
    }

    var ownsSourceSurface: Bool {
        self == .uiKitOpaqueSource
    }
}

/// SwiftUI 页面壳保持相同 Tab 和目标结构，仅在来源节点切换实验变量。
private struct AppleMusicTransitionLabSwiftUIShell: View {
    let mode: AppleMusicTransitionLabMode
    let onClose: () -> Void

    @Namespace private var transitionNamespace
    @State private var isSwiftUIPlayerPresented = false

    var body: some View {
        ZStack {
            Color.surfacePage
                .ignoresSafeArea()

            AppleMusicTransitionLabTabContent(
                mode: mode,
                onClose: onClose
            )
                .tabViewBottomAccessory {
                    accessorySource
                }
        }
        .fullScreenCover(
            isPresented: $isSwiftUIPlayerPresented,
            onDismiss: {
                AppleMusicTransitionLabLogger.event(
                    "SwiftUI dismissal completed; mode=\(mode.rawValue)"
                )
            }
        ) {
            AppleMusicTransitionLabPlayerView {
                isSwiftUIPlayerPresented = false
            }
            .presentationBackground(Color.surfacePage)
            .navigationTransition(
                .zoom(
                    sourceID: AppleMusicTransitionLabFixture.transitionID,
                    in: transitionNamespace
                )
            )
        }
        .onAppear {
            AppleMusicTransitionLabLogger.event("Experiment launched; mode=\(mode.rawValue)")
        }
    }

    @ViewBuilder
    private var accessorySource: some View {
        if mode.usesUIKit {
            AppleMusicTransitionLabUIKitAccessorySource(
                ownsSourceSurface: mode.ownsSourceSurface
            )
        } else {
            AppleMusicTransitionLabAccessoryContent(
                onOpen: {
                    AppleMusicTransitionLabLogger.event("SwiftUI presentation requested")
                    isSwiftUIPlayerPresented = true
                }
            )
            .matchedTransitionSource(
                id: AppleMusicTransitionLabFixture.transitionID,
                in: transitionNamespace
            )
        }
    }
}

/// 把系统 Accessory placement 映射为 SwiftUI 内容，并交给稳定的 UIKit 来源控制器承载。
private struct AppleMusicTransitionLabUIKitAccessorySource: View {
    let ownsSourceSurface: Bool

    var body: some View {
        AppleMusicTransitionLabUIKitZoomBridge(
            sourceID: AppleMusicTransitionLabFixture.transitionID,
            surfaceColor: UIColor(Color.surfacePage)
        ) { open in
            if ownsSourceSurface {
                AppleMusicTransitionLabAccessoryContent(onOpen: open)
                    .background(
                        Color.surfaceCard,
                        in: RoundedRectangle(
                            cornerRadius: CornerRadius.containerXL,
                            style: .continuous
                        )
                    )
                    .compositingGroup()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: CornerRadius.containerXL,
                            style: .continuous
                        )
                    )
            } else {
                AppleMusicTransitionLabAccessoryContent(onOpen: open)
            }
        } destination: { dismiss in
            AppleMusicTransitionLabPlayerView(onClose: dismiss)
        }
    }
}

/// 三组实验共用真实生产 Accessory 组件与固定暂停会话，排除计时刷新造成的像素变化。
private struct AppleMusicTransitionLabAccessoryContent: View {
    let onOpen: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        ReadingTimerAccessoryView(
            session: AppleMusicTransitionLabFixture.session,
            isWriting: false,
            onOpen: onOpen,
            onTogglePlayback: {},
            layoutMode: placement == .inline ? .inline : .expanded
        )
        .frame(maxWidth: placement == .inline ? nil : .infinity)
        .accessibilityIdentifier("apple-music-transition-lab-accessory")
    }
}

/// 独立实验壳的两页 Tab 内容，通过滚动触发系统 regular/inline Accessory 切换。
private struct AppleMusicTransitionLabTabContent: View {
    let mode: AppleMusicTransitionLabMode
    let onClose: () -> Void

    var body: some View {
        TabView {
            Tab("在读", systemImage: "book") {
                NavigationStack {
                    AppleMusicTransitionLabFeedView(
                        title: "在读",
                        accent: .appTint,
                        mode: mode,
                        onClose: onClose
                    )
                }
            }

            Tab("时间线", systemImage: "clock") {
                NavigationStack {
                    AppleMusicTransitionLabFeedView(
                        title: "时间线",
                        accent: .indigo,
                        mode: mode,
                        onClose: onClose
                    )
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Color.appTint)
    }
}

/// 为独立壳提供稳定、可滚动且不参与转场的背景内容。
private struct AppleMusicTransitionLabFeedView: View {
    let title: String
    let accent: Color
    let mode: AppleMusicTransitionLabMode
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.base) {
                ForEach(0..<18, id: \.self) { index in
                    HStack(spacing: Spacing.base) {
                        RoundedRectangle(
                            cornerRadius: CornerRadius.blockMedium,
                            style: .continuous
                        )
                        .fill(accent.opacity(index.isMultiple(of: 2) ? 0.18 : 0.1))
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: index.isMultiple(of: 2) ? "book" : "text.quote")
                                .foregroundStyle(accent)
                        }

                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text("转场背景样例 \(index + 1)")
                                .font(AppTypography.subheadlineMedium)
                                .foregroundStyle(Color.textPrimary)

                            Text("向下滚动可让系统 Tab Bar 与 Accessory 进入 inline 状态")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(Spacing.base)
                    .background(
                        Color.surfaceCard,
                        in: RoundedRectangle(
                            cornerRadius: CornerRadius.blockLarge,
                            style: .continuous
                        )
                    )
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom, 88)
        }
        .background(Color.surfacePage)
        .overlay(alignment: .bottom) {
            AppleMusicTransitionLabGlassCalibrationBackdrop()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(mode.title)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("退出", action: onClose)
                    .accessibilityIdentifier("apple-music-transition-lab-exit")
            }
        }
    }
}

/// 在 Accessory 背后提供固定色彩变化，使系统玻璃恢复与不透明快照的差异更易逐帧识别。
private struct AppleMusicTransitionLabGlassCalibrationBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.indigo.opacity(0.38),
                Color.orange.opacity(0.32),
                Color.appTint.opacity(0.42)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 168)
        .mask {
            LinearGradient(
                colors: [.clear, .black.opacity(0.82), .black],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 为来源和目标提供同一套无网络、高对比封面尺寸。
private enum AppleMusicTransitionLabFixtureCoverSizing {
    case fixedHeight(CGFloat)
    case fixedWidth(CGFloat)
}

/// 通过稳定方向标记放大封面跳变、重影和缩放模糊，底层仍由 XMBookCover 统一渲染。
private struct AppleMusicTransitionLabFixtureCover: View {
    let sizing: AppleMusicTransitionLabFixtureCoverSizing
    let cornerRadius: CGFloat

    var body: some View {
        coverSurface
            .overlay {
                LinearGradient(
                    colors: [
                        Color.indigo.opacity(0.96),
                        Color.appTint.opacity(0.92),
                        Color.orange.opacity(0.90)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay {
                GeometryReader { proxy in
                    directionalMarkers(in: proxy.size)
                }
            }
            .compositingGroup()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(
                    Color.white.opacity(0.42),
                    lineWidth: StrokeWidth.hairline
                )
            }
    }

    @ViewBuilder
    private var coverSurface: some View {
        switch sizing {
        case .fixedHeight(let height):
            XMBookCover.fixedHeight(
                height,
                urlString: "",
                cornerRadius: 0,
                placeholderIconSize: .hidden,
                surfaceStyle: .plain
            )
        case .fixedWidth(let width):
            XMBookCover.fixedWidth(
                width,
                urlString: "",
                cornerRadius: 0,
                placeholderIconSize: .hidden,
                surfaceStyle: .plain
            )
        }
    }

    private func directionalMarkers(in size: CGSize) -> some View {
        let shortEdge = min(size.width, size.height)
        return ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.24))
                .frame(
                    width: max(6, size.width * 0.22),
                    height: size.height * 1.45
                )
                .rotationEffect(.degrees(24))
                .offset(x: -size.width * 0.10)

            Circle()
                .fill(Color.orange)
                .frame(
                    width: max(4, shortEdge * 0.12),
                    height: max(4, shortEdge * 0.12)
                )
                .position(
                    x: size.width * 0.80,
                    y: size.height * 0.16
                )

            VStack(alignment: .leading, spacing: max(2, shortEdge * 0.025)) {
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(
                        width: size.width * 0.38,
                        height: max(2, shortEdge * 0.045)
                    )
                Capsule()
                    .fill(Color.black.opacity(0.50))
                    .frame(
                        width: size.width * 0.25,
                        height: max(2, shortEdge * 0.045)
                    )
            }
            .position(
                x: size.width * 0.30,
                y: size.height * 0.82
            )
        }
    }
}

/// 目标完整页以单一不透明根表面覆盖安全区，排除目标内容自身的背景断层。
private struct AppleMusicTransitionLabPlayerView: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.surfacePage
                .ignoresSafeArea()

            NavigationStack {
                GeometryReader { proxy in
                    VStack(spacing: Spacing.double) {
                        Spacer(minLength: Spacing.section)

                        AppleMusicTransitionLabFixtureCover(
                            sizing: .fixedWidth(
                                min(
                                    AppleMusicTransitionLabFixture.targetCoverWidth,
                                    proxy.size.width - 96
                                )
                            ),
                            cornerRadius: CornerRadius.blockMedium
                        )
                        .shadow(color: .black.opacity(0.16), radius: 16, y: 8)

                        VStack(spacing: Spacing.half) {
                            Text(AppleMusicTransitionLabFixture.bookTitle)
                                .font(AppTypography.title3Semibold)
                                .foregroundStyle(Color.textPrimary)

                            Text("正在阅读")
                                .font(AppTypography.subheadline)
                                .foregroundStyle(Color.textSecondary)
                        }

                        Text(AppleMusicTransitionLabFixture.elapsedTime)
                            .font(AppTypography.brandDisplay(size: 52, relativeTo: .largeTitle))
                            .foregroundStyle(Color.textPrimary)
                            .monospacedDigit()
                            .contentTransition(.numericText())

                        HStack(spacing: Spacing.double) {
                            playerControl(systemName: "backward.end.fill")
                            playerControl(systemName: "pause.fill", isPrimary: true)
                            playerControl(systemName: "forward.end.fill")
                        }

                        Spacer(minLength: Spacing.section)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, Spacing.screenEdge)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        TopBarDismissButton(action: onClose)
                            .accessibilityIdentifier(
                                "apple-music-transition-lab-dismiss"
                            )
                    }

                    ToolbarItem(placement: .principal) {
                        Text("阅读计时")
                            .font(AppTypography.headline)
                    }
                }
            }
        }
        .accessibilityIdentifier("apple-music-transition-lab-player")
    }

    private func playerControl(
        systemName: String,
        isPrimary: Bool = false
    ) -> some View {
        Image(systemName: systemName)
            .font(isPrimary ? AppTypography.title2 : AppTypography.title3)
            .foregroundStyle(isPrimary ? Color.white : Color.textPrimary)
            .frame(
                width: isPrimary ? 64 : AppleMusicTransitionLabFixture.secondaryPlayerControlSize,
                height: isPrimary ? 64 : AppleMusicTransitionLabFixture.secondaryPlayerControlSize
            )
            .background {
                if isPrimary {
                    Circle().fill(Color.appTint)
                }
            }
            .accessibilityHidden(true)
    }
}

/// 纯 SwiftUI 最小复现壳，不依赖 XMNote Accessory、业务状态或 UIKit Presenter。
private struct AppleMusicTransitionFrameworkSwiftUIShell: View {
    let onClose: () -> Void

    @Namespace private var transitionNamespace
    @State private var isDestinationPresented = false

    var body: some View {
        AppleMusicTransitionFrameworkSwiftUITabs(onClose: onClose)
            .tabViewBottomAccessory {
                AppleMusicTransitionFrameworkSwiftUIAccessory {
                    AppleMusicTransitionLabLogger.event(
                        "Framework D SwiftUI presentation requested"
                    )
                    isDestinationPresented = true
                }
                .matchedTransitionSource(
                    id: AppleMusicTransitionFrameworkFixture.transitionID,
                    in: transitionNamespace
                )
            }
            .fullScreenCover(
                isPresented: $isDestinationPresented,
                onDismiss: {
                    AppleMusicTransitionLabLogger.event(
                        "Framework D SwiftUI dismissal completed"
                    )
                }
            ) {
                AppleMusicTransitionFrameworkSwiftUIDestination {
                    isDestinationPresented = false
                }
                .presentationBackground(Color.xmResolved(.systemBackground))
                .navigationTransition(
                    .zoom(
                        sourceID: AppleMusicTransitionFrameworkFixture.transitionID,
                        in: transitionNamespace
                    )
                )
            }
            .onAppear {
                AppleMusicTransitionLabLogger.event("Framework D SwiftUI launched")
            }
    }
}

/// 纯 SwiftUI 实验的系统 Tab 内容，通过滚动保留后续 inline 复测能力。
private struct AppleMusicTransitionFrameworkSwiftUITabs: View {
    let onClose: () -> Void

    var body: some View {
        TabView {
            Tab("列表", systemImage: "list.bullet") {
                NavigationStack {
                    AppleMusicTransitionFrameworkSwiftUIFeed(
                        title: "纯 SwiftUI",
                        onClose: onClose
                    )
                }
            }

            Tab("设置", systemImage: "gearshape") {
                NavigationStack {
                    AppleMusicTransitionFrameworkSwiftUIFeed(
                        title: "系统设置",
                        onClose: onClose
                    )
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(.blue)
    }
}

/// 不绘制背景、材质或离屏合成，仅向系统 Bottom Accessory 提供固定内容。
private struct AppleMusicTransitionFrameworkSwiftUIAccessory: View {
    let onOpen: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .imageScale(.large)

                if placement == .inline {
                    Text("00:42")
                        .monospacedDigit()
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System Accessory")
                            .font(.headline)
                        Text("Paused · 00:42")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "play.fill")
                        .imageScale(.large)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: placement == .inline ? nil : .infinity)
            .frame(height: AppleMusicTransitionFrameworkFixture.accessoryHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("纯 SwiftUI 系统 Accessory")
        .accessibilityIdentifier("apple-music-transition-framework-swiftui-accessory")
    }
}

/// 固定彩色内容位于系统玻璃下方，使材质失效和恢复时刻能被逐帧识别。
private struct AppleMusicTransitionFrameworkSwiftUIFeed: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<20, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: index.isMultiple(of: 2) ? "circle.fill" : "square.fill")
                            .foregroundStyle(
                                Color(
                                    uiColor: AppleMusicTransitionFrameworkFixture
                                        .calibrationColors[index % AppleMusicTransitionFrameworkFixture.calibrationColors.count]
                                )
                            )
                            .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("System Row \(index + 1)")
                                .font(.body)
                            Text("Scroll to minimize the tab accessory")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 64)
                }
            }
            .padding(.vertical, 12)
            .safeAreaPadding(.bottom, 96)
        }
        .background(Color.xmResolved(.systemBackground))
        .overlay(alignment: .bottom) {
            AppleMusicTransitionFrameworkSwiftUICalibrationBackdrop()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("退出", action: onClose)
                    .accessibilityIdentifier(
                        "apple-music-transition-framework-swiftui-exit"
                    )
            }
        }
    }
}

/// 使用与纯 UIKit 实验相同的三段系统色，避免背景采样内容成为变量。
private struct AppleMusicTransitionFrameworkSwiftUICalibrationBackdrop: View {
    var body: some View {
        HStack(spacing: 0) {
            ForEach(
                Array(AppleMusicTransitionFrameworkFixture.calibrationColors.enumerated()),
                id: \.offset
            ) { _, color in
                Color.xmResolved(color)
            }
        }
        .frame(height: AppleMusicTransitionFrameworkFixture.calibrationHeight)
        .mask {
            LinearGradient(
                colors: [.clear, .black.opacity(0.82), .black],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 纯 SwiftUI 目标页只提供不透明系统表面和系统关闭按钮。
private struct AppleMusicTransitionFrameworkSwiftUIDestination: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.xmResolved(.systemBackground)
                .ignoresSafeArea()

            NavigationStack {
                VStack(spacing: 20) {
                    Spacer()

                    Image(systemName: "music.note")
                        .font(.system(size: 72))
                        .foregroundStyle(.blue)

                    Text("System Destination")
                        .font(.title.bold())

                    Text("Pure SwiftUI FullScreen Zoom")
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.xmResolved(.systemBackground))
                .navigationTitle("Framework D")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭", systemImage: "chevron.down", action: onClose)
                            .accessibilityIdentifier(
                                "apple-music-transition-framework-swiftui-dismiss"
                            )
                    }
                }
            }
        }
        .accessibilityIdentifier("apple-music-transition-framework-swiftui-destination")
        .onAppear {
            AppleMusicTransitionLabLogger.event(
                "Framework D SwiftUI destination appeared"
            )
        }
    }
}

/// 纯系统两组共享的固定像素与文案，仅服务 Debug 最小复现。
enum AppleMusicTransitionFrameworkFixture {
    static let transitionID = "apple-music-transition-framework-swiftui"
    static let accessoryHeight: CGFloat = 56
    static let calibrationHeight: CGFloat = 168
    static let calibrationColors: [UIColor] = [
        .systemIndigo,
        .systemOrange,
        .systemGreen
    ]
}

/// 实验固定数据，避免网络、数据库或计时任务改变录屏内容。
private enum AppleMusicTransitionLabFixture {
    static let transitionID = "apple-music-accessory-zoom"
    static let bookTitle = "设计中的设计"
    static let elapsedTime = "00:25:18"
    static let targetCoverWidth: CGFloat = 228
    static let secondaryPlayerControlSize: CGFloat = 44

    static let session = ReadingTimerSession(
        id: 9_900_001,
        book: ReadingTimerBookContext(
            id: 9_900_001,
            name: bookTitle,
            author: "原研哉",
            coverURL: "",
            readStatusId: 1,
            readPosition: 0,
            totalPosition: 0,
            totalPagination: 0,
            currentPositionUnit: 0,
            positionUnit: 0
        ),
        startTime: Date(timeIntervalSince1970: 1_785_427_200),
        endTime: nil,
        interruptTime: Date(timeIntervalSince1970: 1_785_428_718),
        elapsedSeconds: 1_518,
        countdownSeconds: 0,
        pausedDurationMillis: 0,
        isPaused: true,
        status: .paused,
        position: 0,
        recordedPositionUnit: nil,
        fuzzyReadDate: nil,
        insight: "",
        createdDate: Date(timeIntervalSince1970: 1_785_427_200),
        updatedDate: Date(timeIntervalSince1970: 1_785_428_718)
    )
}

/// 统一输出实验生命周期事件，不在录屏画面叠加调试信息。
enum AppleMusicTransitionLabLogger {
    private static let logger = Logger(
        subsystem: "com.merpyzf.xmnote",
        category: "AppleMusicTransitionLab"
    )

    static func event(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[AppleMusicTransitionLab] \(message)")
    }
}

/// 测试页说明列表行。
private struct AppleMusicTransitionLabBulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            Circle()
                .fill(Color.appTint)
                .frame(width: Spacing.compact, height: Spacing.compact)
                .padding(.top, Spacing.half)

            Text(text)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    NavigationStack {
        AppleMusicTransitionLabView()
    }
}
#endif
