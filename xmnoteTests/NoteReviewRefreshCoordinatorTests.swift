import CoreGraphics
import Testing
@testable import xmnote

@MainActor
struct NoteReviewRefreshCoordinatorTests {
    @Test
    func firstRequestStartsLoadingIntent() {
        var coordinator = NoteReviewRefreshCoordinator()

        #expect(coordinator.request() == .start(1))
        #expect(coordinator.phase == .loading)
    }

    @Test
    func loadingKeepsOnlyLatestPendingIntent() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))
        #expect(coordinator.request() == .none)
        #expect(coordinator.request() == .none)

        #expect(
            coordinator.preparationCompleted(
                for: 1,
                requiresReplacement: false,
                shouldAnnounceOnFinish: true
            ) == .start(3)
        )
        #expect(coordinator.phase == .loading)
    }

    @Test
    func loadingPendingIntentDiscardsReplacementResultAndStartsLatest() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))
        #expect(coordinator.request() == .none)
        #expect(coordinator.request() == .none)

        #expect(
            coordinator.preparationCompleted(
                for: 1,
                requiresReplacement: true,
                shouldAnnounceOnFinish: true
            ) == .start(3)
        )
        #expect(coordinator.phase == .loading)
    }

    @Test
    func preparedReplacementMountsLayersBeforeStartingAnimation() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))

        let action = coordinator.preparationCompleted(
            for: 1,
            requiresReplacement: true,
            shouldAnnounceOnFinish: true
        )

        #expect(String(describing: action) == "mountReplacement(1)")
        #expect(coordinator.phase == .replacing)
    }

    @Test
    func replacingKeepsOnlyLatestPendingIntent() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))
        #expect(
            coordinator.preparationCompleted(
                for: 1,
                requiresReplacement: true,
                shouldAnnounceOnFinish: true
            ) == .mountReplacement(1)
        )
        #expect(coordinator.phase == .replacing)
        #expect(coordinator.request() == .none)
        #expect(coordinator.request() == .none)

        #expect(coordinator.replacementAnimationCompleted(for: 1) == .settle(1))
        #expect(coordinator.phase == .settling)
        #expect(coordinator.settlingCompleted(for: 1) == .start(3))
        #expect(coordinator.phase == .loading)
    }

    @Test
    func failedPreparationWithoutPendingReturnsIdle() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))

        #expect(coordinator.preparationFailed(for: 1) == .finish(shouldAnnounce: false))
        #expect(coordinator.phase == .idle)
    }

    @Test
    func unchangedPreparationFinishesWithoutAnnouncement() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))

        #expect(
            coordinator.preparationCompleted(
                for: 1,
                requiresReplacement: false,
                shouldAnnounceOnFinish: false
            )
                == .finish(shouldAnnounce: false)
        )
        #expect(coordinator.phase == .idle)
    }

    @Test
    func changedSingleItemFinishesWithAnnouncementWithoutReplacement() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))

        #expect(
            coordinator.preparationCompleted(
                for: 1,
                requiresReplacement: false,
                shouldAnnounceOnFinish: true
            ) == .finish(shouldAnnounce: true)
        )
        #expect(coordinator.phase == .idle)
    }

    @Test
    func completedReplacementWithoutPendingRequestsAnnouncement() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))
        #expect(
            coordinator.preparationCompleted(
                for: 1,
                requiresReplacement: true,
                shouldAnnounceOnFinish: true
            ) == .mountReplacement(1)
        )
        #expect(coordinator.replacementAnimationCompleted(for: 1) == .settle(1))

        #expect(coordinator.settlingCompleted(for: 1) == .finish(shouldAnnounce: true))
        #expect(coordinator.phase == .idle)
    }

    @Test
    func cancelClearsActiveAndPendingWork() {
        var coordinator = NoteReviewRefreshCoordinator()
        #expect(coordinator.request() == .start(1))
        #expect(coordinator.request() == .none)

        coordinator.cancel()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.request() == .start(3))
    }

    @Test
    func identicalOrSingleItemIDsDoNotRequireReplacement() {
        #expect(!NoteReviewRefreshCoordinator.requiresReplacement(oldIDs: [1, 2], newIDs: [1, 2]))
        #expect(!NoteReviewRefreshCoordinator.requiresReplacement(oldIDs: [1], newIDs: [2]))
        #expect(NoteReviewRefreshCoordinator.requiresReplacement(oldIDs: [1, 2], newIDs: [2, 3]))
        #expect(NoteReviewRefreshCoordinator.requiresReplacement(oldIDs: [1, 2, 3], newIDs: [1, 4, 5]))
    }

    @Test
    func normalMotionUsesSpecifiedTransformsAndTiming() {
        let motion = NoteReviewRefreshMotionSpec.standard

        #expect(motion.outgoing.transform == .init(offsetX: -18, offsetY: -6, scale: 0.988, rotationDegrees: -0.25, opacity: 0))
        #expect(motion.outgoing.duration == 0.18)
        #expect(motion.outgoing.delay == 0)
        #expect(motion.outgoing.curve == .smooth)
        #expect(motion.incoming.transform == .init(offsetX: 12, offsetY: 7, scale: 0.978, rotationDegrees: 0.15, opacity: 0))
        #expect(motion.incoming.duration == 0.24)
        #expect(motion.incoming.delay == 0.05)
        #expect(motion.incoming.curve == .snappy(extraBounce: 0))
        #expect(motion.totalDuration == 0.29)
        #expect(motion.completionDuration == 0.29)
    }

    @Test
    func reduceMotionUsesOpacityOnlyTiming() {
        let motion = NoteReviewRefreshMotionSpec.reduceMotion

        #expect(motion.outgoing.transform == .init(offsetX: 0, offsetY: 0, scale: 1, rotationDegrees: 0, opacity: 0))
        #expect(motion.outgoing.duration == 0.1)
        #expect(motion.incoming.transform == .init(offsetX: 0, offsetY: 0, scale: 1, rotationDegrees: 0, opacity: 0))
        #expect(motion.incoming.duration == 0.14)
        #expect(motion.incoming.delay == 0.1)
        #expect(motion.totalDuration == 0.24)
        #expect(motion.completionDuration == 0.24)
    }

    @Test
    func progressPolicyUsesDelayedDisplayAndMinimumResidence() {
        #expect(NoteReviewRefreshProgressPolicy.delay == .milliseconds(150))
        #expect(NoteReviewRefreshProgressPolicy.minimumVisibleDuration == .milliseconds(200))
    }

    @Test
    func renderPolicySeparatesMountAndLiveDeckHandoffByOneFrame() {
        #expect(NoteReviewRefreshRenderPolicy.mountDelay == .milliseconds(16))
        #expect(NoteReviewRefreshRenderPolicy.handoffDelay == .milliseconds(16))
    }
}
