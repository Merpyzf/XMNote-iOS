#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 WebHTMLFetchTestViewModel 提供抓取状态、场景预设、友好恢复提示与登录回流状态
 * [OUTPUT]: 对外提供 WebHTMLFetchTestView（网页 HTML 抓取测试页）
 * [POS]: Debug 测试页，验证在线搜索抓取基础设施的 HTML 输出、Cookie 复用、豆瓣登录入口与 DOM 探针命中情况
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct WebHTMLFetchTestView: View {
    @State private var viewModel = WebHTMLFetchTestViewModel()

    var body: some View {
        WebHTMLFetchTestContentView(viewModel: viewModel)
    }
}

private struct WebHTMLFetchTestContentView: View {
    @Bindable var viewModel: WebHTMLFetchTestViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                controlSection
                manualSection
                presetSection
                summarySection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("网页 HTML 抓取")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: doubanLoginPresentationBinding) { presentation in
            DoubanLoginWebViewScreen(
                title: presentation.title,
                onClose: {
                    Task {
                        await viewModel.handleDoubanLoginDismissed()
                    }
                },
                onLoginDetected: {
                    viewModel.handleDoubanLoginSucceeded()
                }
            )
        }
    }
}

private extension WebHTMLFetchTestContentView {
    var doubanLoginPresentationBinding: Binding<WebHTMLFetchTestViewModel.DoubanLoginPresentation?> {
        Binding(
            get: { viewModel.activeDoubanLoginPresentation },
            set: { newValue in
                guard newValue == nil, viewModel.activeDoubanLoginPresentation != nil else {
                    viewModel.activeDoubanLoginPresentation = newValue
                    return
                }
                Task {
                    await viewModel.handleDoubanLoginDismissed()
                }
            }
        )
    }

    var controlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("抓取参数")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("通道")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Picker("通道", selection: $viewModel.selectedChannel) {
                        ForEach(WebFetchChannel.allCases) { channel in
                            Text(channel.title).tag(channel)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("会话")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Picker("会话", selection: $viewModel.selectedSession) {
                        ForEach(WebHTMLFetchTestViewModel.SessionSelection.allCases) { selection in
                            Text(selection.title).tag(selection)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: Spacing.half) {
                    Button("运行全部预设") {
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

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("豆瓣登录")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    HStack(spacing: Spacing.half) {
                        Button("打开登录页") {
                            Task {
                                await viewModel.presentDoubanLoginEntry()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Text("单独验证共享豆瓣会话与登录回流。")
                            .font(.caption)
                            .foregroundStyle(Color.textHint)
                    }
                }

                if viewModel.isRunningAll {
                    HStack(spacing: Spacing.half) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在串行执行全部预设场景...")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var manualSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("手动 URL")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                TextField("https://example.com/page", text: $viewModel.manualURLInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.cozy)
                    .background(Color.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))

                HStack(spacing: Spacing.half) {
                    Button("抓取 URL") {
                        Task {
                            await viewModel.runManual()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("适合直接验证重定向、Cookie 与 HTML 预览。")
                        .font(.caption)
                        .foregroundStyle(Color.textHint)
                }

                outcomeCard(viewModel.manualOutcome)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var presetSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("预设场景")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                VStack(spacing: Spacing.base) {
                    ForEach(viewModel.presets) { item in
                        presetRow(item)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func presetRow(_ item: WebHTMLFetchTestViewModel.PresetItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .top, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(item.note)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer(minLength: 0)
                statusBadge(item.outcome.status)
            }

            outcomeCard(
                item.outcome,
                loginAction: item.outcome.userFacingRecovery?.primaryButtonTitle == nil ? nil : {
                    Task {
                        await viewModel.presentDoubanLogin(for: item.id)
                    }
                },
                retryAction: item.outcome.userFacingRecovery?.retryButtonTitle == nil ? nil : {
                    Task {
                        await viewModel.runPreset(item.id)
                    }
                }
            )

            HStack(spacing: Spacing.half) {
                Button(item.outcome.status == .idle ? "运行" : "重试") {
                    Task {
                        await viewModel.runPreset(item.id)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(item.outcome.status == .loading || viewModel.isRunningAll)

                if item.outcome.status == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
    }

    var summarySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("统计")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.half) {
                    summaryBadge("成功", value: "\(viewModel.successCount)")
                    summaryBadge("失败", value: "\(viewModel.failedCount)")
                    summaryBadge("会话", value: viewModel.selectedSession.title)
                }

                if let lastBatchRunAt = viewModel.lastBatchRunAt {
                    Text("最近批量测试：\(dateTimeText(lastBatchRunAt))")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    Text("尚未执行批量抓取。")
                        .font(.caption)
                        .foregroundStyle(Color.textHint)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }
}

private extension WebHTMLFetchTestContentView {
    func outcomeCard(
        _ outcome: WebHTMLFetchTestViewModel.Outcome,
        loginAction: (() -> Void)? = nil,
        retryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: 6) {
                metricBadge("状态", value: outcome.status.title)
                if let probeStatusTitle = outcome.probeStatusTitle {
                    metricBadge("探针", value: probeStatusTitle)
                }
                if let cookieCount = outcome.cookieCount {
                    metricBadge("Cookie", value: "\(cookieCount)")
                }
            }

            if let recovery = outcome.userFacingRecovery {
                recoveryCard(
                    recovery,
                    loginAction: loginAction,
                    retryAction: retryAction
                )
            }

            if let message = outcome.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.feedbackWarning)
            }

            if let finalURL = outcome.finalURL {
                labeledText("Final URL", value: finalURL, monospaced: true)
            }

            HStack(spacing: Spacing.half) {
                if let initialChannelTitle = outcome.initialChannelTitle {
                    metricBadge("首通道", value: initialChannelTitle)
                }
                if let selectedChannelTitle = outcome.selectedChannelTitle {
                    metricBadge("最终通道", value: selectedChannelTitle)
                }
                if let elapsedMilliseconds = outcome.elapsedMilliseconds {
                    metricBadge("耗时", value: "\(elapsedMilliseconds)ms")
                }
            }

            HStack(spacing: Spacing.half) {
                if let pageTitle = outcome.pageTitle, !pageTitle.isEmpty {
                    metricBadge("Title", value: pageTitle)
                }
                if let htmlLength = outcome.htmlLength {
                    metricBadge("HTML", value: "\(htmlLength)")
                }
            }

            if !outcome.doubanBooks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("抓取书籍")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    VStack(spacing: Spacing.half) {
                        ForEach(outcome.doubanBooks) { book in
                            doubanBookCard(book)
                        }
                    }
                }
            }

            debugDiagnosticsSection(outcome)
        }
    }

    func recoveryCard(
        _ recovery: WebHTMLFetchTestViewModel.UserFacingRecovery,
        loginAction: (() -> Void)?,
        retryAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(recovery.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            Text(recovery.message)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            HStack(spacing: Spacing.half) {
                if let primaryButtonTitle = recovery.primaryButtonTitle,
                   let loginAction {
                    Button(primaryButtonTitle, action: loginAction)
                        .buttonStyle(.borderedProminent)
                }

                if let retryButtonTitle = recovery.retryButtonTitle,
                   let retryAction {
                    Button(retryButtonTitle, action: retryAction)
                        .buttonStyle(.borderedProminent)
                }

                if let secondaryButtonTitle = recovery.secondaryButtonTitle {
                    Text(secondaryButtonTitle)
                        .font(.caption)
                        .foregroundStyle(Color.textHint)
                }
            }
        }
        .padding(Spacing.base)
        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }

    @ViewBuilder
    func debugDiagnosticsSection(_ outcome: WebHTMLFetchTestViewModel.Outcome) -> some View {
        let hasDiagnostics = outcome.fallbackReason != nil
            || outcome.probeSummary != nil
            || !outcome.attempts.isEmpty
            || !outcome.selectorHits.isEmpty
            || ((outcome.htmlPreview?.isEmpty == false))

        if hasDiagnostics {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("调试信息")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                if let fallbackReason = outcome.fallbackReason {
                    labeledText("回退原因", value: fallbackReason, monospaced: false)
                }

                if let probeSummary = outcome.probeSummary {
                    labeledText("探针摘要", value: probeSummary, monospaced: false)
                }

                if !outcome.attempts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("尝试轨迹")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                        VStack(spacing: Spacing.half) {
                            ForEach(outcome.attempts) { attempt in
                                attemptCard(attempt)
                            }
                        }
                    }
                }

                if !outcome.selectorHits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("命中选择器")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                        FlowLayoutRow(items: outcome.selectorHits)
                    }
                }

                if let htmlPreview = outcome.htmlPreview, !htmlPreview.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("HTML 预览")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(htmlPreview)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled)
                                .padding(Spacing.base)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(Color.surfacePage)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                    }
                }
            }
        }
    }

    func doubanBookCard(_ book: WebHTMLFetchTestViewModel.DoubanBookRow) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                48,
                urlString: book.coverURLString,
                cornerRadius: CornerRadius.inlaySmall,
                border: XMBookCover.Border(color: Color.black.opacity(0.06), width: 0.5),
                placeholderIconSize: .medium
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)

                if !book.info.isEmpty {
                    Text(book.info)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(3)
                }

                metricBadge("Douban ID", value: "\(book.doubanId)")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.base)
        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }

    func attemptCard(_ attempt: WebHTMLFetchTestViewModel.AttemptOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                metricBadge("通道", value: attempt.channelTitle)
                if let probeStatusTitle = attempt.probeStatusTitle {
                    metricBadge("探针", value: probeStatusTitle)
                }
                if let elapsedMilliseconds = attempt.elapsedMilliseconds {
                    metricBadge("耗时", value: "\(elapsedMilliseconds)ms")
                }
            }

            Text(attempt.summary)
                .font(.caption)
                .foregroundStyle(Color.textPrimary)

            if let finalURL = attempt.finalURL {
                Text(finalURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.base)
        .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }

    func statusBadge(_ status: WebHTMLFetchTestViewModel.RunStatus) -> some View {
        Text(status.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusForeground(status))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusBackground(status), in: Capsule())
    }

    func metricBadge(_ title: String, value: String) -> some View {
        Text("\(title) \(value)")
            .font(.caption2)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.surfacePage, in: Capsule())
    }

    func labeledText(_ title: String, value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
        }
    }

    func summaryBadge(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.cozy)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }

    func statusForeground(_ status: WebHTMLFetchTestViewModel.RunStatus) -> Color {
        switch status {
        case .idle:
            return Color.textSecondary
        case .loading:
            return Color.feedbackWarning
        case .success:
            return Color.feedbackSuccess
        case .failed:
            return Color.feedbackError
        }
    }

    func statusBackground(_ status: WebHTMLFetchTestViewModel.RunStatus) -> Color {
        switch status {
        case .idle:
            return Color.surfacePage
        case .loading:
            return Color.feedbackWarning.opacity(0.14)
        case .success:
            return Color.feedbackSuccess.opacity(0.14)
        case .failed:
            return Color.feedbackError.opacity(0.14)
        }
    }

    func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct FlowLayoutRow: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chunked(items, size: 2), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        Text(item)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.surfacePage, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chunked(_ values: [String], size: Int) -> [[String]] {
        stride(from: 0, to: values.count, by: max(size, 1)).map {
            Array(values[$0..<min($0 + max(size, 1), values.count)])
        }
    }
}
#endif
