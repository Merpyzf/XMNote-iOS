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
    /// 阅读和总览转场的原始内容层；系统边缘合成保留在外层，不能进入中断快照。
    private(set) lazy var renderingContent: UIView = {
        let content = UIView(frame: bounds)
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
        return content
    }()

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

    /// 子类以同一场景描述生成未接入系统滚动合成的冻结像素，不读取已过滤的屏幕图层。
    func preparedContentImage() -> UIImage? { nil }

    /// 第三目标准备期间保留原始内容及一次原生边缘效果；主 actor 只在中断事件捕获一次。
    func frozenContentSurface(in container: UIView) -> NoteReviewCanvasTransitionSurface? {
        guard !renderingContent.subviews.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        guard let image = preparedContentImage() else { return nil }
        let frozen = NoteReviewCanvasTransitionSurface(frame: convert(bounds, to: container))
        frozen.backgroundColor = backgroundColor
        let pixels = UIImageView(image: image)
        pixels.frame = frozen.bounds
        frozen.renderingContent.addSubview(pixels)
        return frozen
    }

    /// 离屏复用现有渲染结果，只在中断时绘制一次；不会绑定系统边缘交互或创建新排版。
    func rasterizePreparedScene(_ scene: NoteReviewCanvasTransitionSurface) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { output in
            scene.renderingContent.layer.render(in: output.cgContext)
        }
    }

    /// 新场景只接管未烘焙边缘的内容，外层冻结滚动面由宿主在同次提交中回收。
    func contentForHandoff() -> UIView {
        renderingContent.frame = frame
        renderingContent.backgroundColor = backgroundColor
        return renderingContent
    }

    /// 内容与表面同大，不建立可滚动距离或额外相机偏移。
    override func layoutSubviews() {
        super.layoutSubviews()
        if contentSize != bounds.size { contentSize = bounds.size }
    }
}
