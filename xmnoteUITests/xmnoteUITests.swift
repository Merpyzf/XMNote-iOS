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
    private let resetSceneStateArgument = "-XMNoteUITestResetSceneState"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAccessibilityDynamicTypeLimitsBothBookshelfGridsToTwoColumns() throws {
        let defaultApp = launchAccessibilityBookshelf(argument: defaultBookshelfArgument)
        let defaultCollection = waitForDefaultBookshelf(in: defaultApp)
        assertAccessibilityGridCellWidth(
            defaultBookButton(in: defaultApp, id: 1001),
            collection: defaultCollection,
            app: defaultApp
        )

        defaultApp.terminate()

        let secondaryApp = launchAccessibilityBookshelf(argument: wantReadArgument)
        let secondaryCollection = waitForBookList(in: secondaryApp)
        assertAccessibilityGridCellWidth(
            bookButton(in: secondaryApp, id: 1001),
            collection: secondaryCollection,
            app: secondaryApp
        )
    }

    func testDefaultBookshelfSearchFiltersClearsAndCancels() throws {
        let app = launchDefaultBookshelf()
        let collection = waitForDefaultBookshelf(in: app)

        XCTAssertFalse(app.textFields["bookshelf.default.search.field"].exists)
        XCTAssertFalse(app.buttons["bookshelf.default.search.drawer"].isHittable)

        revealSearchDrawer(
            in: collection,
            drawerIdentifier: "bookshelf.default.search.drawer",
            app: app
        )
        app.buttons["bookshelf.default.search.drawer"].tap()

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
        let collection = waitForDefaultBookshelf(in: app)

        let sortingNotice = "搜索结果暂不支持排序，清除搜索后可调整顺序"
        revealSearchDrawer(
            in: collection,
            drawerIdentifier: "bookshelf.default.search.drawer",
            app: app
        )
        app.buttons["bookshelf.default.search.drawer"].tap()

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
        let collection = waitForDefaultBookshelf(in: app)

        openDefaultBookshelfEditing(in: app)
        XCTAssertTrue(app.buttons["退出整理模式"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["在整理结果中搜索"].exists)

        revealSearchDrawer(
            in: collection,
            drawerIdentifier: "bookshelf.default.search.drawer",
            app: app
        )
        app.buttons["bookshelf.default.search.drawer"].tap()

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

    func testDefaultBookshelfSelectionLifecycleAndCellReuseStayConsistent() throws {
        let app = launchDefaultBookshelf()
        let collection = waitForDefaultBookshelf(in: app)

        openDefaultBookshelfEditing(in: app)
        let firstBook = defaultEditingBookButton(in: app, id: 1001, selected: false)
        XCTAssertTrue(firstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(firstBook.isSelected)

        firstBook.tap()
        let selectedFirstBook = defaultEditingBookButton(in: app, id: 1001, selected: true)
        XCTAssertTrue(selectedFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(selectedFirstBook.isSelected)
        XCTAssertTrue(app.staticTexts["已选 1 本"].waitForExistence(timeout: 3), app.debugDescription)

        selectedFirstBook.tap()
        let deselectedFirstBook = defaultEditingBookButton(in: app, id: 1001, selected: false)
        XCTAssertTrue(deselectedFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(deselectedFirstBook.isSelected)
        XCTAssertTrue(app.staticTexts["未选择"].waitForExistence(timeout: 3), app.debugDescription)

        let rapidlyToggledBook = defaultBookButton(in: app, id: 1001)
        rapidlyToggledBook.tap()
        rapidlyToggledBook.tap()
        XCTAssertTrue(
            defaultEditingBookButton(in: app, id: 1001, selected: false).waitForExistence(timeout: 3),
            app.debugDescription
        )

        defaultEditingBookButton(in: app, id: 1001, selected: false).tap()
        XCTAssertTrue(
            defaultEditingBookButton(in: app, id: 1001, selected: true).waitForExistence(timeout: 3),
            app.debugDescription
        )

        let reusedTarget = defaultEditingBookButton(in: app, id: 1016, selected: false)
        scrollToUpperHalf(reusedTarget, in: collection, app: app)
        XCTAssertFalse(reusedTarget.isSelected)
        XCTAssertFalse(defaultEditingBookButton(in: app, id: 1016, selected: true).exists)

        scrollTowardBeginningUntilVisible(
            defaultEditingBookButton(in: app, id: 1001, selected: true),
            in: collection,
            app: app
        )
        XCTAssertTrue(defaultEditingBookButton(in: app, id: 1001, selected: true).isSelected)

        finishBookshelfEditing(in: app)
        let browsingFirstBook = defaultBookButton(in: app, id: 1001)
        XCTAssertTrue(browsingFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(browsingFirstBook.isSelected)
        XCTAssertFalse(defaultEditingBookButton(in: app, id: 1001, selected: true).waitForExistence(timeout: 1))
        XCTAssertFalse(defaultEditingBookButton(in: app, id: 1001, selected: false).waitForExistence(timeout: 1))

        openDefaultBookshelfEditing(in: app)
        let resetFirstBook = defaultEditingBookButton(in: app, id: 1001, selected: false)
        XCTAssertTrue(resetFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(resetFirstBook.isSelected)
    }

    func testDefaultBookshelfEditingPreservesScrolledViewport() throws {
        let app = launchDefaultBookshelf()
        let collection = waitForDefaultBookshelf(in: app)
        let target = defaultBookButton(in: app, id: 1016)

        scrollToUpperHalf(target, in: collection, app: app)
        let targetFrameBeforeEditing = target.frame
        XCTAssertFalse(defaultBookButton(in: app, id: 1001).isHittable)

        openDefaultBookshelfEditing(in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(target.isHittable, app.debugDescription)
        XCTAssertFalse(defaultBookButton(in: app, id: 1001).isHittable)
        XCTAssertLessThan(
            abs(target.frame.midY - targetFrameBeforeEditing.midY),
            collection.frame.height * 0.25
        )

        finishBookshelfEditing(in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(target.isHittable, app.debugDescription)
        XCTAssertFalse(defaultBookButton(in: app, id: 1001).isHittable)
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
        XCTAssertEqual(drawer.label, "搜索书名或作者")
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
        XCTAssertTrue(app.buttons["退出整理模式"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["在整理结果中搜索"].exists)

        revealSearchDrawer(in: collection, app: app)
        let drawer = app.buttons["bookshelf.book-list.search.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))
        XCTAssertEqual(drawer.label, "搜索书名或作者")

        drawer.tap()
        let field = app.textFields["bookshelf.book-list.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        XCTAssertFalse(app.textFields["在整理结果中搜索"].exists)
    }

    func testBookListSelectionLifecycleAndCellReuseStayConsistent() throws {
        let app = launchBookList(argument: wantReadArgument)
        let collection = waitForBookList(in: app)

        openBookListEditing(in: app)
        let firstBook = editingBookButton(in: app, id: 1001, selected: false)
        XCTAssertTrue(firstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(firstBook.isSelected)

        firstBook.tap()
        let selectedFirstBook = editingBookButton(in: app, id: 1001, selected: true)
        XCTAssertTrue(selectedFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(selectedFirstBook.isSelected)
        XCTAssertTrue(app.staticTexts["已选 1 本"].waitForExistence(timeout: 3), app.debugDescription)

        selectedFirstBook.tap()
        let deselectedFirstBook = editingBookButton(in: app, id: 1001, selected: false)
        XCTAssertTrue(deselectedFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(deselectedFirstBook.isSelected)
        XCTAssertTrue(app.staticTexts["未选择"].waitForExistence(timeout: 3), app.debugDescription)

        let rapidlyToggledBook = bookButton(in: app, id: 1001)
        rapidlyToggledBook.tap()
        rapidlyToggledBook.tap()
        XCTAssertTrue(
            editingBookButton(in: app, id: 1001, selected: false).waitForExistence(timeout: 3),
            app.debugDescription
        )

        editingBookButton(in: app, id: 1001, selected: false).tap()
        XCTAssertTrue(
            editingBookButton(in: app, id: 1001, selected: true).waitForExistence(timeout: 3),
            app.debugDescription
        )

        let reusedTarget = editingBookButton(in: app, id: 1016, selected: false)
        scrollToUpperHalf(reusedTarget, in: collection, app: app)
        XCTAssertFalse(reusedTarget.isSelected)
        XCTAssertFalse(editingBookButton(in: app, id: 1016, selected: true).exists)

        scrollTowardBeginningUntilVisible(
            editingBookButton(in: app, id: 1001, selected: true),
            in: collection,
            app: app
        )
        XCTAssertTrue(editingBookButton(in: app, id: 1001, selected: true).isSelected)

        finishBookshelfEditing(in: app)
        let browsingFirstBook = bookButton(in: app, id: 1001)
        XCTAssertTrue(browsingFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(browsingFirstBook.isSelected)
        XCTAssertFalse(editingBookButton(in: app, id: 1001, selected: true).waitForExistence(timeout: 1))
        XCTAssertFalse(editingBookButton(in: app, id: 1001, selected: false).waitForExistence(timeout: 1))

        openBookListEditing(in: app)
        let resetFirstBook = editingBookButton(in: app, id: 1001, selected: false)
        XCTAssertTrue(resetFirstBook.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(resetFirstBook.isSelected)
    }

    func testBookListEditingPreservesScrolledViewport() throws {
        let app = launchBookList(argument: wantReadArgument)
        let collection = waitForBookList(in: app)
        let target = bookButton(in: app, id: 1016)

        scrollToUpperHalf(target, in: collection, app: app)
        let targetFrameBeforeEditing = target.frame
        XCTAssertFalse(bookButton(in: app, id: 1001).isHittable)

        let editButton = app.buttons["整理书籍"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3), app.debugDescription)
        editButton.tap()

        XCTAssertTrue(target.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(target.isHittable, app.debugDescription)
        XCTAssertFalse(bookButton(in: app, id: 1001).isHittable)
        XCTAssertLessThan(
            abs(target.frame.midY - targetFrameBeforeEditing.midY),
            collection.frame.height * 0.25
        )

        finishBookshelfEditing(in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(target.isHittable, app.debugDescription)
        XCTAssertFalse(bookButton(in: app, id: 1001).isHittable)
    }

    func testBookListReorderStillUsesCollectionDrag() throws {
        let app = launchBookList(argument: reorderGroupArgument)
        _ = waitForBookList(in: app)

        let editButton = app.buttons["整理书籍"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3))
        editButton.tap()
        XCTAssertTrue(app.buttons["退出整理模式"].waitForExistence(timeout: 3))

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

    func testBookCollectionManualListAndDetailOpen() throws {
        let app = launchDefaultBookshelf()
        openBookCollectionTab(in: app)

        XCTAssertTrue(app.buttons["book.collection.top.create"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["book.collection.top.more"].exists)
        XCTAssertTrue(app.staticTexts["UI测试手动书单"].waitForExistence(timeout: 3), app.debugDescription)

        app.staticTexts["UI测试手动书单"].tap()

        XCTAssertTrue(app.otherElements["book.collection.detail"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(app.buttons["book.collection.detail.add"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["适合验证书单详情的推荐语"].waitForExistence(timeout: 3), app.debugDescription)
    }

    func testBookCollectionAnnualListAndReadOnlyDetailOpen() throws {
        let app = launchDefaultBookshelf()
        openBookCollectionTab(in: app)

        selectAnnualBookCollections(in: app)

        XCTAssertTrue(app.staticTexts["2026 年阅读书单"].waitForExistence(timeout: 3), app.debugDescription)
        app.staticTexts["2026 年阅读书单"].tap()

        XCTAssertTrue(app.otherElements["book.collection.detail"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(app.staticTexts["年度书单内容自动同步"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["book.collection.detail.add"].exists)
    }

    func testBookCollectionGridReorderingPreservesSemanticViewport() throws {
        let app = launchDefaultBookshelf()
        openBookCollectionTab(in: app)
        switchBookCollectionDisplayToList(in: app)
        switchBookCollectionDisplayToGrid(in: app)

        let grid = app.scrollViews["book.collection.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 4), app.debugDescription)
        let targetGridCard = app.buttons["book.collection.grid.9116"]
        scrollToUpperHalf(targetGridCard, in: grid, app: app)
        XCTAssertFalse(app.buttons["book.collection.grid.9101"].isHittable)
        let anchorID = leadingVisibleManualCollectionID(in: grid, app: app)
        XCTAssertNotEqual(anchorID, 9_101)

        app.buttons["book.collection.top.more"].tap()
        let reorder = app.buttons["调整排序"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 3), app.debugDescription)
        reorder.tap()

        let targetRow = app.buttons["book.collection.row.\(anchorID)"]
        XCTAssertTrue(targetRow.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(targetRow.isHittable, app.debugDescription)
        XCTAssertFalse(app.buttons["book.collection.row.9101"].isHittable)

        let done = app.buttons["book.collection.top.reorder.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), app.debugDescription)
        done.tap()

        let restoredGridCard = app.buttons["book.collection.grid.\(anchorID)"]
        XCTAssertTrue(restoredGridCard.waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertTrue(restoredGridCard.isHittable, app.debugDescription)
        XCTAssertFalse(app.buttons["book.collection.grid.9101"].isHittable)
    }

    func testBookCollectionCreateEditAddAndDeleteFlow() throws {
        let app = launchDefaultBookshelf()
        openBookCollectionTab(in: app)
        switchBookCollectionDisplayToList(in: app)

        let createdTitle = "UITest Collection"
        let editedTitle = "UITest Collection Edited"

        app.buttons["book.collection.top.create"].tap()
        XCTAssertTrue(app.navigationBars["新建书单"].waitForExistence(timeout: 3), app.debugDescription)
        let createTitleField = app.textFields["书单标题"]
        XCTAssertTrue(createTitleField.waitForExistence(timeout: 3), app.debugDescription)
        createTitleField.tap()
        createTitleField.typeText(createdTitle)
        let createDescription = app.textViews.firstMatch
        XCTAssertTrue(createDescription.waitForExistence(timeout: 3), app.debugDescription)
        createDescription.tap()
        createDescription.typeText("Created by UI test")
        app.buttons["确认"].firstMatch.tap()

        let createdTitleElement = app.staticTexts[createdTitle]
        XCTAssertTrue(createdTitleElement.waitForExistence(timeout: 4), app.debugDescription)

        createdTitleElement.swipeLeft()
        let editButton = app.buttons["编辑"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 2), app.debugDescription)
        editButton.tap()

        XCTAssertTrue(app.navigationBars["编辑书单"].waitForExistence(timeout: 3), app.debugDescription)
        replaceText(in: app.textFields["书单标题"], with: editedTitle)
        app.buttons["确认"].firstMatch.tap()

        let editedTitleElement = app.staticTexts[editedTitle]
        XCTAssertTrue(editedTitleElement.waitForExistence(timeout: 4), app.debugDescription)
        editedTitleElement.tap()

        XCTAssertTrue(app.otherElements["book.collection.detail"].waitForExistence(timeout: 4), app.debugDescription)
        let addBookButton = app.buttons["book.collection.detail.add"]
        XCTAssertTrue(addBookButton.waitForExistence(timeout: 3), app.debugDescription)
        addBookButton.tap()

        XCTAssertTrue(app.navigationBars["添加书籍"].waitForExistence(timeout: 4), app.debugDescription)
        let pickerSearchField = app.searchFields["搜索书名、作者、ISBN"]
        XCTAssertTrue(pickerSearchField.waitForExistence(timeout: 3), app.debugDescription)
        pickerSearchField.tap()
        pickerSearchField.typeText("想读 03")

        let bookToAdd = app.buttons["book.picker.local.1003"]
        XCTAssertTrue(bookToAdd.waitForExistence(timeout: 4), app.debugDescription)
        bookToAdd.tap()

        let confirm = app.buttons["book.picker.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), app.debugDescription)
        confirm.tap()

        let addedBookTitle = app.staticTexts["UI测试想读 03"]
        XCTAssertTrue(addedBookTitle.waitForExistence(timeout: 5), app.debugDescription)

        let addedBookCell = app.cells.containing(.staticText, identifier: "UI测试想读 03").firstMatch
        if addedBookCell.waitForExistence(timeout: 1) {
            addedBookCell.swipeLeft()
        } else {
            addedBookTitle.swipeLeft()
        }
        let recommendButton = app.buttons["收藏理由"]
        XCTAssertTrue(recommendButton.waitForExistence(timeout: 3), app.debugDescription)
        recommendButton.tap()

        XCTAssertTrue(app.navigationBars["添加收藏理由"].waitForExistence(timeout: 3), app.debugDescription)
        let recommendEditor = app.textViews.firstMatch
        XCTAssertTrue(recommendEditor.waitForExistence(timeout: 3), app.debugDescription)
        recommendEditor.tap()
        recommendEditor.typeText("UI 自动化推荐语")
        app.buttons["确认"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["UI 自动化推荐语"].waitForExistence(timeout: 4), app.debugDescription)

        app.buttons["书单更多操作"].tap()
        let deleteMenuItem = app.buttons["删除书单"]
        XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 3), app.debugDescription)
        deleteMenuItem.tap()

        let deleteAlert = app.alerts.matching(NSPredicate(format: "label CONTAINS %@", editedTitle)).firstMatch
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 3), app.debugDescription)
        deleteAlert.buttons["删除"].tap()

        XCTAssertTrue(app.staticTexts["UI测试手动书单"].waitForExistence(timeout: 4), app.debugDescription)
        XCTAssertFalse(app.staticTexts[editedTitle].waitForExistence(timeout: 2))
    }

    private func launchBookList(argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [seedArgument, argument, resetSceneStateArgument]
        app.launch()
        return app
    }

    private func launchDefaultBookshelf() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [defaultBookshelfArgument, resetSceneStateArgument]
        app.launch()
        return app
    }

    private func launchAccessibilityBookshelf(argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            seedArgument,
            argument,
            resetSceneStateArgument,
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
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
        if organizeButton.waitForExistence(timeout: 1) {
            organizeButton.tap()
            return
        }

        let systemMenu = app.collectionViews.allElementsBoundByIndex.first { element in
            element.identifier != "bookshelf.default.collection"
                && element.frame.width > 0
                && element.frame.width < app.frame.width
        }
        XCTAssertNotNil(systemMenu, app.debugDescription)
        guard let systemMenu else { return }
        let organizeCell = systemMenu.cells.element(boundBy: 0)
        XCTAssertTrue(organizeCell.exists, app.debugDescription)
        organizeCell.tap()
    }

    private func openBookCollectionTab(in app: XCUIApplication) {
        _ = waitForDefaultBookshelf(in: app)
        let collectionTab = app.buttons["书单"]
        XCTAssertTrue(collectionTab.waitForExistence(timeout: 4), app.debugDescription)
        collectionTab.tap()

        let manualCollection = app.staticTexts["UI测试手动书单"]
        if !manualCollection.waitForExistence(timeout: 1) {
            let scopePicker = app.descendants(matching: .any)["book.collection.kind.picker"]
            XCTAssertTrue(scopePicker.waitForExistence(timeout: 3), app.debugDescription)
            scopePicker.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        }
        XCTAssertTrue(manualCollection.waitForExistence(timeout: 6), app.debugDescription)
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

    private func editingBookButton(
        in app: XCUIApplication,
        id: Int64,
        selected: Bool = false
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@",
                "bookshelf.book-list.book.\(id)",
                selected ? "已选中" : "未选中"
            )
        ).firstMatch
    }

    private func assertAccessibilityGridCellWidth(
        _ book: XCUIElement,
        collection: XCUIElement,
        app: XCUIApplication
    ) {
        XCTAssertTrue(book.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertGreaterThan(book.frame.width, collection.frame.width / 3)
        XCTAssertGreaterThan(book.frame.height, 0)
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

    private func finishBookshelfEditing(in app: XCUIApplication) {
        let done = app.buttons["退出整理模式"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 3), app.debugDescription)
        done.tap()
    }

    private func openBookListEditing(in app: XCUIApplication) {
        let editButton = app.buttons["整理书籍"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3), app.debugDescription)
        editButton.tap()
        XCTAssertTrue(app.buttons["退出整理模式"].waitForExistence(timeout: 3), app.debugDescription)
    }

    private func scrollToUpperHalf(
        _ element: XCUIElement,
        in scrollable: XCUIElement,
        app: XCUIApplication
    ) {
        for _ in 0..<14 {
            if element.exists,
               element.isHittable,
               element.frame.midY <= scrollable.frame.midY {
                return
            }
            let start = scrollable.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = scrollable.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(element.frame.midY, scrollable.frame.midY)
    }

    private func scrollTowardBeginningUntilVisible(
        _ element: XCUIElement,
        in scrollable: XCUIElement,
        app: XCUIApplication
    ) {
        for _ in 0..<14 {
            if element.exists, element.isHittable {
                return
            }
            let start = scrollable.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
            let end = scrollable.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func switchBookCollectionDisplayToGrid(in app: XCUIApplication) {
        if app.scrollViews["book.collection.grid"].exists {
            return
        }
        let more = app.buttons["book.collection.top.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3), app.debugDescription)
        more.tap()

        let displaySettings = app.buttons["显示设置"]
        XCTAssertTrue(displaySettings.waitForExistence(timeout: 3), app.debugDescription)
        displaySettings.tap()

        let displayMode = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "显示方式，当前")
        ).firstMatch
        XCTAssertTrue(displayMode.waitForExistence(timeout: 3), app.debugDescription)
        displayMode.tap()

        let gridOption = app.buttons["网格"]
        XCTAssertTrue(gridOption.waitForExistence(timeout: 3), app.debugDescription)
        gridOption.tap()

        let close = app.buttons["关闭"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3), app.debugDescription)
        close.tap()
        XCTAssertTrue(app.scrollViews["book.collection.grid"].waitForExistence(timeout: 4), app.debugDescription)
    }

    private func switchBookCollectionDisplayToList(in app: XCUIApplication) {
        if !app.scrollViews["book.collection.grid"].exists {
            return
        }
        let more = app.buttons["book.collection.top.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3), app.debugDescription)
        more.tap()

        let displaySettings = app.buttons["显示设置"]
        XCTAssertTrue(displaySettings.waitForExistence(timeout: 3), app.debugDescription)
        displaySettings.tap()

        let displayMode = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "显示方式，当前")
        ).firstMatch
        XCTAssertTrue(displayMode.waitForExistence(timeout: 3), app.debugDescription)
        displayMode.tap()

        let listOption = app.buttons["列表"]
        XCTAssertTrue(listOption.waitForExistence(timeout: 3), app.debugDescription)
        listOption.tap()

        let close = app.buttons["关闭"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3), app.debugDescription)
        close.tap()
        XCTAssertFalse(app.scrollViews["book.collection.grid"].waitForExistence(timeout: 2))
    }

    private func selectAnnualBookCollections(in app: XCUIApplication) {
        let annualButton = app.buttons["年度书单"]
        if annualButton.waitForExistence(timeout: 1) {
            annualButton.tap()
            return
        }

        let scopePicker = app.descendants(matching: .any)["book.collection.kind.picker"]
        XCTAssertTrue(scopePicker.waitForExistence(timeout: 3), app.debugDescription)
        scopePicker.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
    }

    private func leadingVisibleManualCollectionID(
        in grid: XCUIElement,
        app: XCUIApplication
    ) -> Int64 {
        let orderedIDs = [Int64(9_101)] + (9_110...9_121).map(Int64.init)
        for id in orderedIDs {
            let card = app.buttons["book.collection.grid.\(id)"]
            guard card.exists, card.isHittable else { continue }
            let visibleHeight = card.frame.intersection(grid.frame).height
            if visibleHeight >= card.frame.height * 0.5 {
                return id
            }
        }
        XCTFail(app.debugDescription)
        return 9_101
    }

    private func revealSearchDrawer(
        in collection: XCUIElement,
        drawerIdentifier: String = "bookshelf.book-list.search.drawer",
        app: XCUIApplication
    ) {
        collection.swipeDown()
        let drawer = app.buttons[drawerIdentifier]
        if !drawer.waitForExistence(timeout: 1) || !drawer.isHittable {
            collection.swipeDown()
        }
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 80))
        field.typeText(text)
    }
}
