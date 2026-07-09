import CoreGraphics
import Testing
@testable import xmnote

struct NoteReviewPagingMotionSpecTests {
    @Test
    func horizontalDragUsesDistanceThresholdForNavigation() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        #expect(spec.navigation(
            translation: CGSize(width: -70, height: 4),
            predictedEndTranslation: CGSize(width: -72, height: 4),
            containerWidth: 300
        ).isNext)

        #expect(spec.navigation(
            translation: CGSize(width: 70, height: 4),
            predictedEndTranslation: CGSize(width: 72, height: 4),
            containerWidth: 300
        ).isPrevious)
    }

    @Test
    func predictedEndTranslationCanCommitFastShortDrag() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        #expect(spec.navigation(
            translation: CGSize(width: -30, height: 2),
            predictedEndTranslation: CGSize(width: -112, height: 2),
            containerWidth: 300
        ).isNext)
    }

    @Test
    func verticalIntentDoesNotStartCardPaging() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        #expect(!spec.shouldTrackHorizontalDrag(translation: CGSize(width: 18, height: 80)))
        #expect(spec.navigation(
            translation: CGSize(width: 18, height: 80),
            predictedEndTranslation: CGSize(width: 120, height: 160),
            containerWidth: 300
        ).isNone)
    }

    @Test
    func defaultRestingStackRevealsReadableCardEdges() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        let nextCard = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0),
            progressIndex: 0,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )

        #expect(abs(nextCard.offsetX - 7.5) < 0.001)
        #expect(abs(nextCard.offsetY - 3) < 0.001)
        #expect(abs(nextCard.scale - 0.98) < 0.001)
        #expect(abs(nextCard.rotationDegrees) <= 0.5)
    }

    @Test
    func restingStackShowsBackCardContentPreviewWithoutReadability() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        let topCard = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0),
            progressIndex: 0,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )
        let backCard = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0),
            progressIndex: 0,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )

        #expect(topCard.contentVisibility.bodyOpacity == 1)
        #expect(topCard.contentVisibility.footerOpacity == 1)
        #expect(topCard.contentVisibility.isReadable)
        #expect(backCard.contentVisibility.bodyOpacity > 0)
        #expect(backCard.contentVisibility.footerOpacity > 0)
        #expect(!backCard.contentVisibility.isReadable)
    }

    @Test
    func targetContentHandsOffDuringNextTransition() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        let previewIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.16),
            progressIndex: 0.16,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )
        let preHandoffIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.49),
            progressIndex: 0.49,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )
        let midOutgoing = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.5),
            progressIndex: 0.5,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )
        let midIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.5),
            progressIndex: 0.5,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )
        let afterHandoffIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.65),
            progressIndex: 0.65,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )
        let lateIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.72),
            progressIndex: 0.72,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )
        let settledIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 1),
            progressIndex: 1,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )

        #expect(previewIncoming.contentVisibility.footerOpacity > 0)
        #expect(previewIncoming.contentVisibility.bodyOpacity > 0)
        #expect(previewIncoming.contentVisibility.edgeMaskProgress > 0)
        #expect(preHandoffIncoming.contentVisibility.footerOpacity > 0)
        #expect(preHandoffIncoming.contentVisibility.bodyOpacity > 0)
        #expect(!preHandoffIncoming.contentVisibility.isReadable)
        #expect(midOutgoing.contentVisibility.bodyOpacity == 1)
        #expect(midIncoming.contentVisibility.footerOpacity > 0)
        #expect(midIncoming.contentVisibility.bodyOpacity > 0)
        #expect(!midIncoming.contentVisibility.isReadable)
        #expect(afterHandoffIncoming.contentVisibility.bodyOpacity > 0)
        #expect(!afterHandoffIncoming.contentVisibility.isReadable)
        #expect(lateIncoming.contentVisibility.isReadable)
        #expect(lateIncoming.contentVisibility.bodyOpacity >= afterHandoffIncoming.contentVisibility.bodyOpacity)
        #expect(settledIncoming.contentVisibility.bodyOpacity == 1)
        #expect(settledIncoming.contentVisibility.footerOpacity == 1)
    }

    @Test
    func targetContentHandsOffDuringPreviousTransition() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        let previewIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.84),
            progressIndex: 0.84,
            sourceIndex: 1,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )
        let preHandoffIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.51),
            progressIndex: 0.51,
            sourceIndex: 1,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )
        let midOutgoing = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.5),
            progressIndex: 0.5,
            sourceIndex: 1,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )
        let midIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.5),
            progressIndex: 0.5,
            sourceIndex: 1,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )
        let afterHandoffIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.35),
            progressIndex: 0.35,
            sourceIndex: 1,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )
        let settledIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0),
            progressIndex: 0,
            sourceIndex: 1,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )

        #expect(previewIncoming.contentVisibility.footerOpacity > 0)
        #expect(previewIncoming.contentVisibility.bodyOpacity > 0)
        #expect(previewIncoming.contentVisibility.edgeMaskProgress > 0)
        #expect(preHandoffIncoming.contentVisibility.footerOpacity > 0)
        #expect(preHandoffIncoming.contentVisibility.bodyOpacity > 0)
        #expect(!preHandoffIncoming.contentVisibility.isReadable)
        #expect(midOutgoing.contentVisibility.bodyOpacity == 1)
        #expect(midIncoming.contentVisibility.footerOpacity > 0)
        #expect(midIncoming.contentVisibility.bodyOpacity > 0)
        #expect(!midIncoming.contentVisibility.isReadable)
        #expect(afterHandoffIncoming.contentVisibility.bodyOpacity > 0)
        #expect(!afterHandoffIncoming.contentVisibility.isReadable)
        #expect(settledIncoming.contentVisibility.bodyOpacity == 1)
        #expect(settledIncoming.contentVisibility.footerOpacity == 1)
    }

    @Test
    func previousTransitionPreRendersSourceSupportProxyBehindTarget() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300
        let plans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 1,
            progressIndex: 0.5,
            containerWidth: containerWidth,
            isSupportProxyEnabled: true
        )

        let sourcePrimary = plans.plan(pageIndex: 1, role: .primary)
        let sourceSupport = plans.plan(pageIndex: 1, role: .sourceSupportProxy)
        let targetPrimary = plans.plan(pageIndex: 0, role: .primary)
        #expect(sourcePrimary != nil)
        #expect(sourceSupport != nil)
        #expect(targetPrimary != nil)
        guard let sourcePrimary, let sourceSupport, let targetPrimary else { return }

        #expect(sourcePrimary.transform.offsetX >= containerWidth * 0.49)
        #expect(sourceSupport.transform.contentVisibility.bodyOpacity > 0)
        #expect(sourceSupport.transform.contentVisibility.footerOpacity > 0)
        #expect(!sourceSupport.transform.contentVisibility.isReadable)
        #expect(abs(sourceSupport.transform.offsetX) < containerWidth * 0.08)
        #expect(!sourceSupport.allowsHitTesting)
        #expect(sourceSupport.isAccessibilityHidden)
        #expect(sourceSupport.zIndex < targetPrimary.zIndex)
    }

    @Test
    func nextTransitionPreRendersSourceSupportProxySymmetrically() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300
        let plans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 0,
            progressIndex: 0.5,
            containerWidth: containerWidth,
            isSupportProxyEnabled: true
        )

        let sourcePrimary = plans.plan(pageIndex: 0, role: .primary)
        let sourceSupport = plans.plan(pageIndex: 0, role: .sourceSupportProxy)
        let targetPrimary = plans.plan(pageIndex: 1, role: .primary)
        #expect(sourcePrimary != nil)
        #expect(sourceSupport != nil)
        #expect(targetPrimary != nil)
        guard let sourcePrimary, let sourceSupport, let targetPrimary else { return }

        #expect(sourcePrimary.transform.offsetX <= -containerWidth * 0.49)
        #expect(sourceSupport.transform.contentVisibility.bodyOpacity > 0)
        #expect(sourceSupport.transform.contentVisibility.footerOpacity > 0)
        #expect(!sourceSupport.transform.contentVisibility.isReadable)
        #expect(abs(sourceSupport.transform.offsetX) < containerWidth * 0.08)
        #expect(sourceSupport.zIndex < targetPrimary.zIndex)
    }

    @Test
    func sourceSupportProxyUsesDeckTrackWithoutSwing() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300
        let progressIndex = 0.5
        let plans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 0,
            progressIndex: progressIndex,
            containerWidth: containerWidth,
            isSupportProxyEnabled: true
        )
        let sourceSupport = plans.plan(pageIndex: 0, role: .sourceSupportProxy)
        #expect(sourceSupport != nil)
        guard let sourceSupport else { return }

        let deckTrackTransform = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: progressIndex),
            progressIndex: progressIndex,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth,
            allowsSwingOut: false
        )

        #expect(abs(sourceSupport.transform.offsetX - deckTrackTransform.offsetX) < 0.001)
        #expect(abs(sourceSupport.transform.offsetY - deckTrackTransform.offsetY) < 0.001)
        #expect(abs(sourceSupport.transform.scale - deckTrackTransform.scale) < 0.001)
        #expect(abs(sourceSupport.transform.opacity - deckTrackTransform.opacity) < 0.001)
    }

    @Test
    func sourceSupportProxyOnlyExistsDuringValidTransition() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        let restingPlans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 1,
            progressIndex: 1,
            containerWidth: 300,
            isSupportProxyEnabled: true
        )
        let rubberBandPlans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 0,
            progressIndex: -0.12,
            containerWidth: 300,
            isSupportProxyEnabled: false
        )

        #expect(restingPlans.plan(pageIndex: 1, role: .sourceSupportProxy) == nil)
        #expect(rubberBandPlans.plan(pageIndex: 0, role: .sourceSupportProxy) == nil)
    }

    @Test
    func primaryCardPaperStaysOpaqueDuringTransition() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let plans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 0,
            progressIndex: 0.5,
            containerWidth: 300,
            isSupportProxyEnabled: true
        )

        let primaryPlans = plans.filter { $0.role == .primary }
        #expect(primaryPlans.count == 3)
        #expect(primaryPlans.allSatisfy { $0.transform.opacity == 1 })
    }

    @Test
    func supportProxyIsTheOnlyLayerAllowedToFadeIn() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let plans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 0,
            progressIndex: 0.09,
            containerWidth: 300,
            isSupportProxyEnabled: true
        )

        let supportProxy = plans.plan(pageIndex: 0, role: .sourceSupportProxy)
        #expect(supportProxy != nil)
        guard let supportProxy else { return }
        #expect(supportProxy.transform.opacity > 0)
        #expect(supportProxy.transform.opacity < 1)
    }

    @Test
    func contentHandoffNeverMakesTwoBodiesReadable() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let plans = spec.layerPlans(
            pageCount: 3,
            sourceIndex: 0,
            progressIndex: 0.65,
            containerWidth: 300,
            isSupportProxyEnabled: true
        )

        let readablePrimaryBodies = plans.filter {
            $0.role == .primary && $0.transform.contentVisibility.isReadable
        }
        #expect(readablePrimaryBodies.count <= 1)
    }

    @Test
    func contentOpacityStaysVisibleAcrossLayerHandoff() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300

        let preHandoffOutgoing = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.49),
            progressIndex: 0.49,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let preHandoffIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.49),
            progressIndex: 0.49,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let postHandoffOutgoing = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.51),
            progressIndex: 0.51,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let postHandoffIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.51),
            progressIndex: 0.51,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: containerWidth
        )

        #expect(preHandoffOutgoing.contentVisibility.bodyOpacity > 0)
        #expect(preHandoffIncoming.contentVisibility.bodyOpacity > 0)
        #expect(postHandoffOutgoing.contentVisibility.bodyOpacity > 0)
        #expect(postHandoffIncoming.contentVisibility.bodyOpacity > 0)
        #expect(abs(preHandoffIncoming.contentVisibility.bodyOpacity - postHandoffIncoming.contentVisibility.bodyOpacity) < 0.2)
    }

    @Test
    func commitBoundaryMatchesRestingPreviewForOutgoingCard() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300

        let outgoingAtCommitBoundary = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 1),
            progressIndex: 1,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let outgoingAfterSelectionCommit = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 1),
            progressIndex: 1,
            sourceIndex: 1,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )

        #expect(abs(outgoingAtCommitBoundary.offsetX - outgoingAfterSelectionCommit.offsetX) < 0.001)
        #expect(abs(outgoingAtCommitBoundary.offsetY - outgoingAfterSelectionCommit.offsetY) < 0.001)
        #expect(abs(outgoingAtCommitBoundary.scale - outgoingAfterSelectionCommit.scale) < 0.001)
        #expect(outgoingAtCommitBoundary.contentVisibility.bodyOpacity > 0)
        #expect(outgoingAtCommitBoundary.contentVisibility.footerOpacity > 0)
        #expect(outgoingAtCommitBoundary.contentVisibility == outgoingAfterSelectionCommit.contentVisibility)
    }

    @Test
    func defaultLayoutKeepsRestingStackAwayFromScreenEdges() {
        let layout = NoteReviewPagingLayoutSpec.iOSReviewDefault
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        #expect(layout.resolvedDeckWidth(for: 440) == 430)
        #expect(layout.resolvedDeckWidth(for: 393) == 393)
        #expect(layout.topCardSideMargin(availableWidth: 402) == 24)
        #expect(layout.restingStackSideMargin(availableWidth: 393, motionSpec: spec) >= Spacing.base)
        let restingStackSideMargin = layout.restingStackSideMargin(availableWidth: 402, motionSpec: spec)
        let restingStackExposure = layout.topCardSideMargin(availableWidth: 402) - restingStackSideMargin
        #expect(restingStackSideMargin >= Spacing.base)
        #expect(restingStackExposure <= Spacing.comfortable - 4 + 0.001)
        #expect(layout.restingStackSideMargin(availableWidth: 440, motionSpec: spec) >= Spacing.base)
    }

    @Test
    func cardContentWidthUsesComfortableReadingInsetOnCompactDeck() {
        let layout = NoteReviewPagingLayoutSpec.iOSReviewDefault
        let cardWidth = 402 - layout.topCardSideMargin(availableWidth: 402) * 2
        let contentWidth = NoteReviewCardLayout.readableContentWidth(forCardWidth: cardWidth)

        #expect(cardWidth == 354)
        #expect(NoteReviewCardLayout.horizontalPadding == Spacing.comfortable)
        #expect(abs(contentWidth - 326) < 0.001)
    }

    @Test
    func footerCoverKeepsCompactWidthAndBookCoverAspectRatio() {
        let coverWidth = NoteReviewCardLayout.footerCoverWidth
        let coverSize = XMBookCover.size(width: coverWidth)
        let surfaceTier = XMBookCover.resolvedSurfaceTier(
            for: coverSize,
            requestedStyle: .spine
        )

        #expect(coverWidth == 36)
        #expect(abs(coverSize.height - coverWidth / XMBookCover.aspectRatio) < 0.001)
        #expect(surfaceTier == .plain)
    }

    @Test
    func restingStackExposureStaysOutsideTextSafeAreaAcrossDeckWidths() {
        let layout = NoteReviewPagingLayoutSpec.iOSReviewDefault
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let cardHeight: CGFloat = 520
        let maximumSidePeek = Spacing.comfortable - 4
        let maximumBottomPeek: CGFloat = 4

        for availableWidth in [CGFloat(360), 393, 402, 430] {
            let pageWidth = layout.pagingWidth(for: availableWidth)

            let restingCases = [
                (sourceIndex: 0, pageIndex: 1, progressIndex: Double(0)),
                (sourceIndex: 0, pageIndex: 2, progressIndex: Double(0)),
                (sourceIndex: 1, pageIndex: 0, progressIndex: Double(1)),
                (sourceIndex: 1, pageIndex: 2, progressIndex: Double(1))
            ]

            for restingCase in restingCases {
                let transform = spec.cardTransform(
                    position: spec.cardPosition(
                        pageIndex: restingCase.pageIndex,
                        progressIndex: restingCase.progressIndex
                    ),
                    progressIndex: restingCase.progressIndex,
                    sourceIndex: restingCase.sourceIndex,
                    pageIndex: restingCase.pageIndex,
                    pageCount: 3,
                    containerWidth: pageWidth
                )
                let exposure = Self.stackExposure(
                    transform: transform,
                    cardWidth: pageWidth,
                    cardHeight: cardHeight
                )

                #expect(exposure.sidePeek <= maximumSidePeek + 0.001)
                #expect(exposure.bottomPeek <= maximumBottomPeek + 0.001)
                #expect(transform.contentVisibility.bodyOpacity > 0)
                #expect(transform.contentVisibility.footerOpacity > 0)
                #expect(!transform.contentVisibility.isReadable)
            }
        }
    }

    @Test
    func topCardAddsBoundedSwingOutDuringHorizontalDrag() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300
        let progressIndex = 0.5

        let topCard = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: progressIndex),
            progressIndex: progressIndex,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let baselineTopCard = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: progressIndex),
            progressIndex: progressIndex,
            sourceIndex: 1,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )

        #expect(topCard.offsetX < baselineTopCard.offsetX)
        #expect(abs(topCard.offsetX) >= containerWidth * 0.49)
        #expect(abs(topCard.offsetX) <= containerWidth * 0.52 + 0.001)
    }

    @Test
    func topCardSwingOutFollowsAuthorWaveAndReturnsToDeckTrack() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300

        let first = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.25),
            progressIndex: 0.25,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let second = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.5),
            progressIndex: 0.5,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let third = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.75),
            progressIndex: 0.75,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let settledOutgoing = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 1),
            progressIndex: 1,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )

        #expect(abs(second.offsetX) > abs(first.offsetX))
        #expect(abs(third.offsetX) > abs(first.offsetX))
        #expect(abs(third.offsetX) > abs(settledOutgoing.offsetX))
        #expect(abs(settledOutgoing.offsetX + containerWidth * spec.horizontalPeekRatio) < 0.001)
    }

    @Test
    func continuousProgressMovesIncomingCardOntoTopTrack() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault
        let containerWidth: CGFloat = 300

        let restingIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0),
            progressIndex: 0,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let halfwayIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.5),
            progressIndex: 0.5,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let settledIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 1),
            progressIndex: 1,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: containerWidth
        )
        let settledOutgoing = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 1),
            progressIndex: 1,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: containerWidth
        )

        #expect(halfwayIncoming.offsetX < restingIncoming.offsetX)
        #expect(halfwayIncoming.scale > restingIncoming.scale)
        #expect(abs(settledIncoming.offsetX) < 0.001)
        #expect(abs(settledIncoming.offsetY) < 0.001)
        #expect(abs(settledIncoming.scale - 1) < 0.001)
        #expect(abs(settledOutgoing.offsetX) < containerWidth * 0.2)
        #expect(abs(settledOutgoing.offsetX + containerWidth * spec.horizontalPeekRatio) < 0.001)
    }

    @Test
    func dynamicLayeringUsesAuthorMidpointHandoff() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        let earlyOutgoingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.4),
            pageIndex: 0,
            progressIndex: 0.4,
            sourceIndex: 0
        )
        let earlyIncomingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.4),
            pageIndex: 1,
            progressIndex: 0.4,
            sourceIndex: 0
        )
        let lateOutgoingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.6),
            pageIndex: 0,
            progressIndex: 0.6,
            sourceIndex: 0
        )
        let lateIncomingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.6),
            pageIndex: 1,
            progressIndex: 0.6,
            sourceIndex: 0
        )

        #expect(earlyOutgoingZ > earlyIncomingZ)
        #expect(lateIncomingZ > lateOutgoingZ)
    }

    @Test
    func dynamicLayeringIsSymmetricForPreviousNavigation() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        let earlyOutgoingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.6),
            pageIndex: 1,
            progressIndex: 0.6,
            sourceIndex: 1
        )
        let earlyIncomingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.6),
            pageIndex: 0,
            progressIndex: 0.6,
            sourceIndex: 1
        )
        let lateOutgoingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.4),
            pageIndex: 1,
            progressIndex: 0.4,
            sourceIndex: 1
        )
        let lateIncomingZ = spec.zIndex(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.4),
            pageIndex: 0,
            progressIndex: 0.4,
            sourceIndex: 1
        )

        #expect(earlyOutgoingZ > earlyIncomingZ)
        #expect(lateIncomingZ > lateOutgoingZ)
    }

    @Test
    func cardTransformCapsRotation() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault

        #expect(spec.maxRotationDegrees == 5)

        let transform = spec.cardTransform(
            position: 4,
            progressIndex: 4,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 5,
            containerWidth: 300
        )

        #expect(abs(transform.rotationDegrees) <= spec.maxRotationDegrees)
    }

    @Test
    func reduceMotionRemovesRotationAndShortensSettleDuration() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault.applyingReduceMotion(true)

        #expect(spec.maxRotationDegrees == 0)
        #expect(spec.settleDuration <= 0.12)
        #expect(spec.scaleInterval == 1)
        #expect(spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.6),
            progressIndex: 0.6,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        ).rotationDegrees == 0)

        let reducedTopCard = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 0, progressIndex: 0.5),
            progressIndex: 0.5,
            sourceIndex: 0,
            pageIndex: 0,
            pageCount: 3,
            containerWidth: 300
        )
        #expect(abs(reducedTopCard.offsetX + 3) < 0.001)
    }

    @Test
    func reduceMotionStillPreRendersTargetContent() {
        let spec = NoteReviewPagingMotionSpec.iOSReviewDefault.applyingReduceMotion(true)

        let incoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.2),
            progressIndex: 0.2,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )
        let readableIncoming = spec.cardTransform(
            position: spec.cardPosition(pageIndex: 1, progressIndex: 0.3),
            progressIndex: 0.3,
            sourceIndex: 0,
            pageIndex: 1,
            pageCount: 3,
            containerWidth: 300
        )

        #expect(incoming.contentVisibility.footerOpacity == 1)
        #expect(incoming.contentVisibility.bodyOpacity > 0)
        #expect(readableIncoming.contentVisibility.isReadable)
    }
}

private extension Optional where Wrapped == NoteReviewPagingNavigation {
    var isNext: Bool {
        if case .some(.next) = self { return true }
        return false
    }

    var isPrevious: Bool {
        if case .some(.previous) = self { return true }
        return false
    }

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

private extension Array where Element == NoteReviewPagingLayerPlan {
    func plan(pageIndex: Int, role: NoteReviewPagingLayerRole) -> NoteReviewPagingLayerPlan? {
        first { $0.pageIndex == pageIndex && $0.role == role }
    }
}

private extension NoteReviewPagingMotionSpecTests {
    struct StackExposure {
        let sidePeek: CGFloat
        let bottomPeek: CGFloat
    }

    static func stackExposure(
        transform: NoteReviewPagingCardTransform,
        cardWidth: CGFloat,
        cardHeight: CGFloat
    ) -> StackExposure {
        let radians = CGFloat(abs(transform.rotationDegrees) * .pi / 180)
        let scaledWidth = cardWidth * transform.scale
        let scaledHeight = cardHeight * transform.scale
        let rotatedWidth = scaledWidth * cos(radians) + scaledHeight * sin(radians)
        let rotatedHeight = scaledWidth * sin(radians) + scaledHeight * cos(radians)
        return StackExposure(
            sidePeek: max(0, abs(transform.offsetX) + rotatedWidth / 2 - cardWidth / 2),
            bottomPeek: max(0, transform.offsetY + rotatedHeight / 2 - cardHeight / 2)
        )
    }
}
