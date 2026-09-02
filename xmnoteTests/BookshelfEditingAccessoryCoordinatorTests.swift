/**
 * [INPUT]: 依赖 BookshelfEditingAccessoryCoordinator、纯值 accessory 快照与瞬时命令模型
 * [OUTPUT]: 验证快速重复请求单次消费，以及忙碌或退场期间拒绝新命令
 * [POS]: xmnoteTests 书架整理底部 accessory 命令防重合同测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
@testable import xmnote

@MainActor
struct BookshelfEditingAccessoryCoordinatorTests {
    @Test
    func rapidRepeatedRequestProducesOneConsumableCommand() throws {
        let coordinator = BookshelfEditingAccessoryCoordinator()
        let ownerID = UUID()
        let snapshot = BookshelfEditingAccessorySnapshot(
            ownerID: ownerID,
            source: .bookList,
            bookshelfTitle: "测试分组",
            actions: [.deleteBooks],
            enabledActions: [.deleteBooks],
            selectedCount: 1,
            isBusy: false
        )

        coordinator.activatePresentation(with: snapshot)
        let presentationID = try #require(coordinator.presentationID)
        coordinator.confirmExpanded(ownerID: ownerID, presentationID: presentationID)
        coordinator.completeEntry(ownerID: ownerID, presentationID: presentationID)

        coordinator.request(.deleteBooks)
        let firstCommand = try #require(coordinator.pendingCommand)
        coordinator.request(.deleteBooks)

        #expect(coordinator.pendingCommand?.requestID == firstCommand.requestID)
        #expect(
            coordinator.consume(
                requestID: firstCommand.requestID,
                ownerID: ownerID,
                presentationID: presentationID
            )
        )
        #expect(
            !coordinator.consume(
                requestID: firstCommand.requestID,
                ownerID: ownerID,
                presentationID: presentationID
            )
        )
    }

    @Test
    func busyOrRetiredPresentationRejectsRequest() throws {
        let coordinator = BookshelfEditingAccessoryCoordinator()
        let ownerID = UUID()
        let busySnapshot = BookshelfEditingAccessorySnapshot(
            ownerID: ownerID,
            source: .mainBookshelf,
            bookshelfTitle: "默认书架",
            actions: [.moveToGroup],
            enabledActions: [.moveToGroup],
            selectedCount: 1,
            isBusy: true
        )

        coordinator.activatePresentation(with: busySnapshot)
        let presentationID = try #require(coordinator.presentationID)
        coordinator.confirmExpanded(ownerID: ownerID, presentationID: presentationID)
        coordinator.completeEntry(ownerID: ownerID, presentationID: presentationID)
        coordinator.request(.moveToGroup)

        #expect(coordinator.pendingCommand == nil)

        coordinator.updatePayload(
            BookshelfEditingAccessorySnapshot(
                ownerID: ownerID,
                source: .mainBookshelf,
                bookshelfTitle: "默认书架",
                actions: [.moveToGroup],
                enabledActions: [.moveToGroup],
                selectedCount: 1,
                isBusy: false
            )
        )
        let transitionID = UUID()
        coordinator.beginExit(
            ownerID: ownerID,
            presentationID: presentationID,
            transitionID: transitionID
        )
        coordinator.request(.moveToGroup)

        #expect(coordinator.pendingCommand == nil)
    }
}
