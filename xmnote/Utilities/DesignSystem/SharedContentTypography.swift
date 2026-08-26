/**
 * [INPUT]: 依赖 AppTypography、SwiftUI 与 UIKit
 * [OUTPUT]: 对外提供跨书摘阅读内容与跨页阅读摘要的共享排版 token
 * [POS]: Utilities/DesignSystem 的共享内容排版层，仅承载至少两个独立生产场景复用的稳定语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 跨书摘展示场景的阅读内容排版令牌，统一正文、批注与元数据的字号和行距。
enum ReadingContentTypography {
    private static let bodyBaseSize: CGFloat = 16
    private static let annotationBaseSize: CGFloat = 14
    private static let metadataBaseSize: CGFloat = 11

    static var body: Font {
        AppTypography.fixed(
            baseSize: bodyBaseSize,
            relativeTo: .body,
            minimumPointSize: bodyBaseSize
        )
    }
    static let bodyLineSpacing: CGFloat = 7
    static var uiBody: UIFont {
        AppTypography.uiFixed(
            baseSize: bodyBaseSize,
            textStyle: .body,
            minimumPointSize: bodyBaseSize
        )
    }
    static var annotation: Font {
        AppTypography.fixed(
            baseSize: annotationBaseSize,
            relativeTo: .subheadline,
            minimumPointSize: annotationBaseSize
        )
    }
    static let annotationLineSpacing: CGFloat = 5
    static var uiAnnotation: UIFont {
        AppTypography.uiFixed(
            baseSize: annotationBaseSize,
            textStyle: .subheadline,
            minimumPointSize: annotationBaseSize
        )
    }
    static var metadata: Font {
        AppTypography.fixed(
            baseSize: metadataBaseSize,
            relativeTo: .caption2,
            minimumPointSize: metadataBaseSize
        )
    }
}

/// 跨页阅读摘要排版，仅承载阅读日历与独立单书阅读统计中已证明同语义复用的指标层级。
enum ReadingSummaryTypography {
    static let metricTitle: Font = AppTypography.captionMedium
    static let metricNumber: Font = AppTypography.title3Semibold
    static let metricUnit: Font = AppTypography.caption2Medium
    static let metricSubtitle: Font = AppTypography.caption
}
