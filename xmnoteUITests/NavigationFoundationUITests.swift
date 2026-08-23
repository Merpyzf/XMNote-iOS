import XCTest

/// 覆盖可恢复浏览栈、全屏任务隔离与多 Tab 独立现场的产品级导航回归路径。
@MainActor
final class NavigationFoundationUITests: XCTestCase {
    private let seedArgument = "-XMNoteUITestSeedBookshelfBookList"
    private let defaultBookshelfArgument = "-XMNoteUITestOpenDefaultBookshelf"
    private let wantReadListArgument = "-XMNoteUITestOpenWantReadList"
    private let resetSceneStateArgument = "-XMNoteUITestResetSceneState"
    private let timerDeepLinkConflictArgument = "-XMNoteUITestExerciseTimerDeepLinkConflict"
    private let bookID: Int64 = 1_001

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBrowseStackRestoresAtomicallyAndReturnsTwiceToRoot() {
        let app = launchDefaultBookshelf(resetSceneState: true)
        openReadingDetail(in: app)

        app.terminate()
        app.launchArguments = [seedArgument, defaultBookshelfArgument]
        app.launch()

        XCTAssertTrue(readingDetail(in: app).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(
            app.otherElements["app.navigation-restoration-gate"].exists,
            app.debugDescription
        )
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 1), app.debugDescription)
        tapSystemBack(in: app)
        XCTAssertTrue(bookDetail(in: app).waitForExistence(timeout: 6), app.debugDescription)
        tapSystemBack(in: app)
        XCTAssertTrue(defaultBookshelf(in: app).waitForExistence(timeout: 6), app.debugDescription)
    }

    func testFullScreenEditorLeavesUnderlyingBrowseStackUnchanged() {
        let app = launchDefaultBookshelf(resetSceneState: true)
        openBookDetail(in: app)

        let moreButton = app.buttons["更多书籍操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 4), app.debugDescription)
        moreButton.tap()
        let editButton = app.buttons["编辑书籍"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 3), app.debugDescription)
        editButton.tap()

        let cancelButton = app.buttons["取消"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 8), app.debugDescription)
        cancelButton.tap()

        XCTAssertTrue(bookDetail(in: app).waitForExistence(timeout: 6), app.debugDescription)
        tapSystemBack(in: app)
        XCTAssertTrue(defaultBookshelf(in: app).waitForExistence(timeout: 6), app.debugDescription)
    }

    func testContentViewerRootShowsCollapseControlAndPreservesBrowseStack() {
        let app = launchDefaultBookshelf(resetSceneState: true)
        openBookDetail(in: app)

        let noteListTab = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "书摘，")
        ).firstMatch
        XCTAssertTrue(noteListTab.waitForExistence(timeout: 4), app.debugDescription)
        noteListTab.tap()

        let noteButton = app.buttons["UI 测试书摘"]
        XCTAssertTrue(noteButton.waitForExistence(timeout: 6), app.debugDescription)
        noteButton.tap()

        let collapseButton = app.buttons["关闭内容查看"]
        XCTAssertTrue(collapseButton.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 1), app.debugDescription)
        collapseButton.tap()

        XCTAssertTrue(noteButton.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertFalse(collapseButton.waitForExistence(timeout: 1), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 1), app.debugDescription)

        tapSystemBack(in: app)
        XCTAssertTrue(defaultBookshelf(in: app).waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 6), app.debugDescription)
    }

    func testBookListBrowseStackSurvivesOtherTabSwitches() {
        let app = XCUIApplication()
        app.launchArguments = [seedArgument, wantReadListArgument, resetSceneStateArgument]
        app.launch()
        let bookList = app.collectionViews["bookshelf.book-list.collection"]
        XCTAssertTrue(bookList.waitForExistence(timeout: 10), app.debugDescription)

        let notesTab = app.tabBars.buttons["笔记"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 4), app.debugDescription)
        notesTab.tap()
        let profileTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 4), app.debugDescription)
        profileTab.tap()
        app.tabBars.buttons["书籍"].tap()

        XCTAssertTrue(bookList.waitForExistence(timeout: 6), app.debugDescription)
        tapSystemBack(in: app)
        XCTAssertTrue(defaultBookshelf(in: app).waitForExistence(timeout: 6), app.debugDescription)
    }

    func testPagesOpenedFromBookNoteListKeepHomeTabChromeHidden() {
        let app = launchDefaultBookshelf(resetSceneState: true)
        openBookDetail(in: app)
        let noteListTab = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "书摘、")
        ).firstMatch
        XCTAssertTrue(noteListTab.waitForExistence(timeout: 4), app.debugDescription)
        noteListTab.tap()
        XCTAssertTrue(app.buttons["UI 测试书摘"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 1), app.debugDescription)

        let readingDetailButton = app.buttons["查看《UI测试想读 01》阅读详情"]
        XCTAssertTrue(readingDetailButton.waitForExistence(timeout: 4), app.debugDescription)
        readingDetailButton.tap()

        XCTAssertTrue(readingDetail(in: app).waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 1), app.debugDescription)

        tapSystemBack(in: app)
        XCTAssertTrue(bookDetail(in: app).waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 1), app.debugDescription)
        tapSystemBack(in: app)
        XCTAssertTrue(defaultBookshelf(in: app).waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 6), app.debugDescription)
    }

    func testNewestReadingTimerDeepLinkWinsAfterFullScreenTaskDismissal() {
        let app = XCUIApplication()
        app.launchArguments = [
            seedArgument,
            timerDeepLinkConflictArgument,
            resetSceneStateArgument
        ]
        app.launch()

        let finalTimer = app.descendants(matching: .any)["reading.timer.1002"]
        XCTAssertTrue(finalTimer.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["reading.timer.1001"].exists)
        XCTAssertFalse(app.buttons["关闭阅读日历"].exists)
    }

    private func launchDefaultBookshelf(resetSceneState: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [seedArgument, defaultBookshelfArgument]
        if resetSceneState {
            app.launchArguments.append(resetSceneStateArgument)
        }
        app.launch()
        XCTAssertTrue(defaultBookshelf(in: app).waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    private func openBookDetail(in app: XCUIApplication) {
        let book = app.buttons.matching(identifier: "bookshelf.default.book.\(bookID)").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5), app.debugDescription)
        book.tap()
        XCTAssertTrue(bookDetail(in: app).waitForExistence(timeout: 8), app.debugDescription)
    }

    private func openReadingDetail(in app: XCUIApplication) {
        openBookDetail(in: app)
        let moreButton = app.buttons["更多书籍操作"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 4), app.debugDescription)
        moreButton.tap()
        let readingDetailButton = app.buttons["查看阅读详情"]
        XCTAssertTrue(readingDetailButton.waitForExistence(timeout: 3), app.debugDescription)
        readingDetailButton.tap()
        XCTAssertTrue(readingDetail(in: app).waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.tabBars.firstMatch.waitForExistence(timeout: 1), app.debugDescription)
    }

    private func tapSystemBack(in app: XCUIApplication) {
        let backButton = app.buttons["返回"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 4), app.debugDescription)
        backButton.tap()
    }

    private func defaultBookshelf(in app: XCUIApplication) -> XCUIElement {
        app.collectionViews["bookshelf.default.collection"]
    }

    private func bookDetail(in app: XCUIApplication) -> XCUIElement {
        app.otherElements["book.detail.\(bookID)"]
    }

    private func readingDetail(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["book.reading-detail.\(bookID)"]
    }
}
