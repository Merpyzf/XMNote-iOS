#if DEBUG
/**
 * [INPUT]: 依赖正式 ExpandableRichText、ReadingContentTypography 阅读排版令牌与 CardContainer
 * [OUTPUT]: 对外提供 FadeOverflowTextTestView，用于验证方案 A 正式长文本披露组件
 * [POS]: Debug 测试页面，覆盖正式组件的行数、主题、富文本、压力实例、快速反转与双向文字场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 方案 A 正式组件验收页，以多种真实富文本输入检查布局、动效和主题适配。
struct FadeOverflowTextTestView: View {
    @State private var maxVisibleLines = 3
    @State private var previewMode: FadeOverflowPreviewMode = .system
    @State private var stressInstanceCount = 1
    @State private var stressTargets = (0..<30).map { _ in
        FadeOverflowStressTarget()
    }
    @State private var isStressRunning = false
    @State private var stressTask: Task<Void, Never>?

    private let samples = FadeOverflowTextSample.samples

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                controlsSection

                ForEach(samples) { sample in
                    sampleCard(sample)
                }

                stressSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("长文本披露")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(previewMode.colorScheme)
        .onDisappear {
            stressTask?.cancel()
            stressTask = nil
            isStressRunning = false
        }
    }

    private var controlsSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("正式组件参数")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("完整显示行数")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)

                    Picker("完整显示行数", selection: $maxVisibleLines) {
                        ForEach(2...5, id: \.self) { lineCount in
                            Text("\(lineCount) 行").tag(lineCount)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("外观")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)

                    Picker("外观", selection: $previewMode) {
                        ForEach(FadeOverflowPreviewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("压力实例")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)

                    Picker("压力实例", selection: $stressInstanceCount) {
                        Text("1 个").tag(1)
                        Text("10 个").tag(10)
                        Text("30 个").tag(30)
                    }
                    .pickerStyle(.segmented)
                }

                Text("以下卡片全部直接使用正式 ExpandableRichText；没有渐隐、对照分支或测试页私有测量实现。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func sampleCard(_ sample: FadeOverflowTextSample) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(sample.title)
                        .font(AppTypography.headline)
                        .foregroundStyle(Color.textPrimary)

                    Text(sample.subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                ExpandableRichText(
                    html: sample.html,
                    baseFont: ReadingContentTypography.uiBody,
                    textColor: .label,
                    lineSpacing: ReadingContentTypography.bodyLineSpacing,
                    maxLines: maxVisibleLines
                )
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var stressSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("多实例快速反转")
                            .font(AppTypography.headline)
                            .foregroundStyle(Color.textPrimary)

                        Text("在 \(stressInstanceCount) 个长文本组件之间轮转切换 100 次")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }

                    Spacer()

                    Button(isStressRunning ? "运行中" : "开始") {
                        runStress()
                    }
                    .disabled(isStressRunning)
                }

                ScrollView {
                    VStack(spacing: Spacing.base) {
                        ForEach(0..<stressInstanceCount, id: \.self) { index in
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text("实例 \(index + 1)")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textHint)

                                FadeOverflowStressItem(
                                    target: stressTargets[index],
                                    maxVisibleLines: maxVisibleLines
                                )
                            }
                        }
                    }
                    .padding(.trailing, Spacing.half)
                }
                .frame(height: stressInstanceCount == 1 ? 160 : 360)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func runStress() {
        stressTask?.cancel()
        isStressRunning = true
        stressTask = Task { @MainActor in
            for index in 0..<100 {
                guard !Task.isCancelled else { break }
                let targetIndex = index % stressInstanceCount
                stressTargets[targetIndex].isExpanded.toggle()
                try? await Task.sleep(for: .milliseconds(8))
            }
            try? await Task.sleep(for: .milliseconds(350))
            isStressRunning = false
            stressTask = nil
        }
    }
}

/// 压力页的单实例目标状态，只让本轮被操作的组件失效。
@Observable
private final class FadeOverflowStressTarget {
    var isExpanded = false
}

/// 将独立压力目标接入正式组件，避免父级数组变化无效刷新全部实例。
private struct FadeOverflowStressItem: View {
    @Bindable var target: FadeOverflowStressTarget
    let maxVisibleLines: Int

    var body: some View {
        ExpandableRichText(
            html: FadeOverflowTextSample.stressHTML,
            isExpanded: $target.isExpanded,
            baseFont: ReadingContentTypography.uiBody,
            textColor: .label,
            lineSpacing: ReadingContentTypography.bodyLineSpacing,
            maxLines: maxVisibleLines
        )
    }
}

/// 调试页的富文本长度与语义覆盖样例。
private struct FadeOverflowTextSample: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let html: String

    static let stressHTML = """
    阅读并不是把目光从一行文字移动到下一行那么简单。真正连续的阅读体验依赖稳定的行长、清晰的层级、可以预期的段落节奏，以及界面对注意力的克制。<br><br>
    当一张卡片只展示部分内容时，读者首先需要确认已经出现的内容是完整而可信的；展开动作应当紧随正文语义，而不是制造新的工具栏。状态变化期间，正文顶部、字形位置和列表滚动锚点都必须保持稳定。<br><br>
    这段压力文本还包含 <b>粗体语义</b>、English words、超长内容和多个段落，用于持续触发完整测量、折叠高度与展开高度之间的大幅变化。
    """

    static let samples: [FadeOverflowTextSample] = [
        FadeOverflowTextSample(
            id: "short",
            title: "不足三行",
            subtitle: "验证没有省略号和披露操作",
            html: "短文本应按自然高度结束，不产生额外操作行。"
        ),
        FadeOverflowTextSample(
            id: "exact",
            title: "固定三行",
            subtitle: "验证刚好达到边界时第三行完整显示",
            html: "第一行用于确认正文起点。<br>第二行保持正常阅读节奏。<br>第三行必须完整显示。"
        ),
        FadeOverflowTextSample(
            id: "one-overflow",
            title: "恰好多一行",
            subtitle: "验证第三行末尾省略号与展开基线",
            html: "第一行必须完全不受影响。<br>第二行仍然保持清晰。<br>第三行需要保留阅读完整性。<br>第四行触发披露操作。"
        ),
        FadeOverflowTextSample(
            id: "long-natural",
            title: "长段自然换行",
            subtitle: "验证大幅高度变化、快速连点与滚动稳定性",
            html: """
            沃尔特·翁的看法与之类似，在《口语文化与书面文化》这部具有里程碑意义的著作中，他强调，书写技术并不是口语的简单替代，而是会持续改变人类组织知识、保存记忆和理解世界的方式。随着文字被记录、复制和传播，思想也获得了跨越时间与空间继续生长的可能。<br><br>
            当经验只存在于当下的讲述中时，记忆必须依靠重复、节奏和共同参与来维持；文字出现以后，人们开始能够回看一个已经完成的表达，比较前后的差异，并在原有结构上继续补充新的解释。阅读因此不再只是接收信息，也成为一种可以暂停、返回和重新组织意义的活动。<br><br>
            对长篇笔记来说，收起状态需要帮助用户建立整体秩序，展开状态则需要让当前内容获得完整阅读空间。两个状态之间的变化应以正文顶部为锚点，让已经建立的阅读位置保持稳定；操作本身应当清晰可见，但不能拥有比正文更高的视觉重量。<br><br>
            最终需要验证的不只是某一张截图是否好看，还包括动态字体改变后的行高、横竖屏切换后的重新测量、快速连续点击时的动画衔接，以及很长内容展开后列表中其他卡片的位置变化。
            """
        ),
        FadeOverflowTextSample(
            id: "rich-semantics",
            title: "富文本语义",
            subtitle: "验证粗体、链接、列表、引用和多段落",
            html: """
            在 <b>Orality and Literacy</b> 中，作者用 <b>technology of the word</b> 描述文字带来的认知变化。中文与 English words 混排时，正文仍应保持统一基线。<br><br>
            <ul><li>列表第一项需要保留圆点和缩进</li><li>列表第二项用于验证截断后的展开排版</li></ul>
            <blockquote>引用内容保留原有语义色条，不退化为普通段落。</blockquote>
            末尾包含 <a href="https://example.com">链接文本</a> 与更多正文，用于确认完整富文本解析只执行一次。
            """
        ),
        FadeOverflowTextSample(
            id: "long-word-rtl",
            title: "长词与双向文字",
            subtitle: "验证窄宽度、英文长词与 RTL trailing 操作",
            html: """
            Supercalifragilisticexpialidocious 与 extraordinarilylongtechnicalidentifier 用于检查英文长词换行。<br><br>
            القراءة المستمرة تحتاج إلى إيقاع واضح ومسافة مستقرة بين السطور، ويجب أن يظهر إجراء التوسيع عند الطرف المنطقي للنص دون أن يطغى على المحتوى الأساسي。
            """
        ),
    ]
}

/// 调试页的主题预览方式。
private enum FadeOverflowPreviewMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

#Preview {
    NavigationStack {
        FadeOverflowTextTestView()
    }
}
#endif
