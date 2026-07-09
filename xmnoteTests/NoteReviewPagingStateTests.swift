import CoreGraphics
import Testing
@testable import xmnote

@MainActor
struct NoteReviewPagingStateTests {
    @Test
    func initialSelectionUsesFirstLoadedItem() {
        let state = NoteReviewPagingState(
            itemIDs: [10, 20, 30],
            selection: nil,
            hasMoreItems: false,
            isLoopingEnabled: true
        )

        #expect(state.normalizedSelection == 10)
        #expect(state.currentIndex == 0)
    }

    @Test
    func nextAndPreviousMoveThroughLoadedItems() {
        var state = NoteReviewPagingState(
            itemIDs: [10, 20, 30],
            selection: 20,
            hasMoreItems: false,
            isLoopingEnabled: true
        )

        #expect(state.nextID() == 30)
        #expect(state.previousID() == 10)

        state.navigate(.next)
        #expect(state.normalizedSelection == 30)

        state.navigate(.previous)
        #expect(state.normalizedSelection == 20)
    }

    @Test
    func loadedBoundaryWaitsForMoreItemsBeforeLooping() {
        let loadingState = NoteReviewPagingState(
            itemIDs: [10, 20, 30],
            selection: 30,
            hasMoreItems: true,
            isLoopingEnabled: true
        )

        #expect(loadingState.nextID() == nil)

        let completeState = NoteReviewPagingState(
            itemIDs: [10, 20, 30],
            selection: 30,
            hasMoreItems: false,
            isLoopingEnabled: true
        )

        #expect(completeState.nextID() == 10)
    }

    @Test
    func applyingAppendedItemsPreservesCurrentSelection() {
        var state = NoteReviewPagingState(
            itemIDs: [10, 20],
            selection: 20,
            hasMoreItems: true,
            isLoopingEnabled: true
        )

        state.applyItems([10, 20, 30, 40], hasMoreItems: false)

        #expect(state.normalizedSelection == 20)
        #expect(state.nextID() == 30)
    }

    @Test
    func applyingResetItemsFallsBackToFirstAvailableItem() {
        var state = NoteReviewPagingState(
            itemIDs: [10, 20],
            selection: 20,
            hasMoreItems: true,
            isLoopingEnabled: true
        )

        state.applyItems([70, 80], hasMoreItems: false)

        #expect(state.normalizedSelection == 70)
        #expect(state.currentIndex == 0)
    }

    @Test
    func emptyAndSingleItemStatesDoNotInventDestinations() {
        let emptyState = NoteReviewPagingState<Int>(
            itemIDs: [],
            selection: nil,
            hasMoreItems: false,
            isLoopingEnabled: true
        )

        #expect(emptyState.normalizedSelection == nil)
        #expect(emptyState.nextID() == nil)
        #expect(emptyState.previousID() == nil)

        let singleState = NoteReviewPagingState(
            itemIDs: [10],
            selection: 10,
            hasMoreItems: false,
            isLoopingEnabled: true
        )

        #expect(singleState.nextID() == nil)
        #expect(singleState.previousID() == nil)
    }

    @Test
    func selectionTransitionDelaysSelectionUntilSettleCompletes() {
        var transition = NoteReviewPagingSelectionTransition(selection: 10)

        transition.beginSettle(to: 20)

        #expect(transition.visibleSelection == 10)
        #expect(transition.pendingSelection == 20)
        #expect(transition.isSettling)

        transition.syncExternalSelection(30)
        #expect(transition.visibleSelection == 10)

        let committedSelection = transition.completeSettle()

        #expect(committedSelection == 20)
        #expect(transition.visibleSelection == 20)
        #expect(transition.pendingSelection == nil)
        #expect(!transition.isSettling)
    }

    @Test
    func visualSessionKeepsSourceIdentityUntilCommitCompletes() {
        var session = NoteReviewPagingVisualSession(sourceSelection: 10, sourceIndex: 0)

        session.updateDragProgress(0.36)
        session.beginCommit(to: 20, targetIndex: 1, direction: .next)

        #expect(session.sourceSelection == 10)
        #expect(session.destination == 20)
        #expect(session.sourceIndex == 0)
        #expect(session.targetIndex == 1)
        #expect(session.completedSelection == nil)
        #expect(session.progressIndex == 0.36)

        session.animateToCommitBoundary()

        #expect(session.visualProgress == 1)
        #expect(session.progressIndex == 1)
        #expect(session.completedSelection == nil)

        let committedSelection = session.completeCommit()

        #expect(committedSelection == 20)
        #expect(session.completedSelection == 20)
    }

    @Test
    func visualSessionCancelReturnsToSourceWithoutCommit() {
        var session = NoteReviewPagingVisualSession(sourceSelection: 10, sourceIndex: 0)

        session.updateDragProgress(0.48)
        session.cancel()

        #expect(session.sourceSelection == 10)
        #expect(session.destination == nil)
        #expect(session.targetIndex == nil)
        #expect(session.visualProgress == 0)
        #expect(session.progressIndex == 0)
        #expect(session.completedSelection == nil)
        #expect(!session.isCommitting)
    }

    @Test
    func visualSessionPreviousCommitUsesSymmetricNegativeProgress() {
        var session = NoteReviewPagingVisualSession(sourceSelection: 20, sourceIndex: 1)

        session.updateDragProgress(-0.42)
        session.beginCommit(to: 10, targetIndex: 0, direction: .previous)
        session.animateToCommitBoundary()

        #expect(session.visualProgress == -1)
        #expect(session.progressIndex == 0)
        #expect(session.completeCommit() == 10)
    }

    @Test
    func committingVisualSessionIgnoresRepeatedDragUpdatesUntilFinished() {
        var session = NoteReviewPagingVisualSession(sourceSelection: 10, sourceIndex: 0)

        session.updateDragProgress(0.4)
        session.beginCommit(to: 20, targetIndex: 1, direction: .next)
        session.updateDragProgress(-0.8)
        session.animateToCommitBoundary()

        #expect(session.sourceSelection == 10)
        #expect(session.destination == 20)
        #expect(session.targetIndex == 1)
        #expect(session.visualProgress == 1)
        #expect(session.progressIndex == 1)
        #expect(session.completeCommit() == 20)
    }

    @Test
    func horizontalDragLockStartsFromZeroToAvoidLateJump() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        var tracker = NoteReviewPagingDragTracker()

        let lockFrame = tracker.update(
            translation: CGSize(width: 30, height: 6),
            motionSpec: spec
        )
        let movedFrame = tracker.update(
            translation: CGSize(width: 58, height: 8),
            motionSpec: spec
        )
        let predicted = tracker.effectivePredictedEndTranslation(CGSize(width: 120, height: 20))

        #expect(lockFrame == CGSize.zero)
        #expect(movedFrame == CGSize(width: 28, height: 2))
        #expect(predicted == CGSize(width: 90, height: 14))
        #expect(tracker.axisLock == .horizontal)
    }

    @Test
    func verticalDragLockDoesNotBecomeCardPagingMidGesture() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        var tracker = NoteReviewPagingDragTracker()

        let verticalFrame = tracker.update(
            translation: CGSize(width: 10, height: 32),
            motionSpec: spec
        )
        let laterHorizontalDrift = tracker.update(
            translation: CGSize(width: 80, height: 34),
            motionSpec: spec
        )

        #expect(verticalFrame == nil)
        #expect(laterHorizontalDrift == nil)
        #expect(tracker.axisLock == .vertical)
    }
}
