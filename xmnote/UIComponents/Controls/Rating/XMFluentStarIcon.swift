/**
 * [INPUT]: 依赖 SwiftUI Shape/View，复用 Android Fluent 星形路径与书籍/章节收藏默认外观
 * [OUTPUT]: 对外提供 XMStarredAppearance、XMFluentStarIcon 与 XMFluentStarShape，统一收藏星标的圆润填充星形
 * [POS]: UIComponents/Controls/Rating 的跨模块星形基础设施，被 XMRatingBar 与星标章节展示消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 收藏/星标状态的外观 owner，与评分数值语义分离维护。
enum XMStarredAppearance {
    static let foreground = Color.xmHex(0xFFC500)
}

/// 单颗 Fluent 圆润星形图标，用于评分以外的星标状态展示。
struct XMFluentStarIcon: View {
    let size: CGFloat
    let color: Color

    /// 使用统一星形路径和语义色创建指定尺寸的只读图标。
    init(size: CGFloat = 16, color: Color = XMStarredAppearance.foreground) {
        self.size = size
        self.color = color
    }

    var body: some View {
        XMFluentStarShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Fluent UI 风格的圆润五角星，源路径对齐 Android FluentRatingBar。
struct XMFluentStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / Self.viewportSize
        let originX = rect.minX + (rect.width - Self.viewportSize * scale) / 2
        let originY = rect.minY + (rect.height - Self.viewportSize * scale) / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()
        path.move(to: point(10.7878, 3.10215))
        path.addCurve(
            to: point(13.209, 3.10215),
            control1: point(11.283, 2.09877),
            control2: point(12.7138, 2.09876)
        )
        path.addLine(to: point(15.567, 7.87987))
        path.addLine(to: point(20.8395, 8.64601))
        path.addCurve(
            to: point(21.5877, 10.9487),
            control1: point(21.9468, 8.80691),
            control2: point(22.3889, 10.1677)
        )
        path.addLine(to: point(17.7724, 14.6676))
        path.addLine(to: point(18.6731, 19.9189))
        path.addCurve(
            to: point(16.7143, 21.342),
            control1: point(18.8622, 21.0217),
            control2: point(17.7047, 21.8627)
        )
        path.addLine(to: point(11.9984, 18.8627))
        path.addLine(to: point(7.28252, 21.342))
        path.addCurve(
            to: point(5.32374, 19.9189),
            control1: point(6.29213, 21.8627),
            control2: point(5.13459, 21.0217)
        )
        path.addLine(to: point(6.2244, 14.6676))
        path.addLine(to: point(2.40916, 10.9487))
        path.addCurve(
            to: point(3.15735, 8.64601),
            control1: point(1.60791, 10.1677),
            control2: point(2.05005, 8.80691)
        )
        path.addLine(to: point(8.42988, 7.87987))
        path.addLine(to: point(10.7878, 3.10215))
        path.closeSubpath()
        return path
    }

    private static let viewportSize: CGFloat = 24
}

#Preview {
    XMFluentStarIcon()
        .padding()
}
