/**
 * [INPUT]: 接收已准备的纸张代理或栅格，不参与业务滚动和排版
 * [OUTPUT]: 为临时显示表面提供与真实滚动面一致的系统 scroll-edge 接线
 * [POS]: NoteReviewCanvas 内部转场和调宽表层，不是第二个手势 owner
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 临时表面只接受父页面的系统边缘效果；平移、缩放和惯性始终属于真实画布。
@MainActor
class NoteReviewCanvasTransitionSurface: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentInsetAdjustmentBehavior = .never
        isScrollEnabled = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        topEdgeEffect.style = .soft
        bottomEdgeEffect.style = .soft
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 内容与表面同大，不建立可滚动距离或额外相机偏移。
    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize != bounds.size { contentSize = bounds.size }
    }
}
