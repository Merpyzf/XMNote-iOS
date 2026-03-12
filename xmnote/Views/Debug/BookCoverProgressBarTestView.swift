#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 BookCoverProgressBar 与 XMBookCover 提供封面叠层渲染，依赖 DesignTokens 与 CardContainer 组织测试页布局
 * [OUTPUT]: 对外提供 BookCoverProgressBarTestView（封面阅读进度条测试页）
 * [POS]: Debug 测试页，集中验证封面底部玻璃进度条在不同进度、尺寸、封面样式与内容源下的表现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct BookCoverProgressBarTestView: View {
    private enum ContentSource: String, CaseIterable, Identifiable {
        case sample
        case placeholder

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sample:
                return "样例"
            case .placeholder:
                return "占位"
            }
        }
    }

    private struct CoverWidthOption: Identifiable, Hashable {
        let width: CGFloat
        let title: String

        var id: CGFloat { width }
    }

    @State private var progress: Double = 0.62
    @State private var selectedWidth: CoverWidthOption = .init(width: 80, title: "80pt")
    @State private var surfaceStyle: XMBookCover.SurfaceStyle = .spine
    @State private var contentSource: ContentSource = .sample

    private let widthOptions: [CoverWidthOption] = [
        .init(width: 54, title: "54pt"),
        .init(width: 70, title: "70pt"),
        .init(width: 80, title: "80pt"),
        .init(width: 110, title: "110pt")
    ]

    private let sampleURLs: [String] = [
        "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Example.jpg/320px-Example.jpg",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/8/84/Example.svg/320px-Example.svg.png",
        "https://www.gstatic.com/webp/gallery/1.sm.webp",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/f/fa/Apple_logo_black.svg/320px-Apple_logo_black.svg.png"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                controlSection
                livePreviewSection
                progressMatrixSection
                sizeMatrixSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("封面阅读进度条")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension BookCoverProgressBarTestView {
    var controlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("控制区")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.half) {
                    headerLine(title: "当前进度", value: percentText(progress))

                    Slider(value: $progress, in: 0...1)
                        .tint(Color.brand)
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("封面宽度")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.textSecondary)

                    Picker("封面宽度", selection: $selectedWidth) {
                        ForEach(widthOptions) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("封面样式")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.textSecondary)

                    Picker("封面样式", selection: $surfaceStyle) {
                        Text("平面").tag(XMBookCover.SurfaceStyle.plain)
                        Text("薄厚边").tag(XMBookCover.SurfaceStyle.spine)
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("内容源")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.textSecondary)

                    Picker("内容源", selection: $contentSource) {
                        ForEach(ContentSource.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
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

                HStack(alignment: .top, spacing: Spacing.double) {
                    coverPreview(width: selectedWidth.width, progress: progress, urlString: sampleURL(at: 0))

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        labelBadge(title: selectedWidth.title)
                        labelBadge(title: surfaceStyle == .spine ? "薄厚边" : "平面")
                        labelBadge(title: contentSource.title)

                        Text("底部偏移与左右留白会随封面尺寸收敛，小封面保持细条感，大封面保持悬浮感。")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var progressMatrixSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("进度矩阵")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        ForEach([0.0, 0.25, 0.6, 1.0], id: \.self) { value in
                            VStack(alignment: .leading, spacing: Spacing.half) {
                                coverPreview(width: selectedWidth.width, progress: value, urlString: sampleURL(at: Int(value * 10)))
                                Text(percentText(value))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var sizeMatrixSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("尺寸矩阵")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        ForEach(widthOptions) { option in
                            VStack(alignment: .leading, spacing: Spacing.half) {
                                coverPreview(width: option.width, progress: progress, urlString: sampleURL(at: Int(option.width)))
                                Text(option.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.textPrimary)
                                Text(percentText(progress))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func coverPreview(width: CGFloat, progress: Double, urlString: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            XMBookCover.fixedWidth(
                width,
                urlString: urlString,
                border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth),
                surfaceStyle: surfaceStyle
            )
            .overlay {
                BookCoverProgressBar(progress: progress)
            }
            .shadow(
                color: Color.bookCoverDropShadow.opacity(surfaceStyle == .spine ? 0.34 : 0.18),
                radius: surfaceStyle == .spine ? 2.2 : 1.2,
                x: 0,
                y: surfaceStyle == .spine ? 1.2 : 0.8
            )

            Text("\(Int(width.rounded())) × \(Int((width / XMBookCover.aspectRatio).rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.textHint)
        }
    }

    func headerLine(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.textPrimary)
        }
    }

    func labelBadge(title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.half)
            .background(Color.surfaceNested, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }
    }

    func percentText(_ progress: Double) -> String {
        "\(Int((min(1, max(0, progress)) * 100).rounded()))%"
    }

    func sampleURL(at index: Int) -> String {
        guard contentSource == .sample else { return "" }
        return sampleURLs[index % sampleURLs.count]
    }
}

#Preview {
    NavigationStack {
        BookCoverProgressBarTestView()
    }
}
#endif
