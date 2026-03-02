#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 ImageLoadingTestViewModel 提供图片加载测试状态，依赖 XMRemoteImage 进行可视化预览
 * [OUTPUT]: 对外提供 ImageLoadingTestView（图片加载测试页）
 * [POS]: Debug 测试页，覆盖静态图/GIF/失败链路、耗时与缓存来源观测
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ImageLoadingTestView: View {
    @State private var viewModel = ImageLoadingTestViewModel()

    var body: some View {
        ImageLoadingTestContentView(viewModel: viewModel)
    }
}

private struct ImageLoadingTestContentView: View {
    @Bindable var viewModel: ImageLoadingTestViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                operationSection
                manualURLSection
                testCaseSection
                summarySection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.windowBackground)
        .navigationTitle("图片加载测试")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension ImageLoadingTestContentView {
    var operationSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("批量操作")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.half) {
                    Button("运行全部样例") {
                        Task {
                            await viewModel.runAll()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRunningAll)

                    Button("清空结果") {
                        viewModel.resetAll()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isRunningAll)
                }

                if viewModel.isRunningAll {
                    HStack(spacing: Spacing.half) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在串行执行全部样例...")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var manualURLSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("手动 URL 测试")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                TextField("https://example.com/image.jpg", text: $viewModel.manualURLInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.cozy)
                    .background(Color.contentBackground)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium))

                HStack(spacing: Spacing.half) {
                    Button("测试 URL") {
                        Task {
                            await viewModel.runManualURL()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("重置手动结果") {
                        viewModel.resetManualResult()
                    }
                    .buttonStyle(.bordered)
                }

                manualPreview
                manualMetrics
            }
            .padding(Spacing.contentEdge)
        }
    }

    var manualPreview: some View {
        HStack(spacing: Spacing.base) {
            Group {
                if viewModel.manualStatus == .success {
                    XMRemoteImage(
                        urlString: viewModel.manualURLInput,
                        showsGIFBadge: true
                    ) {
                        previewPlaceholder
                    }
                    .id("manual-preview-\(viewModel.manualPreviewVersion)")
                } else {
                    previewPlaceholder
                }
            }
            .frame(width: 52, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall)
                    .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
            )

            VStack(alignment: .leading, spacing: 4) {
                statusBadge(viewModel.manualStatus)
                metricBadges(
                    elapsedMs: viewModel.manualElapsedMs,
                    cacheSource: viewModel.manualCacheSource
                )
                if let message = viewModel.manualMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.feedbackWarning)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    var manualMetrics: some View {
        HStack {
            Text("建议：先运行一次，再点“测试 URL”观察缓存来源变化。")
                .font(.caption2)
                .foregroundStyle(Color.textHint)
            Spacer()
        }
    }

    var testCaseSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("预置样例")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                VStack(spacing: Spacing.base) {
                    ForEach(viewModel.items) { item in
                        testCaseRow(item)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func testCaseRow(_ item: ImageLoadingTestViewModel.TestCaseItem) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Group {
                if item.status == .success {
                    XMRemoteImage(
                        urlString: item.urlString,
                        showsGIFBadge: item.mediaKind == .gif
                    ) {
                        previewPlaceholder
                    }
                    .id("\(item.id.uuidString)-\(item.previewVersion)")
                } else {
                    previewPlaceholder
                }
            }
            .frame(width: 52, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall)
                    .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
            )

            VStack(alignment: .leading, spacing: Spacing.half) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(item.note)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    statusBadge(item.status)
                }

                Text(item.urlString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.textHint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                metricBadges(elapsedMs: item.elapsedMs, cacheSource: item.cacheSource)

                if let message = item.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.feedbackWarning)
                        .lineLimit(2)
                }

                HStack(spacing: Spacing.half) {
                    Button(item.status == .idle ? "运行" : "重试") {
                        Task {
                            await viewModel.retryItem(item.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(item.status == .loading || viewModel.isRunningAll)

                    if item.status == .loading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(Spacing.base)
        .background(Color.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium))
    }

    var summarySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("结果统计")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.half) {
                    summaryBadge("成功", value: "\(viewModel.successCount)")
                    summaryBadge("失败", value: "\(viewModel.failedCount)")
                    summaryBadge("平均耗时", value: "\(viewModel.averageElapsedMs ?? 0)ms")
                }

                if let lastBatchRunAt = viewModel.lastBatchRunAt {
                    Text("最近批量测试：\(dateTimeText(lastBatchRunAt))")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    Text("尚未进行批量测试。")
                        .font(.caption)
                        .foregroundStyle(Color.textHint)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }
}

private extension ImageLoadingTestContentView {
    var previewPlaceholder: some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(Color.tagBackground)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textHint)
            }
    }

    func statusBadge(_ status: ImageLoadingTestViewModel.LoadStatus) -> some View {
        Text(status.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusForeground(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusBackground(status), in: Capsule())
    }

    func metricBadges(
        elapsedMs: Int?,
        cacheSource: ImageLoadingTestViewModel.CacheSource
    ) -> some View {
        HStack(spacing: 6) {
            Text("耗时 \(elapsedMs.map { "\($0)ms" } ?? "--")")
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.windowBackground, in: Capsule())

            Text("来源 \(cacheSource.title)")
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.windowBackground, in: Capsule())
        }
    }

    func summaryBadge(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.textHint)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.contentBackground, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall))
    }

    func statusForeground(_ status: ImageLoadingTestViewModel.LoadStatus) -> Color {
        switch status {
        case .idle:
            return Color.textSecondary
        case .loading:
            return Color.brand
        case .success:
            return Color.feedbackSuccess
        case .failed:
            return Color.feedbackWarning
        }
    }

    func statusBackground(_ status: ImageLoadingTestViewModel.LoadStatus) -> Color {
        switch status {
        case .idle:
            return Color.contentBackground
        case .loading:
            return Color.brand.opacity(0.15)
        case .success:
            return Color.feedbackSuccess.opacity(0.18)
        case .failed:
            return Color.feedbackWarning.opacity(0.18)
        }
    }

    func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        ImageLoadingTestView()
    }
}
#endif
