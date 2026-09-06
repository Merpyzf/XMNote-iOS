/**
 * [INPUT]: 接收同一批纸张的桌面与堆叠端点、背景余纸和已准备像素
 * [OUTPUT]: 提供收拢/展开的单一显示表面和可反向时间轴
 * [POS]: 共用总览控制器的局部场景；不创建另一套模式状态机
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 每张运动纸只持有一份排版；同宽展开不用交叉淡变或重建文字。
nonisolated struct CanvasStackFlight: Sendable {
    let content: CanvasStackPaperContent
    let desktopPose: CanvasOverviewPaperPose
    let stackPose: CanvasOverviewPaperPose
    let remainsInStack: Bool
    let isAnchor: Bool
    let appearsOnDesktop: Bool
}

/// 暂存当前桌面和堆叠浏览意图，取消只恢复这个会话开始时的身份与视口。
@MainActor
final class CanvasStackBrowsingSession {
    let group: NoteReviewCanvasStackGroup
    let model: CanvasOverviewPreparedModel
    let viewport: CanvasOverviewViewportState?
    let noteID: Int64
    let fullDesktop: Bool
    var animator: UIViewPropertyAnimator?
    var scene: CanvasStackTransitionView?
    var directionIsOpening = true
    var hasCommittedTarget = false
    var finishMetrics: (() -> Void)?

    init(group: NoteReviewCanvasStackGroup, model: CanvasOverviewPreparedModel,
         viewport: CanvasOverviewViewportState?, noteID: Int64, fullDesktop: Bool) {
        self.group = group; self.model = model; self.viewport = viewport
        self.noteID = noteID; self.fullDesktop = fullDesktop
    }
}

/// 只投影准备好的像素；原生 animator 管理物理曲线，逐帧无解析、绘制或几何生成。
@MainActor
final class CanvasStackTransitionView: NoteReviewCanvasTransitionSurface {
    let flights: [CanvasStackFlight]
    let remainder = UIImageView()
    var desktopUnderlay: UIImage?
    var desktopUnderlayRect: CGRect = .zero
    var papers: [CanvasStackPaperView] = []
    let reduced: Bool
    let pileCenter: CGPoint

    init(frame: CGRect, flights: [CanvasStackFlight], remainderImage: UIImage,
         pileCenter: CGPoint, reduced: Bool) {
        self.flights = flights; self.pileCenter = pileCenter; self.reduced = reduced
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        remainder.image = remainderImage
        remainder.frame = bounds
        renderingContent.addSubview(remainder)
        for flight in flights {
            let paper = CanvasStackPaperView(content: flight.content)
            renderingContent.addSubview(paper); papers.append(paper)
            paper.layer.zPosition = flight.isAnchor ? 100 : (flight.remainsInStack ? 50 - CGFloat(papers.count) : CGFloat(papers.count))
        }
        apply(stacked: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 回到起点与到达终点都只交还显示权，纹理和文本排版从创建到回收不变。
    func apply(stacked: Bool) {
        for (flight, paper) in zip(flights, papers) {
            let pose = reduced ? flight.desktopPose : (stacked ? flight.stackPose : flight.desktopPose)
            paper.apply(pose)
            paper.alpha = (stacked ? flight.remainsInStack : flight.appearsOnDesktop) ? 1 : 0
        }
        if reduced {
            remainder.alpha = stacked ? 0 : 1
        } else {
            remainder.center = stacked ? pileCenter : CGPoint(x: bounds.midX, y: bounds.midY)
            remainder.transform = stacked ? CGAffineTransform(scaleX: 0.12, y: 0.12) : .identity
            remainder.alpha = stacked ? 0 : 1
        }
    }
}
