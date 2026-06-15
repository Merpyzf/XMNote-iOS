#if DEBUG
/**
 * [INPUT]: 依赖 XMToastCenter、DesignTokens 与本地调试状态，演示底部/顶部短驻留 Toast 的位置、时长与语义状态
 * [OUTPUT]: 对外提供 PopupViewToastTestView（统一 Toast 基建效果调试页）
 * [POS]: Debug 测试页，仅用于验证 XMToast 作为 Toast 统一调用入口，不进入生产业务路径
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct PopupViewToastTestView: View {
    @Environment(XMToastCenter.self) private var toastCenter
    @State private var placement: XMToastPlacement = .bottom
    @State private var duration: Double = 1.8
    @State private var usesLongMessage = false
    @State private var reduceMotionPreview = false
    @State private var processingTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.section) {
                previewSection
                triggerSection
                controlsSection
                behaviorSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom, 118)
        }
        .background(Color.surfacePage)
        .navigationTitle("Toast 提示")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            bottomReferenceChrome
        }
        .onAppear {
            toastCenter.debugReducesMotion = reduceMotionPreview
        }
        .onChange(of: reduceMotionPreview) { _, newValue in
            toastCenter.debugReducesMotion = newValue
        }
        .onDisappear {
            processingTask?.cancel()
            toastCenter.debugReducesMotion = false
            toastCenter.dismiss()
        }
    }
}

private extension PopupViewToastTestView {
    var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            sectionHeader("浮层预览", subtitle: "底部参照物用于观察 Toast 与 TabBar / 搜索浮层的避让关系。")

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                    .fill(Color.surfaceCard)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                            .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                    }

                VStack(alignment: .leading, spacing: Spacing.base) {
                    HStack {
                        VStack(alignment: .leading, spacing: Spacing.half) {
                            Capsule()
                                .fill(Color.brand.opacity(0.16))
                                .frame(width: 108, height: 16)
                            Capsule()
                                .fill(Color.textHint.opacity(0.18))
                                .frame(width: 170, height: 10)
                        }

                        Spacer()

                        Circle()
                            .fill(Color.controlFillSecondary)
                            .frame(width: 38, height: 38)
                            .overlay {
                                Image(systemName: "checkmark")
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(Color.textSecondary)
                            }
                    }

                    HStack(spacing: Spacing.base) {
                        referenceCard(title: "列表内容", subtitle: "Toast 不应遮挡主信息")
                        referenceCard(title: "可继续操作", subtitle: "背景保持可点")
                    }

                    Spacer(minLength: 0)
                }
                .padding(Spacing.contentEdge)

                bottomReferenceChrome
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.bottom, Spacing.base)
            }
            .frame(height: 292)
        }
    }

    var triggerSection: some View {
        debugCard("触发场景") {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: Spacing.base),
                GridItem(.flexible(), spacing: Spacing.base)
            ], spacing: Spacing.base) {
                toastButton(.success)
                toastButton(.warning)
                toastButton(.error)
                toastButton(.info)
                processingButton
                    .gridCellColumns(2)
            }
        }
    }

    var controlsSection: some View {
        debugCard("呈现参数") {
            pickerRow("位置", selection: $placement)
            sliderRow("自动隐藏", value: $duration, range: 1.0...4.0, step: 0.2, suffix: "秒")
            Toggle("显示长文案", isOn: $usesLongMessage)
            Toggle("模拟 Reduce Motion", isOn: $reduceMotionPreview)
        }
    }

    var behaviorSection: some View {
        debugCard("验收关注") {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                behaviorRow("短驻留", "成功/信息约 1.8 秒，警告与错误更长；调试页可覆盖时长。")
                behaviorRow("非阻塞", "背景点击可穿透，Toast 本体点击关闭。")
                behaviorRow("单条更新", "连续触发只替换当前提示，不做堆叠。")
                behaviorRow("处理中", "处理中态不自动隐藏，完成后切换为成功态。")
            }
        }
    }

    var bottomReferenceChrome: some View {
        HStack(spacing: Spacing.tight) {
            HStack(spacing: Spacing.tight) {
                chromeTab(icon: "book", title: "书籍", isActive: true)
                chromeTab(icon: "note.text", title: "笔记", isActive: false)
                chromeTab(icon: "person", title: "我的", isActive: false)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 64)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle.opacity(0.32), lineWidth: CardStyle.borderWidth)
            }

            Circle()
                .fill(.thinMaterial)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "magnifyingglass")
                        .font(AppTypography.title3Semibold)
                        .foregroundStyle(Color.iconPrimary)
                }
                .overlay {
                    Circle()
                        .stroke(Color.surfaceBorderSubtle.opacity(0.32), lineWidth: CardStyle.borderWidth)
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ToastDemoLayout.bottomChromeVerticalPadding)
    }

    func toastButton(_ kind: ToastDemoKind) -> some View {
        Button {
            presentToast(kind)
        } label: {
            Label(kind.buttonTitle, systemImage: kind.role.symbolName)
                .font(AppTypography.subheadlineSemibold)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.bordered)
        .tint(kind.role.tintColor)
    }

    var processingButton: some View {
        Button {
            presentProcessingToast()
        } label: {
            Label("处理中后自动成功", systemImage: XMToastRole.processing.symbolName)
                .font(AppTypography.subheadlineSemibold)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.brand)
    }

    func presentToast(_ kind: ToastDemoKind) {
        processingTask?.cancel()
        toastCenter.show(
            kind.role,
            kind.message(usesLongMessage: usesLongMessage),
            duration: duration,
            placement: placement
        )
    }

    func presentProcessingToast() {
        processingTask?.cancel()
        toastCenter.processing(
            ToastDemoKind.processing.message(usesLongMessage: usesLongMessage),
            placement: placement
        )

        processingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            toastCenter.success(
                ToastDemoKind.success.message(usesLongMessage: usesLongMessage),
                duration: duration,
                placement: placement
            )
        }
    }

    func debugCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                content()
            }
            .padding(Spacing.contentEdge)
        }
    }

    func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func pickerRow(_ title: String, selection: Binding<XMToastPlacement>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            Picker(title, selection: selection) {
                ForEach(XMToastPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            HStack(spacing: Spacing.half) {
                Text(title)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textPrimary)

                Text(String(format: "%.1f %@", value.wrappedValue, suffix))
                    .font(AppTypography.caption2Semibold)
                    .foregroundStyle(Color.brandDeep)
                    .padding(.horizontal, Spacing.half)
                    .padding(.vertical, Spacing.compact)
                    .background(Color.brand.opacity(0.10), in: Capsule())

                Spacer(minLength: 0)
            }

            Slider(value: value, in: range, step: step)
                .tint(Color.brand)
        }
    }

    func behaviorRow(_ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            Image(systemName: "checkmark.circle.fill")
                .font(AppTypography.caption)
                .foregroundStyle(Color.feedbackSuccess)
                .padding(.top, Spacing.micro)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(title)
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func referenceCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.base)
        .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    func chromeTab(icon: String, title: String, isActive: Bool) -> some View {
        VStack(spacing: Spacing.compact) {
            Image(systemName: icon)
                .font(AppTypography.headlineSemibold)
            Text(title)
                .font(AppTypography.caption2Medium)
        }
        .foregroundStyle(isActive ? Color.feedbackSuccess : Color.iconPrimary)
        .frame(width: 54, height: 52)
        .background {
            if isActive {
                Capsule()
                    .fill(Color.brand.opacity(0.12))
            }
        }
    }
}

private enum ToastDemoKind: String, CaseIterable, Identifiable {
    case success
    case warning
    case error
    case info
    case processing

    var id: String { rawValue }

    var role: XMToastRole {
        switch self {
        case .success:
            return .success
        case .warning:
            return .warning
        case .error:
            return .error
        case .info:
            return .info
        case .processing:
            return .processing
        }
    }

    var buttonTitle: String {
        role.title
    }

    func message(usesLongMessage: Bool) -> String {
        usesLongMessage ? longMessage : shortMessage
    }

    private var shortMessage: String {
        switch self {
        case .success:
            return "已保存"
        case .warning:
            return "当前网络较慢"
        case .error:
            return "操作失败，请稍后再试"
        case .info:
            return "已加入稍后处理"
        case .processing:
            return "正在更新..."
        }
    }

    private var longMessage: String {
        switch self {
        case .success:
            return "已保存到本地，稍后会随同步任务上传。"
        case .warning:
            return "当前网络较慢，内容会先保留在本机，连接恢复后继续处理。"
        case .error:
            return "操作失败，请检查网络连接后重试，当前页面内容不会丢失。"
        case .info:
            return "已加入稍后处理列表，你可以继续浏览当前页面。"
        case .processing:
            return "正在更新排序，期间请不要重复触发同一操作。"
        }
    }
}

private enum ToastDemoLayout {
    static let bottomChromeVerticalPadding: CGFloat = Spacing.half
}

private struct PopupViewToastTestPreviewHost: View {
    @State private var toastCenter = XMToastCenter()

    var body: some View {
        NavigationStack {
            PopupViewToastTestView()
        }
        .environment(toastCenter)
        .xmToastHost(center: toastCenter)
    }
}

#Preview {
    PopupViewToastTestPreviewHost()
}
#endif
