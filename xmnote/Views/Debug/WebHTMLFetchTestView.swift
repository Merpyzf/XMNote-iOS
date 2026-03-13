#if DEBUG
import SwiftUI
import WebKit

/**
 * [INPUT]: 依赖 WebHTMLFetchTestViewModel 提供抓取状态、场景预设、友好恢复提示、番茄 DOM 调试报告与结构化解析结果，依赖 XMBookSearchResultCard 渲染与功能页一致的书籍结果卡
 * [OUTPUT]: 对外提供 WebHTMLFetchTestView（网页 HTML 抓取测试页）
 * [POS]: Debug 测试页，验证在线搜索抓取基础设施的 HTML 输出、Cookie 复用、豆瓣登录入口、番茄 DOM 搜索流程、可见页面预览与 DOM 探针命中情况
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
                fanqieSection
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
        .fullScreenCover(item: $viewModel.activeFanqieVerificationPresentation) { presentation in
            BookFanqieVerificationScreen(
                title: presentation.title,
                searchURL: presentation.searchURL,
                onClose: {
                    Task {
                        await viewModel.handleFanqieVerificationDismissed(completed: false)
                    }
                },
                onVerificationCompleted: {
                    Task {
                        await viewModel.handleFanqieVerificationDismissed(completed: true)
                    }
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

    var fanqieSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("番茄搜索调试")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                Text("这里直接运行番茄 DOM 搜索链路，展示运行时快照、终态 HTML、详情链接和触发风控后的恢复流程。")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                TextField("输入番茄关键词", text: $viewModel.fanqieKeyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.cozy)
                    .background(Color.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))

                HStack(spacing: Spacing.half) {
                    Button("运行番茄搜索") {
                        Task {
                            await viewModel.runFanqieDebugSearch()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.fanqieDebugReport.status == .loading)

                    Button("清空报告") {
                        viewModel.clearFanqieDebugReport()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.fanqieDebugReport.status == .loading)
                }

                fanqiePreviewCard
                fanqieReportCard(viewModel.fanqieDebugReport)
                fanqieStructuredResultsCard
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

    func fanqieReportCard(_ report: WebHTMLFetchTestViewModel.FanqieDebugReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: 6) {
                metricBadge("状态", value: report.status.title)
                metricBadge("快照", value: "\(report.snapshots.count)")
                metricBadge("详情链接", value: "\(report.detailPageURLs.count)")
                if !report.candidateDetailPageURLs.isEmpty {
                    metricBadge("候选链接", value: "\(report.candidateDetailPageURLs.count)")
                }
                if let htmlLength = report.htmlLength {
                    metricBadge("HTML", value: "\(htmlLength)")
                }
            }

            if report.status == .verificationRequired {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("番茄命中风控")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text("测试页会复用正式业务中的番茄验证页。完成验证后，会自动重新搜索当前关键词。")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    Button("打开番茄验证页") {
                        viewModel.openFanqieVerification()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(Spacing.base)
                .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
            }

            if report.status == .unrecognizedResult {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("页面已展示结果，但解析规则未命中")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)

                    Text("优先检查候选详情链接、结果容器文本和 HTML 片段，确认番茄是否调整了结果卡片结构。")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(Spacing.base)
                .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
            }

            if let message = report.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        report.status == .failed || report.status == .timeout || report.status == .unrecognizedResult
                            ? Color.feedbackError
                            : Color.feedbackWarning
                    )
            }

            if let requestURL = report.requestURL {
                labeledText("Request URL", value: requestURL, monospaced: true)
            }

            if let finalURL = report.finalURL {
                labeledText("Final URL", value: finalURL, monospaced: true)
            }

            if !report.events.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("流程轨迹")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    VStack(spacing: Spacing.half) {
                        ForEach(Array(report.events.enumerated()), id: \.element.id) { index, event in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Color.textHint)
                                Text(event.message)
                                    .font(.caption)
                                    .foregroundStyle(Color.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, Spacing.cozy)
                            .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }
                    }
                }
            }

            if !report.snapshots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("快照轨迹")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    VStack(spacing: Spacing.half) {
                        ForEach(report.snapshots) { snapshot in
                            fanqieSnapshotCard(snapshot)
                        }
                    }
                }
            }

            if !report.detailPageURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("详情链接")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    VStack(spacing: Spacing.half) {
                        ForEach(report.detailPageURLs, id: \.absoluteString) { url in
                            Text(url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.base)
                                .padding(.vertical, Spacing.cozy)
                                .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }
                    }
                }
            }

            if report.detailPageURLs.isEmpty, !report.candidateDetailPageURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("候选详情链接")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    VStack(spacing: Spacing.half) {
                        ForEach(report.candidateDetailPageURLs, id: \.absoluteString) { url in
                            Text(url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.base)
                                .padding(.vertical, Spacing.cozy)
                                .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }
                    }
                }
            }

            if !report.selectorHitNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("命中选择器")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    FlowLayoutRow(items: report.selectorHitNames)
                }
            }

            if !report.resultTextSamples.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("结果文本样本")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    VStack(spacing: Spacing.half) {
                        ForEach(report.resultTextSamples, id: \.self) { sample in
                            Text(sample)
                                .font(.caption)
                                .foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.base)
                                .padding(.vertical, Spacing.cozy)
                                .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }
                    }
                }
            }

            if !report.resultHTMLSamples.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("结果 HTML 片段")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    VStack(spacing: Spacing.half) {
                        ForEach(report.resultHTMLSamples, id: \.self) { sample in
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(sample)
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

            if let htmlResult = report.htmlResult, !htmlResult.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HTML 结果")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        Text(htmlResult)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .padding(Spacing.base)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180, maxHeight: 320)
                    .background(Color.surfacePage)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    var fanqieStructuredResultsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: 6) {
                Text("结构化书籍结果")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                metricBadge("状态", value: viewModel.fanqieStructuredStatus.title)
                metricBadge("结果数", value: "\(viewModel.fanqieStructuredResults.count)")
            }

            if let message = viewModel.fanqieStructuredMessage, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(
                        viewModel.fanqieStructuredStatus == .failed
                            ? Color.feedbackError
                            : Color.textSecondary
                    )
            }

            if viewModel.fanqieStructuredStatus == .loading {
                HStack(spacing: Spacing.half) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在解析番茄详情页...")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            } else if viewModel.fanqieStructuredResults.isEmpty {
                Text("运行番茄搜索后，这里会展示与功能页一致的书籍结果卡片。")
                    .font(.caption)
                    .foregroundStyle(Color.textHint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.base)
                    .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
            } else {
                VStack(spacing: Spacing.half) {
                    ForEach(viewModel.fanqieStructuredResults) { result in
                        XMBookSearchResultCard(result: result, keyword: viewModel.fanqieKeyword)
                            .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    }
                }
            }
        }
    }

    @ViewBuilder
    var fanqiePreviewCard: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .center, spacing: Spacing.half) {
                Text("实时页面预览")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)

                if viewModel.fanqiePreviewIsLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("预览会复用共享番茄会话，并以桌面内容模式加载，便于直接观察当前关键词对应的真实页面。")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            if let previewURL = viewModel.fanqiePreviewURL {
                FanqieLivePreviewWebView(
                    requestURL: previewURL,
                    reloadToken: viewModel.fanqiePreviewReloadToken,
                    onNavigationStart: {
                        viewModel.fanqiePreviewDidStartNavigation()
                    },
                    onNavigationFinish: { finalURL, pageTitle in
                        viewModel.fanqiePreviewDidFinishNavigation(
                            finalURL: finalURL,
                            pageTitle: pageTitle
                        )
                    },
                    onNavigationFail: { message in
                        viewModel.fanqiePreviewDidFailNavigation(message)
                    }
                )
                .frame(height: 300)
                .background(Color.surfacePage)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
                }

                labeledText("预览请求", value: previewURL.absoluteString, monospaced: true)

                if let finalURL = viewModel.fanqiePreviewFinalURL, !finalURL.isEmpty {
                    labeledText("预览终态", value: finalURL, monospaced: true)
                }

                if let pageTitle = viewModel.fanqiePreviewPageTitle, !pageTitle.isEmpty {
                    metricBadge("预览标题", value: pageTitle)
                }

                if let errorMessage = viewModel.fanqiePreviewErrorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.feedbackError)
                }
            } else {
                Text("点击“运行番茄搜索”后，这里会显示实际加载的番茄搜索页。")
                    .font(.caption)
                    .foregroundStyle(Color.textHint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.base)
                    .background(Color.surfacePage, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
            }
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

    func fanqieSnapshotCard(_ snapshot: WebHTMLFetchTestViewModel.FanqieDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                metricBadge("轮次", value: "\(snapshot.attempt)")
                metricBadge("Ready", value: snapshot.documentReadyState)
                metricBadge("宽度", value: "\(snapshot.viewportWidth)")
                metricBadge("链接", value: "\(snapshot.linkCount)")
                metricBadge("候选", value: "\(snapshot.candidateURLCount)")
                metricBadge("容器", value: "\(snapshot.resultContainerCount)")
            }

            HStack(spacing: 6) {
                metricBadge("Input", value: snapshot.hasSearchInput ? "Y" : "N")
                metricBadge("Loading", value: snapshot.hasLoadingIndicator ? "Y" : "N")
                metricBadge("Empty", value: snapshot.hasEmptyResultText ? "Y" : "N")
                metricBadge("Verify", value: snapshot.hasVerificationMarker ? "Y" : "N")
                metricBadge("force_mobile", value: snapshot.urlHasForceMobile ? "Y" : "N")
            }

            HStack(spacing: 6) {
                metricBadge("state.loading", value: snapshot.stateLoading.map { $0 ? "true" : "false" } ?? "nil")
                metricBadge("state.total", value: snapshot.stateTotal.map(String.init) ?? "nil")
                metricBadge("state.bookIDs", value: "\(snapshot.stateBookIDCount)")
                metricBadge("react.bookIDs", value: "\(snapshot.reactBookIDCount)")
            }

            if !snapshot.selectorHitNames.isEmpty {
                FlowLayoutRow(items: snapshot.selectorHitNames)
            }

            if !snapshot.resultTextSamples.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot.resultTextSamples, id: \.self) { sample in
                        Text(sample)
                            .font(.caption)
                            .foregroundStyle(Color.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text(snapshot.finalURL)
                .font(.caption2.monospaced())
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
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

private struct FanqieLivePreviewWebView: UIViewRepresentable {
    let requestURL: URL
    let reloadToken: UUID
    let onNavigationStart: () -> Void
    let onNavigationFinish: (_ finalURL: String?, _ pageTitle: String?) -> Void
    let onNavigationFail: (_ message: String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNavigationStart: onNavigationStart,
            onNavigationFinish: onNavigationFinish,
            onNavigationFail: onNavigationFail
        )
    }

    func makeUIView(context: Context) -> FanqiePreviewContainerView {
        let service = FanqieWebVerificationService.shared
        let webView = WKWebView(
            frame: FanqiePreviewContainerView.desktopViewport,
            configuration: service.makeWebViewConfiguration(preferredContentMode: .desktop)
        )
        webView.customUserAgent = XMImageRequestBuilder.browserUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.showsHorizontalScrollIndicator = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        let containerView = FanqiePreviewContainerView(webView: webView)
        context.coordinator.attach(webView: webView)
        context.coordinator.load(
            request: service.makeRequest(url: requestURL),
            reloadToken: reloadToken
        )
        return containerView
    }

    func updateUIView(_ uiView: FanqiePreviewContainerView, context: Context) {
        context.coordinator.updateCallbacks(
            onNavigationStart: onNavigationStart,
            onNavigationFinish: onNavigationFinish,
            onNavigationFail: onNavigationFail
        )
        context.coordinator.load(
            request: FanqieWebVerificationService.shared.makeRequest(url: requestURL),
            reloadToken: reloadToken
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private var latestReloadToken: UUID?
        private var onNavigationStart: () -> Void
        private var onNavigationFinish: (_ finalURL: String?, _ pageTitle: String?) -> Void
        private var onNavigationFail: (_ message: String) -> Void

        init(
            onNavigationStart: @escaping () -> Void,
            onNavigationFinish: @escaping (_ finalURL: String?, _ pageTitle: String?) -> Void,
            onNavigationFail: @escaping (_ message: String) -> Void
        ) {
            self.onNavigationStart = onNavigationStart
            self.onNavigationFinish = onNavigationFinish
            self.onNavigationFail = onNavigationFail
        }

        func attach(webView: WKWebView) {
            self.webView = webView
        }

        func updateCallbacks(
            onNavigationStart: @escaping () -> Void,
            onNavigationFinish: @escaping (_ finalURL: String?, _ pageTitle: String?) -> Void,
            onNavigationFail: @escaping (_ message: String) -> Void
        ) {
            self.onNavigationStart = onNavigationStart
            self.onNavigationFinish = onNavigationFinish
            self.onNavigationFail = onNavigationFail
        }

        func load(request: URLRequest, reloadToken: UUID) {
            guard latestReloadToken != reloadToken else { return }
            latestReloadToken = reloadToken
            onNavigationStart()
            webView?.load(request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let pageTitle = (try? await evaluateString(webView, script: "document.title")) ?? webView.title
                onNavigationFinish(webView.url?.absoluteString, pageTitle)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onNavigationStart()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onNavigationFail(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onNavigationFail(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onNavigationFail("番茄预览页面进程已终止，请重新搜索。")
        }

        private func evaluateString(_ webView: WKWebView, script: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: value as? String ?? "")
                }
            }
        }
    }
}

private final class FanqiePreviewContainerView: UIView {
    static let desktopViewport = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .clear
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let viewportSize = Self.desktopViewport.size
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = min(bounds.width / viewportSize.width, bounds.height / viewportSize.height)
        webView.bounds = Self.desktopViewport
        webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}
#endif
