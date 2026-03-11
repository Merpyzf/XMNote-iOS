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
        priority: XMImageRequestBuilder.Priority = .normal
    ) {
        self.urlString = urlString
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.border = border
        self.placeholderBackground = placeholderBackground
        self.placeholderIconFont = placeholderIconFont
        self.priority = priority
    }

    var body: some View {
        let resolved = resolvedSize
        coverContent
            .modifier(SizeModifier(width: resolved.width, height: resolved.height))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(border.color, lineWidth: border.width)
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
        priority: XMImageRequestBuilder.Priority = .normal
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority
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
        priority: XMImageRequestBuilder.Priority = .normal
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            width: width,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority
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
        priority: XMImageRequestBuilder.Priority = .normal
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            height: height,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority
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
        priority: XMImageRequestBuilder.Priority = .normal
    ) -> XMBookCover {
        XMBookCover(
            urlString: urlString,
            width: width,
            height: height,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: placeholderBackground,
            placeholderIconFont: placeholderIconFont,
            priority: priority
        )
    }
}

// MARK: - Internal

private extension XMBookCover {
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
}

#Preview("Fixed Width") {
    XMBookCover.fixedWidth(
        80,
        urlString: "",
        border: .init(color: .cardBorder, width: CardStyle.borderWidth)
    )
    .padding(Spacing.screenEdge)
}

#Preview("Responsive") {
    XMBookCover.responsive(
        urlString: "",
        border: .init(color: .cardBorder, width: CardStyle.borderWidth)
    )
    .frame(width: 110)
    .padding(Spacing.screenEdge)
}
