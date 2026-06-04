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
    private let wantReadArgument = "-XMNoteUITestOpenWantReadList"
    private let reorderGroupArgument = "-XMNoteUITestOpenReorderGroupList"

    override func setUpWithError() throws {
        continueAfterFailure = false
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
    }

    func testSearchDrawerCollapsesWhenEmptyAndBlurred() throws {
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
        clearButton.tap()
        XCTAssertFalse(field.waitForExistence(timeout: 2))
    }

    func testEditingUsesSameSearchDrawerInsteadOfSecondarySearchEntry() throws {
        let app = launchBookList(argument: wantReadArgument)
        let collection = waitForBookList(in: app)

        let editButton = app.buttons["整理书籍"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()
        XCTAssertTrue(app.staticTexts["选择书籍"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["搜索整理结果"].exists)
        XCTAssertFalse(app.textFields["在整理结果中搜索"].exists)

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

    private func waitForBookList(in app: XCUIApplication) -> XCUIElement {
        let collection = app.collectionViews["bookshelf.book-list.collection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 6))
        return collection
    }

    private func bookButton(in app: XCUIApplication, id: Int64) -> XCUIElement {
        app.buttons.matching(identifier: "bookshelf.book-list.book.\(id)").firstMatch
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
