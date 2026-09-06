#if DEBUG
/**
 * [INPUT]: 注入只读 Repository 或确定性模拟数据
 * [OUTPUT]: 测试中心共享总览控制器的诊断宿主
 * [POS]: Debug 只提供数据与操作入口，不维护几何、绘制或转场副本
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 测试中心沿用与生产相同的画布、瀑布流、调宽及转场。
@MainActor
final class NoteReviewSingleCanvasTransitionPrototypeController: NoteReviewCanvasOverviewController {
    private let repository: (any NoteRepositoryProtocol)?
    init(repository: (any NoteRepositoryProtocol)? = nil) {
        self.repository = repository
        super.init()
        showsDiagnosticControls = true
        resolveDataIDs = { [weak self] in
            guard let self else { throw CancellationError() }
            if usesRealData, let repository {
                return try await repository.fetchNoteReviewIDs(settings: repository.fetchNoteReviewSettings())
            }
            return (0..<selectedCount).map { Int64($0 + 1) }
        }
        sourceReader = { [weak self] ids, _ in
            guard let self else { throw CancellationError() }
            if usesRealData, let repository {
                return try await repository.fetchNoteReviewOverviewLayoutSources(noteIDs: ids)
            }
            return ids.map(CanvasLabFixtures.source)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateCountMenu() {
        countButton.configuration?.title = "\(usesRealData ? "真 " : "")\(selectedCount)"
        countButton.accessibilityLabel = "实验数据与样式，\(usesRealData ? "真实书摘" : "模拟数据") \(selectedCount) 条"
        let fixtures = [20, 374, 2000].map { count in
            UIAction(
                title: "模拟 \(count) 条",
                state: !usesRealData && count == selectedCount ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.usesRealData = false
                self.requestPreparation(count: count, preservingCurrentID: self.currentNoteID)
            }
        }
        let real = UIAction(title: "真实书摘 · 沿用回顾筛选", state: usesRealData ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.usesRealData = true
            self.requestPreparation(count: self.selectedCount, preservingCurrentID: self.currentNoteID)
        }
        real.attributes = repository == nil ? .disabled : []
        let alternate = UIAction(title: "瀑布流异样式对照", state: usesAlternateWaterfallStyle ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.usesAlternateWaterfallStyle.toggle()
            self.requestPreparation(count: self.selectedCount, preservingCurrentID: self.currentNoteID)
        }
        let nextRich = UIAction(title: "下一条可见富文本") { [weak self] _ in
            guard let self, self.transitionState == .idle, !self.isPreparingDesktopWidth, let model = self.preparedModel,
                  !model.previewRichNoteIDs.isEmpty else { return }
            let current = self.currentNoteID.flatMap { model.canvasGeometry.indexByID[$0] } ?? -1
            let next = model.previewRichNoteIDs.first { (model.canvasGeometry.indexByID[$0] ?? -1) > current }
                ?? model.previewRichNoteIDs[0]
            self.setCurrentNoteID(next, announce: false)
            if self.currentMode == .desktop {
                self.positionDesktop(on: next, zoomScale: self.desktopScrollView.zoomScale, animated: false)
            } else {
                self.positionWaterfall(on: next, animated: false)
            }
        }
        nextRich.attributes = preparedModel?.previewRichNoteIDs.isEmpty == false ? [] : .disabled
        let zoom = UIMenu(title: "桌面相机距离", children: [0.6, 0.95, 1.3].map { value in
            UIAction(title: "\(Int(value * 100))%") { [weak self] _ in
                guard let self, self.currentMode == .desktop, self.transitionState == .idle,
                      !self.isPreparingDesktopWidth else { return }
                self.positionDesktop(on: self.currentNoteID, zoomScale: value, animated: true)
            }
        })
        let isStationary = transitionState == .idle && widthSession == nil && !isPreparingDesktopWidth
            && environmentCover == nil && !desktopScrollView.isTracking && !desktopScrollView.isDragging
            && !desktopScrollView.isDecelerating && !desktopScrollView.isZooming
            && !waterfallView.isDragging && !waterfallView.isDecelerating
        let packingMenu = UIMenu(title: "桌面布局对照", children: CanvasOverviewDesktopPacking.allCases.map { value in
            UIAction(title: value.title, attributes: isStationary ? [] : .disabled,
                     state: desktopPacking == value ? .on : .off) { [weak self] _ in
                guard let self, self.widthSession == nil, self.transitionState == .idle,
                      !self.desktopScrollView.isDragging, !self.desktopScrollView.isDecelerating,
                      !self.desktopScrollView.isZooming, !self.waterfallView.isDragging,
                      !self.waterfallView.isDecelerating, self.desktopPacking != value else { return }
                self.changeDesktopCardWidth(to: self.selectedDesktopCardWidth, packing: value)
            }
        })
        countButton.menu = UIMenu(children: [UIMenu(options: .displayInline, children: fixtures + [real]),
                                             UIMenu(options: .displayInline, children: [alternate, nextRich, desktopWidthMenu(), zoom, packingMenu])])
    }


}

/// 确定性数据保留在 Debug，不进入生产组件或数据库。
private enum CanvasLabFixtures {
    private static let quotes = [
        "真正稳定的界面不是没有变化，而是每次变化都能让人理解内容从哪里来、又将去往哪里。",
        "阅读不是把所有文字同时放在眼前，而是在合适的距离里发现一条值得停留的句子。",
        "一个系统越复杂，越需要让状态的所有权保持单一，让手势只负责手势，让布局只负责布局。",
        "所谓从容，是在快速移动时依旧清楚自己的位置，也知道随时可以回到刚才读过的地方。",
        "好的工具不会要求用户理解它的实现。它只需要保持响应，保存上下文，并把内容安静地托起来。",
        "设计的秩序不等于整齐划一。轻微差异可以保留纸张的温度，但不能破坏阅读路径。",
        "当一张纸从地图移动到列表，它仍然应该被感知为同一条书摘，而不是突然出现的另一个视图。",
        "性能问题首先是时间预算问题：什么必须此刻完成，什么可以稍后完成，什么根本不应发生。",
    ]
    private static let thoughts = [
        "先保证位置稳定，再讨论丰富效果。",
        "对象身份比动画形式更重要。",
        "跟手本身就是最直接的反馈。",
        "有限内容也可以拥有开阔的空间感。",
        "不要让加载状态成为主要视觉。",
        "把不可见工作移出手势热路径。",
    ]
    private static let books = [
        "《设计的秩序》",
        "《流畅界面》",
        "《深入理解交互系统》",
        "《阅读与记忆》",
        "《复杂性的边界》",
    ]


    static func source(_ id: Int64) -> NoteReviewOverviewLayoutSource {
        let index = Int(id - 1)
        return NoteReviewOverviewLayoutSource(noteID: id,
            contentHTML: Array(repeating: quotes[index % quotes.count], count: index % 9 == 0 ? 2 : 1).joined(separator: " "),
            ideaHTML: index % 4 == 0 ? "" : thoughts[index % thoughts.count],
            bookTitle: books[index % books.count], chapterTitle: "第 \((index % 18) + 1) 章 · 片段 \(index + 1)",
            noteUpdatedDate: 1, bookUpdatedDate: 1, chapterUpdatedDate: 1)
    }
}
#endif
