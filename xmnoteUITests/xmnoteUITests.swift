//
//  xmnoteUITests.swift
//  xmnoteUITests
//
//  Created by 王珂 on 2026/2/9.
//

import XCTest

@MainActor
final class BookshelfBookListSearchDrawerUITests: XCTestCase {
    private let seedArgument = "-XMNoteUITestSeedBookshelfBookList"
    private let defaultBookshelfArgument = "-XMNoteUITestOpenDefaultBookshelf"
    private let wantReadArgument = "-XMNoteUITestOpenWantReadList"
    private let reorderGroupArgument = "-XMNoteUITestOpenReorderGroupList"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDefaultBookshelfSearchFiltersClearsAndCancels() throws {
        let app = launchDefaultBookshelf()
        _ = waitForDefaultBookshelf(in: app)

        XCTAssertFalse(app.textFields["bookshelf.default.search.field"].exists)
        XCTAssertFalse(app.buttons["bookshelf.default.search.drawer"].exists)

        let activateSearch = app.buttons["bookshelf.default.search.activate"]
        XCTAssertTrue(activateSearch.waitForExistence(timeout: 4))
        activateSearch.tap()

        let field = app.textFields["bookshelf.default.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("想读 01")

        XCTAssertTrue(defaultBookButton(in: app, id: 1001).waitForExistence(timeout: 3))
        XCTAssertFalse(defaultBookButton(in: app, id: 1002).waitForExistence(timeout: 1))

        let clearButton = app.buttons["bookshelf.default.search.clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 2))
        clearButton.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertTrue(defaultBookButton(in: app, id: 1002).waitForExistence(timeout: 3))

        let cancelButton = app.buttons["bookshelf.default.search.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.tap()
        XCTAssertFalse(field.waitForExistence(timeout: 2))
        XCTAssertTrue(defaultBookButton(in: app, id: 1001).waitForExistence(timeout: 2))
    }

    func testDefaultBookshelfSearchExplainsSortingDisabledInEditing() throws {
        let app = launchDefaultBookshelf()
        _ = waitForDefaultBookshelf(in: app)

        let sortingNotice = "搜索结果暂不支持排序，清除搜索后可调整顺序"
        let activateSearch = app.buttons["bookshelf.default.search.activate"]
        XCTAssertTrue(activateSearch.waitForExistence(timeout: 4))
        activateSearch.tap()

        let field = app.textFields["bookshelf.default.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("想读 01")

        XCTAssertFalse(app.staticTexts[sortingNotice].waitForExistence(timeout: 1))
        openDefaultBookshelfEditing(in: app)
        XCTAssertTrue(app.staticTexts[sortingNotice].waitForExistence(timeout: 3))
    }

    func testDefaultBookshelfEditingSearchUsesSharedSurfaceAndSelectsVisibleResults() throws {
        let app = launchDefaultBookshelf()
        _ = waitForDefaultBookshelf(in: app)

        openDefaultBookshelfEditing(in: app)
        XCTAssertTrue(app.staticTexts["选择书籍"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["在整理结果中搜索"].exists)

        let editSearchButton = app.buttons["bookshelf.edit.search.activate"]
        XCTAssertTrue(editSearchButton.waitForExistence(timeout: 3))
        editSearchButton.tap()

        let field = app.textFields["bookshelf.default.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("想读 01")

        let selectResults = app.buttons["全选结果"]
        XCTAssertTrue(selectResults.waitForExistence(timeout: 3))
        selectResults.tap()

        XCTAssertTrue(defaultEditingBookButton(in: app, id: 1001, selected: true).waitForExistence(timeout: 3))
        XCTAssertFalse(defaultEditingBookButton(in: app, id: 1002, selected: true).waitForExistence(timeout: 1))

        let cancelSearch = app.buttons["bookshelf.default.search.cancel"]
        XCTAssertTrue(cancelSearch.waitForExistence(timeout: 2))
        cancelSearch.tap()
        XCTAssertTrue(defaultEditingBookButton(in: app, id: 1001, selected: true).waitForExistence(timeout: 3))
    }

    func testSearchDrawerHiddenByDefaultAndRevealedByPull() throws {
        let app = launchBookList(argument: wantReadArgument)
        let collection = waitForBookList(in: app)

        XCTAssertFalse(app.staticTexts["26本"].exists)
        XCTAssertFalse(app.textFields["bookshelf.book-list.search.field"].exists)
        XCTAssertFalse(app.buttons["bookshelf.book-list.search.drawer"].isHittable)

        revealSearchDrawer(in: collection, app: app)

        let drawer = app.buttons["bookshelf.book-list.search.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))
        XCTAssertTrue(drawer.isHittable)
        XCTAssertTrue(drawer.label.contains("在 26 本中搜索"))
    }

    func testSearchDrawerPinsWhileSearching() throws {
        let app = launchBookList(argument: wantReadArgument)
        let collection = waitForBookList(in: app)
        revealSearchDrawer(in: collection, app: app)

        app.buttons["bookshelf.book-list.search.drawer"].tap()

        let field = app.textFields["bookshelf.book-list.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("01")

        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["bookshelf.book-list.search.clear"].exists)
        XCTAssertTrue(bookButton(in: app, id: 1001).waitForExistence(timeout: 2))
        XCTAssertFalse(bookButton(in: app, id: 1002).waitForExistence(timeout: 1))
    }

    func testSearchDrawerClearsWithFocusAndCancelsBackToList() throws {
        let app = launchBookList(argument: wantReadArgument)
        let collection = waitForBookList(in: app)
        revealSearchDrawer(in: collection, app: app)

        app.buttons["bookshelf.book-list.search.drawer"].tap()

        let field = app.textFields["bookshelf.book-list.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.tap()
        field.typeText("01")

        let clearButton = app.buttons["bookshelf.book-list.search.clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 2))
        clearButton.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertTrue(bookButton(in: app, id: 1002).waitForExistence(timeout: 3))
        let cancelButton = app.buttons["bookshelf.book-list.search.cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.tap()
        XCTAssertFalse(field.waitForExistence(timeout: 2))
    }

    func testEditingUsesSameSearchDrawerInsteadOfSecondarySearchEntry() throws {
        let app = launchBookList(argument: wantReadArgument)
        let collection = waitForBookList(in: app)

        let editButton = app.buttons["整理书籍"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()
        XCTAssertTrue(app.staticTexts["选择书籍"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["在整理结果中搜索"].exists)
        XCTAssertTrue(app.buttons["bookshelf.edit.search.activate"].exists)

        revealSearchDrawer(in: collection, app: app)
        let drawer = app.buttons["bookshelf.book-list.search.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))
        XCTAssertTrue(drawer.label.contains("在 26 本中搜索"))

        drawer.tap()
        let field = app.textFields["bookshelf.book-list.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["在整理结果中搜索"].exists)
    }

    func testBookListReorderStillUsesCollectionDrag() throws {
        let app = launchBookList(argument: reorderGroupArgument)
        _ = waitForBookList(in: app)

        let editButton = app.buttons["整理书籍"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()
        XCTAssertTrue(app.staticTexts["选择书籍"].waitForExistence(timeout: 3))

        let firstBook = editingBookButton(in: app, id: 2001)
        let targetBook = editingBookButton(in: app, id: 2004)
        XCTAssertTrue(firstBook.waitForExistence(timeout: 3))
        XCTAssertTrue(targetBook.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["bookshelf.book-list.search.drawer"].isHittable)

        let firstFrameBefore = firstBook.frame
        var movedFrame = firstFrameBefore
        for _ in 0..<2 {
            performReorderDrag(from: editingBookButton(in: app, id: 2001), to: targetBook)
            let movedFirstBook = bookButton(in: app, id: 2001)
            XCTAssertTrue(movedFirstBook.waitForExistence(timeout: 3), app.debugDescription)
            movedFrame = movedFirstBook.frame
            if movedFrame != firstFrameBefore {
                break
            }
        }
        XCTAssertNotEqual(movedFrame, firstFrameBefore)
    }

    private func launchBookList(argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [seedArgument, argument]
        app.launch()
        return app
    }

    private func launchDefaultBookshelf() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [defaultBookshelfArgument]
        app.launch()
        return app
    }

    private func waitForDefaultBookshelf(in app: XCUIApplication) -> XCUIElement {
        let collection = app.collectionViews["bookshelf.default.collection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(defaultBookButton(in: app, id: 1001).waitForExistence(timeout: 4), app.debugDescription)
        return collection
    }

    private func openDefaultBookshelfEditing(in app: XCUIApplication) {
        let moreButton = app.buttons["书架更多操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 4), app.debugDescription)
        moreButton.tap()

        let organizeButton = app.buttons["书籍整理"]
        XCTAssertTrue(organizeButton.waitForExistence(timeout: 3), app.debugDescription)
        organizeButton.tap()
    }

    private func waitForBookList(in app: XCUIApplication) -> XCUIElement {
        let collection = app.collectionViews["bookshelf.book-list.collection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 6))
        return collection
    }

    private func bookButton(in app: XCUIApplication, id: Int64) -> XCUIElement {
        app.buttons.matching(identifier: "bookshelf.book-list.book.\(id)").firstMatch
    }

    private func defaultBookButton(in app: XCUIApplication, id: Int64) -> XCUIElement {
        app.buttons.matching(identifier: "bookshelf.default.book.\(id)").firstMatch
    }

    private func defaultEditingBookButton(in app: XCUIApplication, id: Int64, selected: Bool) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "bookshelf.default.book.\(id)",
                selected ? "已选中" : "未选中"
            )
        ).firstMatch
    }

    private func editingBookButton(in app: XCUIApplication, id: Int64) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "bookshelf.book-list.book.\(id)", "未选中")
        ).firstMatch
    }

    private func performReorderDrag(from source: XCUIElement, to target: XCUIElement) {
        let start = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
        start.press(
            forDuration: 1.5,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
    }

    private func revealSearchDrawer(in collection: XCUIElement, app: XCUIApplication) {
        collection.swipeDown()
        let drawer = app.buttons["bookshelf.book-list.search.drawer"]
        if !drawer.waitForExistence(timeout: 1) || !drawer.isHittable {
            collection.swipeDown()
        }
    }
}
