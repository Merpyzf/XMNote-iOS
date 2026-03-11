/**
 * [INPUT]: 依赖 XMRemoteImage 渲染远程封面、DesignTokens 提供圆角/间距/颜色令牌
 * [OUTPUT]: 对外提供 XMBookCover（统一书籍封面组件，内置 Crop 裁切 + 占位图 + 可配装饰）
 * [POS]: UIComponents/Foundation 跨模块复用组件，消除项目内 5 处封面渲染的比例/裁切/占位重复
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 统一书籍封面组件：固定宽高比容器 + `.fill` Crop 居中裁切 + 占位图 + 可配装饰。
///
/// 三种尺寸模式：
/// - `responsive`：宽度由父容器决定，高度按宽高比自动推算
/// - `fixedWidth`：指定宽度，高度自动
/// - `fixedHeight`：指定高度，宽度自动
/// - `fixedSize`：宽高均指定（日历堆叠等场景）
///
/// 阴影不内置——日历堆叠阴影跟随 style 动态变化，排行榜有固定参数，场景差异大，外挂更灵活。
struct XMBookCover: View {
    /// 宽高比常量 0.7（28:40 = 7:10），全项目封面统一基准。
    static let aspectRatio: CGFloat = 0.7

    /// 封面表面样式，默认保持平面封面，需要 Apple Books 风格的轻量厚度边时显式开启 `.spine`。
    enum SurfaceStyle: Hashable {
        case plain
        case spine
    }

    /// 厚度边效果的实际降级层级，供组件内部和 Debug 测试页共享判断结果。
    enum SurfaceTier: String, Hashable {
        case plain
        case thinEdge
        case depthEdge

        /// 当前尺寸命中的表面层级标题，便于测试页直接显示阈值结果。
        var title: String {
            switch self {
            case .plain:
                return "Flat"
            case .thinEdge:
                return "Thin Edge"
            case .depthEdge:
                return "Depth Edge"
            }
        }
    }

    /// 边框配置。
    struct Border {
        let color: Color
        let width: CGFloat
    }

    let urlString: String
    let width: CGFloat?
    let height: CGFloat?
    let cornerRadius: CGFloat
    let border: Border?
    let placeholderBackground: Color
    let placeholderIconFont: Font?
    let priority: XMImageRequestBuilder.Priority
    let surfaceStyle: SurfaceStyle

    /// 初始化封面组件，组合尺寸、装饰与加载优先级参数。
    /// `placeholderIconFont` 为 nil 时不显示 book.closed 图标（适用于小尺寸封面）。
    init(
        urlString: String,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        cornerRadius: CGFloat = CornerRadius.inlaySmall,
        border: Border? = nil,
        placeholderBackground: Color = .tagBackground,
        placeholderIconFont: Font? = .title2,
        priority: XMImageRequestBuilder.Priority = .normal,
        surfaceStyle: SurfaceStyle = .plain
    ) {
        self.urlString = urlString
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.border = border
        self.placeholderBackground = placeholderBackground
        self.placeholderIconFont = placeholderIconFont
        self.priority = priority
        self.surfaceStyle = surfaceStyle
    }

    var body: some View {
        let resolved = resolvedSize
        let clipShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        coverContent
            .modifier(SizeModifier(width: resolved.width, height: resolved.height))
            .overlay {
                GeometryReader { proxy in
                    surfaceOverlay(for: proxy.size)
                }
                .allowsHitTesting(false)
            }
            .compositingGroup()
            .clipShape(clipShape)
            .overlay {
                if let border {
                    clipShape
                        .stroke(border.color, lineWidth: border.width)
                }
            }
            .background {
                GeometryReader { proxy in
                    surfaceShadow(for: proxy.size)
                }
            }
    }
}

// MARK: - Factory

extension XMBookCover {
    /// 响应式模式：宽度由父容器决定，高度按宽高比自动推算。
    static func responsive(
        urlString: String,
        cornerRadius: CGFloat = CornerRadius.inlaySmall,
        border: Border? = nil,
        placeholderBackground: Color = .tagBackground,
        placeholderIconFont: Font? = .title2,
        priority: XMImageRequestBuilder.Priority = .normal,
        surfaceStyle: SurfaceStyle = .plain
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority,
            surfaceStyle: surfaceStyle
        )
    }

    /// 固定宽度模式：高度 = width / aspectRatio。
    static func fixedWidth(
        _ width: CGFloat,
        urlString: String,
        cornerRadius: CGFloat = CornerRadius.inlaySmall,
        border: Border? = nil,
        placeholderBackground: Color = .tagBackground,
        placeholderIconFont: Font? = .title2,
        priority: XMImageRequestBuilder.Priority = .normal,
        surfaceStyle: SurfaceStyle = .plain
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            width: width,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority,
            surfaceStyle: surfaceStyle
        )
    }

    /// 固定高度模式：宽度 = height * aspectRatio。
    static func fixedHeight(
        _ height: CGFloat,
        urlString: String,
        cornerRadius: CGFloat = CornerRadius.inlaySmall,
        border: Border? = nil,
        placeholderBackground: Color = .tagBackground,
        placeholderIconFont: Font? = .title2,
        priority: XMImageRequestBuilder.Priority = .normal,
        surfaceStyle: SurfaceStyle = .plain
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            height: height,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority,
            surfaceStyle: surfaceStyle
        )
    }

    /// 固定尺寸模式：宽高均由调用方指定（日历堆叠等需要精确尺寸的场景）。
    static func fixedSize(
        width: CGFloat,
        height: CGFloat,
        urlString: String,
        cornerRadius: CGFloat = CornerRadius.inlaySmall,
        border: Border? = nil,
        placeholderBackground: Color = .tagBackground,
        placeholderIconFont: Font? = .title2,
        priority: XMImageRequestBuilder.Priority = .normal,
        surfaceStyle: SurfaceStyle = .plain
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            width: width,
            height: height,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority,
            surfaceStyle: surfaceStyle
        )
    }

    /// 根据实际渲染尺寸和请求样式返回封面层级，供组件和测试页统一判断阈值。
    static func resolvedSurfaceTier(for size: CGSize, requestedStyle: SurfaceStyle) -> SurfaceTier {
        guard requestedStyle == .spine else { return .plain }
        guard size.width >= SurfaceLayout.minEdgeWidth,
              size.height >= SurfaceLayout.minEdgeHeight else {
            return .plain
        }
        if size.width < SurfaceLayout.depthEdgeWidthThreshold {
            return .thinEdge
        }
        return .depthEdge
    }
}

// MARK: - Internal

private extension XMBookCover {
    enum SurfaceLayout {
        static let minEdgeWidth: CGFloat = 56
        static let minEdgeHeight: CGFloat = 80
        static let depthEdgeWidthThreshold: CGFloat = 96
    }

    /// 统一占位图：背景色 + 可选 book.closed 图标。
    var placeholder: some View {
        placeholderBackground
            .overlay {
                if let placeholderIconFont {
                    Image(systemName: "book.closed")
                        .font(placeholderIconFont)
                        .foregroundStyle(Color.textHint)
                }
            }
    }

    /// URL 是否有效（非空且非纯空白）。
    var hasValidURL: Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    /// 封面主内容：有合法 URL 时用 `.fill` Crop，否则展示占位。
    @ViewBuilder
    var coverContent: some View {
        if hasValidURL {
            XMRemoteImage(urlString: urlString, contentMode: .fill, priority: priority) {
                placeholder
            }
        } else {
            placeholder
        }
    }

    /// 根据 width/height 组合计算最终渲染尺寸。
    var resolvedSize: (width: CGFloat?, height: CGFloat?) {
        switch (width, height) {
        case let (w?, h?):
            return (w, h)
        case let (w?, nil):
            return (w, w / Self.aspectRatio)
        case let (nil, h?):
            return (h * Self.aspectRatio, h)
        case (nil, nil):
            return (nil, nil)
        }
    }

    /// 按实际尺寸叠加厚度边层，在 Apple Books 参考方向下补足轻量体积感。
    @ViewBuilder
    func surfaceOverlay(for size: CGSize) -> some View {
        let tier = Self.resolvedSurfaceTier(for: size, requestedStyle: surfaceStyle)
        switch tier {
        case .plain:
            EmptyView()
        case .thinEdge, .depthEdge:
            BookCoverSurfaceOverlay(tier: tier, size: size)
        }
    }

    /// 仅为厚度边样式补一个极轻外投影，让空间感更多来自陈列阴影而不是内部高光。
    @ViewBuilder
    func surfaceShadow(for size: CGSize) -> some View {
        let tier = Self.resolvedSurfaceTier(for: size, requestedStyle: surfaceStyle)
        if let shadowSpec = SurfaceShadowSpec(tier: tier, size: size) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.contentBackground.opacity(0.001))
                .shadow(
                    color: Color.bookCoverDropShadow,
                    radius: shadowSpec.radius,
                    x: shadowSpec.x,
                    y: shadowSpec.y
                )
        }
    }

    /// 根据是否指定尺寸应用不同 frame 策略的修饰符。
    struct SizeModifier: ViewModifier {
        let width: CGFloat?
        let height: CGFloat?

        /// 根据是否给定固定尺寸选择直接定宽高或按封面比例自适应展开。
        func body(content: Content) -> some View {
            if let width, let height {
                content.frame(width: width, height: height)
            } else {
                content
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(XMBookCover.aspectRatio, contentMode: .fit)
            }
        }
    }

    /// 厚度边装饰层只影响封面表面，把左侧体积感收成更像封面板厚度的边缘语言。
    struct BookCoverSurfaceOverlay: View {
        let tier: SurfaceTier
        let size: CGSize

        var body: some View {
            ZStack(alignment: .leading) {
                edgeBand
                foldShadow
            }
        }

        private var edgeWidth: CGFloat {
            switch tier {
            case .plain:
                return 0
            case .thinEdge:
                return min(max(size.width * 0.022, 1.0), 1.8)
            case .depthEdge:
                return min(max(size.width * 0.030, 1.6), 2.8)
            }
        }

        private var foldShadowWidth: CGFloat {
            switch tier {
            case .plain:
                return 0
            case .thinEdge:
                return min(max(size.width * 0.030, 1.4), 3.0)
            case .depthEdge:
                return min(max(size.width * 0.050, 2.4), 5.0)
            }
        }

        private var edgeBand: some View {
            HStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .bookCoverSpineDark.opacity(tier == .depthEdge ? 0.92 : 0.76), location: 0),
                        .init(color: .bookCoverSpineLight.opacity(tier == .depthEdge ? 0.74 : 0.52), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: edgeWidth)

                Spacer(minLength: 0)
            }
        }

        private var foldShadow: some View {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: edgeWidth)

                LinearGradient(
                    stops: [
                        .init(color: .bookCoverFoldShadow.opacity(tier == .depthEdge ? 0.58 : 0.38), location: 0),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: foldShadowWidth)

                Spacer(minLength: 0)
            }
        }
    }

    /// 外部轻阴影只为 `.spine` 档服务，保持与尺寸成比例的克制悬浮感。
    struct SurfaceShadowSpec {
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat

        init?(tier: SurfaceTier, size: CGSize) {
            guard size.width > 0, size.height > 0 else { return nil }
            switch tier {
            case .plain:
                return nil
            case .thinEdge:
                self.radius = min(max(size.width * 0.045, 1.6), 5.0)
                self.x = 0.6
                self.y = min(max(size.width * 0.022, 0.8), 2.4)
            case .depthEdge:
                self.radius = min(max(size.width * 0.052, 2.2), 5.0)
                self.x = 0.6
                self.y = min(max(size.width * 0.025, 1.0), 2.4)
            }
        }
    }
}

#Preview("Fixed Width") {
    VStack(spacing: Spacing.base) {
        XMBookCover.fixedWidth(
            80,
            urlString: "",
            border: .init(color: .cardBorder, width: CardStyle.borderWidth)
        )

        XMBookCover.fixedWidth(
            80,
            urlString: "",
            border: .init(color: .cardBorder, width: CardStyle.borderWidth),
            surfaceStyle: .spine
        )
    }
    .padding(Spacing.screenEdge)
}

#Preview("Responsive") {
    XMBookCover.responsive(
        urlString: "",
        border: .init(color: .cardBorder, width: CardStyle.borderWidth),
        surfaceStyle: .spine
    )
    .frame(width: 110)
    .padding(Spacing.screenEdge)
}
