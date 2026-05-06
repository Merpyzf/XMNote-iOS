#if DEBUG
import CoreGraphics
import Testing
@testable import xmnote

/**
 * [INPUT]: 依赖 BookshelfReorderSession 与书架领域模型构造内存样本
 * [OUTPUT]: 对外提供默认书架拖拽排序策略、命中与自动滚动计算的单元验证
 * [POS]: xmnoteTests 中的 Book 模块拖拽排序基础设施测试，不读写真实数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
struct BookshelfReorderSessionTests {
    @Test
    func policyRejectsSearchStateAndNonDefaultDimension() {
        let searchPolicy = BookshelfReorderPolicy(
            isEditing: true,
            selectedDimension: .default,
            sortMode: .custom,
            hasSearchKeyword: true,
            activeWriteAction: nil,
            contentState: .content
        )
        let statusPolicy = BookshelfReorderPolicy(
            isEditing: true,
            selectedDimension: .status,
            sortMode: .custom,
            hasSearchKeyword: false,
            activeWriteAction: nil,
            contentState: .content
        )

        #expect(!searchPolicy.isEnabled)
        #expect(searchPolicy.disabledReason == "搜索结果不支持排序，清除搜索后可调整书架顺序")
        #expect(!statusPolicy.isEnabled)
        #expect(statusPolicy.disabledReason == "仅默认书架支持拖拽排序")
    }

    @Test
    func sessionRejectsPinnedItemAsDragStart() {
        let pinned = makeItem(1, pinned: true)
        let normal = makeItem(2)
        var session = BookshelfReorderSession()

        let didBegin = session.begin(
            item: pinned,
            items: [pinned, normal],
            location: CGPoint(x: 40, y: 40),
            itemFrames: [
                pinned.id: CGRect(x: 0, y: 0, width: 80, height: 80),
                normal.id: CGRect(x: 0, y: 90, width: 80, height: 80)
            ]
        )

        #expect(!didBegin)
        #expect(session.draggedItemID == nil)
    }

    @Test
    func listDropTargetIgnoresPinnedItems() {
        let pinned = makeItem(1, pinned: true)
        let first = makeItem(2)
        let second = makeItem(3)
        var session = BookshelfReorderSession()
        let frames: [BookshelfItemID: CGRect] = [
            pinned.id: CGRect(x: 0, y: 0, width: 240, height: 70),
            first.id: CGRect(x: 0, y: 80, width: 240, height: 70),
            second.id: CGRect(x: 0, y: 160, width: 240, height: 70)
        ]
        _ = session.begin(
            item: second,
            items: [pinned, first, second],
            location: CGPoint(x: 40, y: 180),
            itemFrames: frames
        )

        let target = session.dropTarget(
            at: CGPoint(x: 40, y: 16),
            layout: .list,
            itemFrames: frames,
            items: [pinned, first, second]
        )

        #expect(target?.itemID == first.id)
        #expect(target?.placement == .before)
        #expect(target?.insertionIndex == 1)
    }

    @Test
    func gridDropTargetUsesTwoDimensionalNearestCell() {
        let first = makeItem(1)
        let second = makeItem(2)
        let third = makeItem(3)
        var session = BookshelfReorderSession()
        let frames: [BookshelfItemID: CGRect] = [
            first.id: CGRect(x: 0, y: 0, width: 90, height: 120),
            second.id: CGRect(x: 100, y: 0, width: 90, height: 120),
            third.id: CGRect(x: 0, y: 130, width: 90, height: 120)
        ]
        _ = session.begin(
            item: first,
            items: [first, second, third],
            location: CGPoint(x: 30, y: 30),
            itemFrames: frames
        )

        let target = session.dropTarget(
            at: CGPoint(x: 138, y: 44),
            layout: .grid,
            itemFrames: frames,
            items: [first, second, third]
        )

        #expect(target?.itemID == second.id)
        #expect(target?.placement == .after)
        #expect(target?.insertionIndex == 1)
    }

    @Test
    func dropTargetUsesOverlayCenterWhenFingerHasOffset() {
        let first = makeItem(1)
        let second = makeItem(2)
        var session = BookshelfReorderSession()
        let frames: [BookshelfItemID: CGRect] = [
            first.id: CGRect(x: 0, y: 0, width: 90, height: 120),
            second.id: CGRect(x: 100, y: 0, width: 90, height: 120)
        ]
        _ = session.begin(
            item: first,
            items: [first, second],
            location: CGPoint(x: 20, y: 20),
            itemFrames: frames
        )
        session.updateLocation(CGPoint(x: 145, y: 20))

        let target = session.dropTarget(
            at: session.overlayState?.center ?? .zero,
            layout: .grid,
            itemFrames: frames,
            items: [first, second]
        )

        #expect(session.overlayState?.center == CGPoint(x: 170, y: 60))
        #expect(target?.itemID == second.id)
        #expect(target?.placement == .after)
    }

    @Test
    func gridDropTargetKeepsItemOrderWhenFrameDictionaryOrderDiffers() {
        let dragged = makeItem(1)
        let left = makeItem(2)
        let right = makeItem(3)
        var session = BookshelfReorderSession()
        let frames: [BookshelfItemID: CGRect] = [
            right.id: CGRect(x: 120, y: 0, width: 80, height: 100),
            left.id: CGRect(x: 0, y: 0, width: 80, height: 100),
            dragged.id: CGRect(x: 240, y: 0, width: 80, height: 100)
        ]
        _ = session.begin(
            item: dragged,
            items: [dragged, left, right],
            location: CGPoint(x: 260, y: 40),
            itemFrames: frames
        )

        let target = session.dropTarget(
            at: CGPoint(x: 100, y: 50),
            layout: .grid,
            itemFrames: frames,
            items: [dragged, left, right]
        )

        #expect(target?.itemID == left.id)
        #expect(target?.placement == .after)
    }

    @Test
    func sameTargetAllowsPlacementChange() {
        let targetID = BookshelfItemID.book(2)
        var session = BookshelfReorderSession()
        let beforeTarget = BookshelfReorderDropTarget(
            itemID: targetID,
            placement: .before,
            insertionIndex: 1
        )
        let afterTarget = BookshelfReorderDropTarget(
            itemID: targetID,
            placement: .after,
            insertionIndex: 2
        )

        let didSetBeforeTarget = session.setDropTarget(beforeTarget)
        let didRepeatBeforeTarget = session.setDropTarget(beforeTarget)
        let didSetAfterTarget = session.setDropTarget(afterTarget)

        #expect(didSetBeforeTarget)
        #expect(!didRepeatBeforeTarget)
        #expect(didSetAfterTarget)
    }

    @Test
    func scrollGeometryMissCanPreserveLastDropTarget() {
        let first = makeItem(1)
        let second = makeItem(2)
        var session = BookshelfReorderSession()
        let frames: [BookshelfItemID: CGRect] = [
            first.id: CGRect(x: 0, y: 0, width: 90, height: 120),
            second.id: CGRect(x: 100, y: 0, width: 90, height: 120)
        ]
        _ = session.begin(
            item: first,
            items: [first, second],
            location: CGPoint(x: 20, y: 20),
            itemFrames: frames
        )
        let target = BookshelfReorderDropTarget(
            itemID: second.id,
            placement: .after,
            insertionIndex: 1
        )

        let didSetTarget = session.setDropTarget(target)

        #expect(didSetTarget)
        session.clearDropTarget(preservingCurrentTarget: true)
        #expect(session.dragTargetItemID == second.id)
        session.clearDropTarget()
        #expect(session.dragTargetItemID == first.id)
    }

    @Test
    func listDropTargetChangesAfterCrossingRowMidline() {
        let first = makeItem(1)
        let second = makeItem(2)
        let third = makeItem(3)
        var session = BookshelfReorderSession()
        let frames: [BookshelfItemID: CGRect] = [
            first.id: CGRect(x: 0, y: 0, width: 240, height: 70),
            second.id: CGRect(x: 0, y: 80, width: 240, height: 70),
            third.id: CGRect(x: 0, y: 160, width: 240, height: 70)
        ]
        _ = session.begin(
            item: second,
            items: [first, second, third],
            location: CGPoint(x: 40, y: 100),
            itemFrames: frames
        )

        let upwardTarget = session.dropTarget(
            at: CGPoint(x: 40, y: 20),
            layout: .list,
            itemFrames: frames,
            items: [first, second, third]
        )
        let downwardTarget = session.dropTarget(
            at: CGPoint(x: 40, y: 210),
            layout: .list,
            itemFrames: frames,
            items: [first, second, third]
        )

        #expect(upwardTarget?.itemID == first.id)
        #expect(upwardTarget?.placement == .before)
        #expect(upwardTarget?.insertionIndex == 0)
        #expect(downwardTarget?.itemID == third.id)
        #expect(downwardTarget?.placement == .after)
        #expect(downwardTarget?.insertionIndex == 2)
    }

    @Test
    func autoScrollDeltaHonorsEdgesAndBounds() {
        let middle = BookshelfReorderScrollSnapshot(
            contentOffsetY: 100,
            contentHeight: 1200,
            viewportHeight: 400
        )
        let top = BookshelfReorderScrollSnapshot(
            contentOffsetY: 0,
            contentHeight: 1200,
            viewportHeight: 400
        )
        let bottom = BookshelfReorderScrollSnapshot(
            contentOffsetY: 800,
            contentHeight: 1200,
            viewportHeight: 400
        )

        #expect(BookshelfReorderSession.autoScrollDelta(locationY: 20, scrollSnapshot: middle) < 0)
        #expect(BookshelfReorderSession.autoScrollDelta(locationY: 380, scrollSnapshot: middle) > 0)
        #expect(BookshelfReorderSession.autoScrollDelta(locationY: 20, scrollSnapshot: top) == 0)
        #expect(BookshelfReorderSession.autoScrollDelta(locationY: 380, scrollSnapshot: bottom) == 0)
    }
}

private func makeItem(
    _ id: Int64,
    pinned: Bool = false
) -> BookshelfItem {
    BookshelfItem(
        id: .book(id),
        pinned: pinned,
        pinOrder: pinned ? id : 0,
        sortOrder: id,
        content: .book(
            BookshelfBookPayload(
                id: id,
                name: "Book \(id)",
                author: "Author",
                cover: "",
                readStatusId: 0,
                noteCount: 0
            )
        )
    )
}
#endif
