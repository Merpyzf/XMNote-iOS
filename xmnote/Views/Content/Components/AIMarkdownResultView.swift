/**
 * [INPUT]: 依赖 SwiftStreamingMarkdown、AI Markdown 累积快照/生成状态、项目排版/颜色令牌与统一 Toast/分享组件
 * [OUTPUT]: 对外提供 AIMarkdownResultView、AIMarkdownInteractionController 与表格导出会话，完成按词流式渲染和交互路由
 * [POS]: Views/Content/Components 的页面私有 AI 结果组件，被 AITextResultSheet 与 AIAutoTagSheet 作为统一 Markdown 展示入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftStreamingMarkdown
import SwiftUI
import UIKit

/// 为 `StreamedMarkdownView` 提供可重订阅的完整累积快照流，渲染订阅取消不会影响 ViewModel 持有的网络任务。
nonisolated final class AIStreamingMarkdownSource: StreamedMarkdownSource, @unchecked Sendable {
    private let lock = NSLock()
    private var latestSnapshot = ""
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    /// 每次访问都建立独立订阅并立即回放最新快照，支持 Dynamic Type 变化或条件视图重建后的继续渲染。
    var text: AsyncStream<String> {
        let subscriptionID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [weak self] continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: subscriptionID)
            }
            guard let self else {
                continuation.finish()
                return
            }

            let snapshot = self.lock.withLock { () -> String in
                self.continuations[subscriptionID] = continuation
                return self.latestSnapshot
            }
            continuation.yield(snapshot)
        }
    }

    /// 发布截至当前的完整 Markdown 文本；锁只保护订阅表，回调投递在锁外完成以避免重入。
    func publish(_ snapshot: String) {
        let subscribers = lock.withLock { () -> [AsyncStream<String>.Continuation] in
            latestSnapshot = snapshot
            return Array(continuations.values)
        }
        subscribers.forEach { $0.yield(snapshot) }
    }

    deinit {
        let subscribers = lock.withLock { () -> [AsyncStream<String>.Continuation] in
            defer { continuations.removeAll() }
            return Array(continuations.values)
        }
        subscribers.forEach { $0.finish() }
    }

    /// 订阅任务结束时移除对应 continuation，避免重建渲染器后继续向旧视图投递快照。
    private func removeContinuation(id: UUID) {
        _ = lock.withLock {
            continuations.removeValue(forKey: id)
        }
    }
}

/// Markdown 表格导出会话，持有单个 UTF-8 临时文件并为 item-driven 系统分享提供稳定身份。
nonisolated struct AIMarkdownTableExport: Identifiable, Sendable {
    let id = UUID()
    let fileURL: URL

    /// 在后台任务中创建唯一纯文本文件；调用方负责在分享结束或页面离场时调用 `discard()`。
    static func make(plainText: String) throws -> AIMarkdownTableExport {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmnote-ai-markdown", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let url = directory.appendingPathComponent("AI表格-\(timestamp).txt", isDirectory: false)
        try plainText.write(to: url, atomically: true, encoding: .utf8)
        return AIMarkdownTableExport(fileURL: url)
    }

    /// 删除本会话生成的精确临时文件；文件已被系统或其他生命周期清理时保持幂等。
    func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
@Observable
/// AI Markdown 页面交互状态，统一处理智能跟随、新一轮生成重置、表格交互和安全链接策略。
final class AIMarkdownInteractionController: MarkdownListener {
    var scrollPosition = ScrollPosition(edge: .top)
    var pendingTableExport: AIMarkdownTableExport?

    @ObservationIgnored weak var toastCenter: XMToastCenter?
    @ObservationIgnored private var pendingScrollTask: Task<Void, Never>?

    private var isFollowingStreamingContent = true
    private var isAtBottom = true
    private var isProgrammaticScrollPending = false
    private var needsAnotherScroll = false
    private var reducesMotion = false

    isolated deinit {
        pendingScrollTask?.cancel()
        pendingTableExport?.discard()
    }

    /// 注入当前 Sheet 的反馈中心和 Reduce Motion 状态；对象本身由 View 的 `@State` 保持稳定。
    func configure(toastCenter: XMToastCenter, reducesMotion: Bool) {
        self.toastCenter = toastCenter
        self.reducesMotion = reducesMotion
    }

    /// 同步 Reduce Motion 环境变化，后续程序化跟随不再执行滚动动画。
    func updateReduceMotion(_ value: Bool) {
        reducesMotion = value
    }

    /// 开始新一轮生成前取消遗留滚动任务，恢复自动跟随并无动画回到顶部，避免旧结果位置污染新内容。
    func resetForNewGeneration() {
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        isFollowingStreamingContent = true
        isAtBottom = true
        isProgrammaticScrollPending = false
        needsAnotherScroll = false
        scrollToTopWithoutAnimation()
    }

    /// 流式正文退场前取消全部补滚并停止追随，无动画回到顶部，避免遗留任务干扰后续结构内容。
    func finishStreamingContent() {
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        isFollowingStreamingContent = false
        isAtBottom = true
        isProgrammaticScrollPending = false
        needsAnotherScroll = false
        scrollToTopWithoutAnimation()
        pendingScrollTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.scrollToTopWithoutAnimation()
            self.pendingScrollTask = nil
        }
    }

    /// 接收底部阈值与滚动归属；内容自然增长不会误停跟随，只有用户主动离开底部才暂停。
    func updateIsAtBottom(_ value: Bool, isPositionedByUser: Bool) {
        isAtBottom = value
        if value {
            isFollowingStreamingContent = true
        } else if isPositionedByUser {
            isFollowingStreamingContent = false
            needsAnotherScroll = false
        }
    }

    /// 独立监听 ScrollPosition 的手势归属，覆盖用户在程序化滚动途中接管而几何布尔值未变化的竞态。
    func updateIsPositionedByUser(_ value: Bool) {
        guard value, !isAtBottom else { return }
        isFollowingStreamingContent = false
        needsAnotherScroll = false
    }

    /// 把交互触发时捕获的 Markdown 快照转换为纯文本后复制，取消任务不会写入剪贴板。
    func copyMarkdown(_ markdown: String, successMessage: String = "AI 结果已复制") async {
        do {
            let plainText = try await AIMarkdownPlainTextConverter.plainText(from: markdown)
            guard !plainText.isEmpty else {
                toastCenter?.warning("当前没有可复制的内容")
                return
            }
            UIPasteboard.general.string = plainText
            toastCenter?.success(successMessage)
        } catch is CancellationError {
            return
        } catch {
            toastCenter?.error("复制失败：\(error.localizedDescription)")
        }
    }

    /// 校验 Markdown 链接 scheme；只把 HTTP(S) 交给系统，其他链接直接丢弃并反馈风险。
    func openURLResult(for url: URL) -> OpenURLAction.Result {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            toastCenter?.warning("仅支持打开 HTTP 或 HTTPS 链接")
            return .discarded
        }
        return .systemAction(url)
    }

    /// 清理系统分享面板已使用的临时文件，并释放 item-driven 会话状态。
    func discardPendingTableExport() {
        pendingTableExport?.discard()
        pendingTableExport = nil
    }

    /// 每次完成 Markdown 文档渲染后请求一次合并滚动；用户正在浏览前文时保持原位置。
    func onRender(markdown: RenderableDocument) async {
        scheduleScrollToBottomIfNeeded()
    }

    /// 表格复制复用同一语义纯文本转换，表格列以制表符保留。
    func onTableCopyTap(content: String) async {
        await copyMarkdown(content, successMessage: "表格已复制")
    }

    /// 把表格 Markdown 转成 UTF-8 纯文本文件；解析和文件写入均可取消，迟到文件会立即清理。
    func onTableDownloadTap(content: String) async {
        var generatedExport: AIMarkdownTableExport?
        do {
            let plainText = try await AIMarkdownPlainTextConverter.plainText(from: content)
            guard !plainText.isEmpty else {
                toastCenter?.warning("当前表格没有可导出的内容")
                return
            }
            generatedExport = try await Task.detached(priority: .userInitiated) {
                try AIMarkdownTableExport.make(plainText: plainText)
            }.value
            try Task.checkCancellation()
            pendingTableExport?.discard()
            pendingTableExport = generatedExport
        } catch is CancellationError {
            generatedExport?.discard()
        } catch {
            generatedExport?.discard()
            toastCenter?.error("导出表格失败：\(error.localizedDescription)")
        }
    }

    /// 使用系统默认选择菜单，当前版本不追加自定义选区动作。
    func onContextMenuAppear(id: String, selectedContent: String) async {}

    /// 使用系统默认选择菜单，当前版本不消费自定义菜单回调。
    func onContextMenuTap(id: String, selectedContent: String) async {}

    /// 图片渲染保持禁用；保留协议入口以避免未来启用图片时出现无反馈点击。
    func onImageTap(image: MarkdownImage) async {
        toastCenter?.warning("当前不支持打开 Markdown 图片")
    }

    /// 合并同一滚动动画窗口内的多次渲染回调，并在 Reduce Motion 下直接定位到底部。
    private func scheduleScrollToBottomIfNeeded() {
        guard isFollowingStreamingContent else { return }
        guard !isProgrammaticScrollPending else {
            needsAnotherScroll = true
            return
        }

        isProgrammaticScrollPending = true
        pendingScrollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled, isFollowingStreamingContent else {
                finishProgrammaticScroll()
                return
            }

            if reducesMotion {
                scrollPosition.scrollTo(edge: .bottom)
            } else {
                withAnimation(.smooth(duration: 0.16)) {
                    self.scrollPosition.scrollTo(edge: .bottom)
                }
            }

            try? await Task.sleep(for: reducesMotion ? .milliseconds(24) : .milliseconds(180))
            guard !Task.isCancelled else { return }
            finishProgrammaticScroll()
        }
    }

    /// 在当前事务中关闭动画并定位内容顶部，供流式内容切换前后复用。
    private func scrollToTopWithoutAnimation() {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .top)
        }
    }

    /// 结束本轮程序化滚动；若期间收到新渲染则立刻补一轮，跟随暂停只由用户滚动归属决定。
    private func finishProgrammaticScroll() {
        isProgrammaticScrollPending = false
        pendingScrollTask = nil
        guard needsAnotherScroll else { return }
        needsAnotherScroll = false
        scheduleScrollToBottomIfNeeded()
    }
}

/// AI 流式 Markdown 内容视图，持有稳定 Source，并以项目设计令牌覆盖第三方默认排版与颜色。
struct AIMarkdownResultView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let markdown: String
    let isStreaming: Bool
    let interactionController: AIMarkdownInteractionController

    @State private var source = AIStreamingMarkdownSource()

    var body: some View {
        StreamedMarkdownView(
            source: source,
            config: renderConfig,
            listener: interactionController
        )
        .id(dynamicTypeSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            interactionController.openURLResult(for: url)
        })
        .onChange(of: markdown, initial: true) { _, newValue in
            source.publish(newValue)
        }
    }

    /// 使用同源动态 UIKit 字体构造库配置，确保段落、标题、表格和代码遵循 XMNote 文本层级。
    private var renderConfig: MarkdownRenderConfig {
        let bodyFonts = Self.textFonts(textStyle: .body)
        let bodySemiboldFonts = Self.textFonts(textStyle: .body, regularWeight: .semibold)
        let calloutFonts = Self.textFonts(textStyle: .callout)
        let monospacedBodyFonts = Self.textFonts(textStyle: .body, design: .monospaced)
        let monospacedCaptionFonts = Self.textFonts(textStyle: .caption2, design: .monospaced)
        let linkFont = AppTypography.uiSemantic(.body)
        let inlineCodeFont = AppTypography.uiSemantic(.body, design: .monospaced)

        return MarkdownRenderConfig(
            shouldAnimateText: isStreaming && !reduceMotion,
            blockQuoteStyle: .init(textFonts: bodyFonts, textColor: .textSecondary),
            headingStyle: .init(
                h1Font: Self.textFonts(textStyle: .title2, regularWeight: .semibold),
                h2Font: Self.textFonts(textStyle: .title3, regularWeight: .semibold),
                h3Font: Self.textFonts(textStyle: .headline, regularWeight: .semibold),
                h4Font: bodySemiboldFonts,
                h5Font: bodySemiboldFonts,
                h6Font: bodySemiboldFonts,
                textColor: .textPrimary
            ),
            orderedListStyle: .init(textFonts: bodyFonts, textColor: .textPrimary),
            paragraphStyle: .init(textFonts: bodyFonts, textColor: .textPrimary),
            tableStyle: .init(
                textFonts: calloutFonts,
                headerTextColor: .textPrimary,
                regularTextColor: .textPrimary,
                headerBackgroundColor: .surfaceNested,
                borderColor: .surfaceBorderSubtle,
                actionButtonColor: .brand
            ),
            inlineStyle: .init(
                boldTextColor: .textPrimary,
                linkTextFont: linkFont,
                linkTextColor: .brandDeep,
                linkUnderlineStyle: .single,
                codeTextFont: inlineCodeFont,
                codeTextColor: .textPrimary,
                codeBackgroundColor: .controlFillSecondary,
                codeUnderlineColor: .surfaceBorderDefault
            ),
            textContextMenu: nil,
            citationConfig: .init(
                isEnabled: false,
                font: AppTypography.uiSemantic(.caption2),
                textColor: .textSecondary,
                backgroundColor: .controlFillSecondary
            ),
            codeBlockConfig: .init(
                theme: .xcode,
                backgroundColor: .surfaceNested,
                foregroundColor: .textSecondary,
                codeTextFonts: monospacedBodyFonts,
                chromeTextFonts: monospacedCaptionFonts
            ),
            blockSpacing: Spacing.comfortable,
            textSelectionConfig: .init(
                isEnabled: true,
                backgroundColor: .surfaceSheet
            ),
            thematicBreakColor: .divider,
            imageConfig: .disabled
        )
    }

    /// 为第三方渲染器提供 normal/italic/bold/boldItalic 同源字体，并让每种变体跟随当前 Dynamic Type。
    private static func textFonts(
        textStyle: UIFont.TextStyle,
        regularWeight: UIFont.Weight = .regular,
        design: UIFontDescriptor.SystemDesign = .default
    ) -> TextFonts {
        TextFonts(
            normal: AppTypography.uiSemantic(textStyle, weight: regularWeight, design: design),
            italic: AppTypography.uiSemantic(textStyle, weight: regularWeight, design: design).italicized,
            bold: AppTypography.uiSemantic(textStyle, weight: .bold, design: design),
            boldItalic: AppTypography.uiSemantic(textStyle, weight: .bold, design: design).italicized,
            preferredLetterSpacing: nil,
            preferredLineHeight: nil
        )
    }
}

private extension UIFont {
    /// 在保留 Dynamic Type 缩放结果的前提下增加斜体 trait；系统无法生成时退回原字体。
    var italicized: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitItalic)
        ) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
