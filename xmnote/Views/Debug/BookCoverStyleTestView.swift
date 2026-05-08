#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 BookCoverStyleTestViewModel 提供封面样式测试状态，依赖 XMBookCover 渲染平面/薄厚边对照，依赖 RepositoryContainer 提供真实封面样例
 * [OUTPUT]: 对外提供 BookCoverStyleTestView（书籍封面样式测试页）
 * [POS]: Debug 测试页，集中验证 Apple Books 参考方向的薄厚边封面在尺寸阈值、内容源、浅深色与业务场景接入下的视觉表现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct BookCoverStyleTestView: View {
    @State private var viewModel = BookCoverStyleTestViewModel()

    var body: some View {
        BookCoverStyleTestContentView(viewModel: viewModel)
    }
}

private struct BookCoverStyleTestContentView: View {
    @Bindable var viewModel: BookCoverStyleTestViewModel
    @Environment(RepositoryContainer.self) private var repositories

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                controlSection
                livePreviewSection
                matrixSection
                scenarioSection
                themeSection
                referenceSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("书籍封面样式")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadBookCoversIfNeeded(using: repositories.bookRepository)
        }
    }
}

private extension BookCoverStyleTestContentView {
    var controlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("控制区")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("预览模式")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.textSecondary)

                    Picker("预览模式", selection: $viewModel.displayMode) {
                        ForEach(BookCoverStyleTestViewModel.DisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("内容源")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.textSecondary)

                    Picker("内容源", selection: $viewModel.contentSource) {
                        ForEach(BookCoverStyleTestViewModel.ContentSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("实时尺寸")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.textSecondary)
                        Spacer(minLength: 0)
                        Text("\(Int(viewModel.livePreviewWidth.rounded())) × \(Int(viewModel.livePreviewHeight.rounded()))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.textPrimary)
                    }

                    Slider(value: $viewModel.livePreviewWidth, in: 48...140, step: 1)
                        .tint(Color.brand)

                    HStack(spacing: Spacing.half) {
                        statusBadge(viewModel.livePreviewTier.title, tint: Color.brand.opacity(0.14), foreground: Color.brand)
                        Text(viewModel.activeSourceTitle)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }

                    Text(viewModel.livePreviewTierDescription)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    if viewModel.isLoadingRealBookCovers {
                        HStack(spacing: Spacing.half) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在读取本地真实封面样例…")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }

                    if let message = viewModel.sourceStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.feedbackWarning)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var livePreviewSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("实时预览")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                switch viewModel.displayMode {
                case .plain:
                    previewCard(
                        title: "平面",
                        surfaceStyle: .plain,
                        width: viewModel.livePreviewWidth,
                        urlString: viewModel.livePreviewURL
                    )
                case .spine:
                    previewCard(
                        title: "Apple Books 参考",
                        surfaceStyle: .spine,
                        width: viewModel.livePreviewWidth,
                        urlString: viewModel.livePreviewURL
                    )
                case .sideBySide:
                    HStack(alignment: .top, spacing: Spacing.base) {
                        previewCard(
                            title: "平面",
                            surfaceStyle: .plain,
                            width: viewModel.livePreviewWidth,
                            urlString: viewModel.livePreviewURL
                        )
                        previewCard(
                            title: "Apple Books 参考",
                            surfaceStyle: .spine,
                            width: viewModel.livePreviewWidth,
                            urlString: viewModel.livePreviewURL
                        )
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var matrixSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("尺寸矩阵")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                ForEach(Array(viewModel.matrixSizes.enumerated()), id: \.element.id) { index, size in
                    if index > 0 {
                        Divider()
                    }

                    HStack(alignment: .top, spacing: Spacing.base) {
                        VStack(alignment: .leading, spacing: Spacing.tiny) {
                            Text(size.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text(size.note)
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 82, alignment: .leading)

                        HStack(alignment: .top, spacing: Spacing.base) {
                            matrixVariantCard(
                                title: "平面",
                                width: size.width,
                                urlString: viewModel.coverURL(at: index),
                                surfaceStyle: .plain
                            )
                            matrixVariantCard(
                                title: "薄厚边",
                                width: size.width,
                                urlString: viewModel.coverURL(at: index),
                                surfaceStyle: .spine
                            )
                        }
                    }
                    .padding(.vertical, index == 0 ? Spacing.none : Spacing.half)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var scenarioSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("业务接入预览")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                sceneBlock(title: "书库网格", subtitle: "110pt 封面作为视觉锚点，薄厚边应像轻量封面板厚度，而不是独立书脊。") {
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        cover(width: 110, urlString: viewModel.coverURL(at: 0), surfaceStyle: .spine)
                        Text("纳瓦尔宝典")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.textPrimary)
                        Text("埃里克·乔根森")
                            .font(.caption2)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(width: 110, alignment: .leading)
                }

                Divider()

                sceneBlock(title: "书籍详情", subtitle: "80pt 封面搭配信息区，厚度边要保留一点实体感，但不能把封面做成拟物书脊。") {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        cover(width: 80, urlString: viewModel.coverURL(at: 1), surfaceStyle: .spine)

                        VStack(alignment: .leading, spacing: Spacing.half) {
                            Text("把时间当作朋友")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                            Text("李笑来")
                                .font(.subheadline)
                                .foregroundStyle(Color.textSecondary)
                            Text("14 条书摘")
                                .font(.caption)
                                .foregroundStyle(Color.textHint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Divider()

                sceneBlock(title: "继续阅读", subtitle: "70pt 封面仍是辅助角色，薄厚边只提供一点厚度暗示，不与进度信息争抢。") {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        cover(width: 70, urlString: viewModel.coverURL(at: 2), surfaceStyle: .spine)

                        VStack(alignment: .leading, spacing: Spacing.half) {
                            Text("了不起的我")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                            Text("已读 68%")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                            Text("继续补全今天的阅读轨迹")
                                .font(.caption2)
                                .foregroundStyle(Color.textHint)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var themeSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("主题验证")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                HStack(alignment: .top, spacing: Spacing.base) {
                    themePreviewPane(title: "浅色", scheme: .light, index: 0)
                    themePreviewPane(title: "深色", scheme: .dark, index: 1)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var referenceSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("参考图验收")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.half) {
                    referenceRule("第一眼先看到封面正面内容，而不是左侧厚度边。")
                    referenceRule("70pt 与 80pt 档只应读成薄厚边，不能出现明确书脊。")
                    referenceRule("不要出现统一斜向高光，空间感主要来自外部轻阴影。")
                    referenceRule("边角应更接近封面板，而不是带明显圆角的 UI 卡片。")
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func previewCard(
        title: String,
        surfaceStyle: XMBookCover.SurfaceStyle,
        width: CGFloat,
        urlString: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            cover(width: width, urlString: urlString, surfaceStyle: surfaceStyle)

            Text(surfaceStyle == .spine
                 ? XMBookCover.resolvedSurfaceTier(
                    for: XMBookCover.size(width: width),
                    requestedStyle: .spine
                 ).title
                 : "Flat")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func matrixVariantCard(
        title: String,
        width: CGFloat,
        urlString: String,
        surfaceStyle: XMBookCover.SurfaceStyle
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            cover(width: width, urlString: urlString, surfaceStyle: surfaceStyle)
            Text(surfaceStyle == .spine
                 ? XMBookCover.resolvedSurfaceTier(
                    for: XMBookCover.size(width: width),
                    requestedStyle: .spine
                 ).title
                 : "Flat")
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
        }
    }

    func sceneBlock<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
    }

    func themePreviewPane(title: String, scheme: ColorScheme, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    cover(width: 92, urlString: viewModel.coverURL(at: index), surfaceStyle: .spine)

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text("设计中的设计")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("原研哉")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: Spacing.base) {
                    cover(width: 70, urlString: "", surfaceStyle: .spine)

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text("占位封面")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("检查无图时的边缘厚度和外阴影是否仍然克制。")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            .environment(\.colorScheme, scheme)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func cover(
        width: CGFloat,
        urlString: String,
        surfaceStyle: XMBookCover.SurfaceStyle
    ) -> some View {
        XMBookCover.fixedWidth(
            width,
            urlString: urlString,
            cornerRadius: surfaceStyle == .spine ? CornerRadius.inlayHairline : CornerRadius.inlaySmall,
            border: .init(
                color: surfaceStyle == .spine ? .surfaceBorderSubtle : .surfaceBorderDefault,
                width: CardStyle.borderWidth
            ),
            placeholderIconSize: .medium,
            surfaceStyle: surfaceStyle
        )
    }

    func referenceRule(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.half) {
            Circle()
                .fill(Color.brand)
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            Text(text)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func statusBadge(_ text: String, tint: Color, foreground: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(tint, in: Capsule())
    }
}

#Preview {
    NavigationStack {
        BookCoverStyleTestView()
    }
}
#endif
