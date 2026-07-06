/**
 * [INPUT]: Vendored Shuffle 源码，依赖 UIKit 手势、动画与卡堆状态机
 * [OUTPUT]: 提供 XMNoteReview 前缀的内部 UIKit 卡堆基础类型
 * [POS]: NoteReviewCardStack 的源码级第三方基座，仅由项目内 SwiftUI wrapper 间接使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

///
/// MIT License
///
/// Copyright (c) 2020 Mac Gallagher
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in all
/// copies or substantial portions of the Software.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
/// SOFTWARE.
///

import UIKit

private enum XMNoteReviewRefreshMotion {
  static let pressDuration: TimeInterval = 0.07
  static let minimizeDuration: TimeInterval = 0.26
  static let bloomDuration: TimeInterval = 0.34
  static let bloomStagger: TimeInterval = 0.030
  static let bloomDamping: CGFloat = 0.92
  static let bloomInitialVelocity: CGFloat = 0.08
  static let reducedFadeOutDuration: TimeInterval = 0.08
  static let reducedFadeInDuration: TimeInterval = 0.12
}

private struct XMNoteReviewRefreshProxyCard {
  let position: Int
  let view: UIView
}

private struct XMNoteReviewRefreshAnimatedCard {
  let position: Int
  let view: UIView
}

open class XMNoteReviewSwipeCardStack: UIView, XMNoteReviewSwipeCardDelegate, UIGestureRecognizerDelegate {

  /// A internal structure for a `XMNoteReviewSwipeCard` and it's corresponding index in the card stack's `dataSource`.
  struct Card {
    var index: Int
    var card: XMNoteReviewSwipeCard
  }

  open var animationOptions = XMNoteReviewCardStackAnimationOptions()

  /// Return `false` if you wish to ignore all horizontal gestures on the card stack.
  ///
  /// You may wish to modify this property if your card stack is embedded in a `UIScrollView`, for example.
  open var shouldRecognizeHorizontalDrag: Bool = true

  /// Return `false` if you wish to ignore all vertical gestures on the card stack.
  ///
  /// You may wish to modify this property if your card stack is embedded in a `UIScrollView`, for example.
  open var shouldRecognizeVerticalDrag: Bool = true

  public weak var delegate: XMNoteReviewSwipeCardStackDelegate?

  public weak var dataSource: XMNoteReviewSwipeCardStackDataSource? {
    didSet {
      reloadData()
    }
  }

  public var cardStackInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10) {
    didSet {
      setNeedsLayout()
    }
  }

  /// The data source index corresponding to the topmost card in the stack.
  public var topCardIndex: Int? {
    return visibleCards.first?.index
  }

  public var numberOfVisibleCards: Int = 3 {
    didSet {
      numberOfVisibleCards = max(1, numberOfVisibleCards)
      reloadVisibleCards()
      setNeedsLayout()
    }
  }

  /// The scale applied between consecutive cards in the stack.
  public var scaleInterval: CGFloat = 0.95 {
    didSet {
      scaleInterval = max(0.5, min(scaleInterval, 1))
      setNeedsLayout()
    }
  }

  /// The vertical offset applied between consecutive background cards.
  public var translationInterval: CGFloat = 10 {
    didSet {
      translationInterval = max(0, translationInterval)
      setNeedsLayout()
    }
  }

  /// Whether a vertical drag that starts over an embedded scroll view should prefer scrolling readable content.
  public var prefersEmbeddedVerticalScroll = true

  /// Horizontal drag must beat vertical drag by this multiplier to take over an embedded scroll view.
  public var horizontalGestureDominance: CGFloat = 1.15 {
    didSet {
      horizontalGestureDominance = max(1, horizontalGestureDominance)
    }
  }

  /// An ordered array containing all pairs of currently visible cards.
  ///
  /// The `Card` at the first position is the topmost `XMNoteReviewSwipeCard` in the view hierarchy.
  var visibleCards: [Card] = []

  var topCard: XMNoteReviewSwipeCard? {
    return visibleCards.first?.card
  }

  var backgroundCards: [XMNoteReviewSwipeCard] {
    return Array(visibleCards.dropFirst()).map { $0.card }
  }

  var isEnabled: Bool {
    return !isAnimating && (topCard?.isUserInteractionEnabled ?? true)
  }

  var isAnimating: Bool = false

  let cardContainer = UIView()

  private var animator: XMNoteReviewCardStackAnimating = XMNoteReviewCardStackAnimator.shared
  private var stateManager: XMNoteReviewCardStackStateManaging = XMNoteReviewCardStackStateManager()
  private var refreshProxyCards: [XMNoteReviewRefreshProxyCard] = []

  // MARK: - Initialization

  override public init(frame: CGRect) {
    super.init(frame: frame)
    initialize()
  }

  public required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    initialize()
  }

  convenience init(animator: XMNoteReviewCardStackAnimating,
                   stateManager: XMNoteReviewCardStackStateManaging) {
    self.init(frame: .zero)
    self.animator = animator
    self.stateManager = stateManager
  }

  private func initialize() {
    addSubview(cardContainer)
  }

  // MARK: - Layout & Transform

  override open func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width - (cardStackInsets.left + cardStackInsets.right)
    let height = bounds.height - (cardStackInsets.top + cardStackInsets.bottom)
    cardContainer.frame = CGRect(x: cardStackInsets.left, y: cardStackInsets.top, width: width, height: height)

    for (position, value) in visibleCards.enumerated() {
      layoutCard(value.card, at: position)
    }
  }

  func layoutCard(_ card: XMNoteReviewSwipeCard, at position: Int) {
    card.transform = .identity
    card.frame = CGRect(origin: .zero, size: cardContainer.frame.size)
    card.transform = transform(forCardAtPosition: position)
    card.isUserInteractionEnabled = position == 0
  }

  func scaleFactor(forCardAtPosition position: Int) -> CGPoint {
    let scale = position == 0 ? 1 : CGFloat(pow(Double(scaleInterval), Double(position)))
    return CGPoint(x: scale, y: scale)
  }

  func transform(forCardAtPosition position: Int) -> CGAffineTransform {
    let cardScaleFactor = scaleFactor(forCardAtPosition: position)
    return CGAffineTransform(translationX: 0, y: CGFloat(position) * translationInterval)
      .scaledBy(x: cardScaleFactor.x, y: cardScaleFactor.y)
  }

  func backgroundCardDragTransform(topCard: XMNoteReviewSwipeCard, currentPosition: Int) -> CGAffineTransform {
    let panTranslation = topCard.panGestureRecognizer.translation(in: self)
    let minimumSideLength = min(bounds.width, bounds.height)
    let percentage = max(min(2 * abs(panTranslation.x) / minimumSideLength, 1),
                         min(2 * abs(panTranslation.y) / minimumSideLength, 1))

    let currentScale = scaleFactor(forCardAtPosition: currentPosition)
    let nextScale = scaleFactor(forCardAtPosition: currentPosition - 1)

    let scaleX = (1 - percentage) * currentScale.x + percentage * nextScale.x
    let scaleY = (1 - percentage) * currentScale.y + percentage * nextScale.y
    let currentTranslation = CGFloat(currentPosition) * translationInterval
    let nextTranslation = CGFloat(max(currentPosition - 1, 0)) * translationInterval
    let translation = (1 - percentage) * currentTranslation + percentage * nextTranslation

    return CGAffineTransform(translationX: 0, y: translation)
      .scaledBy(x: scaleX, y: scaleY)
  }

  // MARK: - Gesture Recognizers

  override open func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let topCard = topCard, topCard.panGestureRecognizer == gestureRecognizer else {
      return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    let velocity = topCard.panGestureRecognizer.velocity(in: self)

    if abs(velocity.x) > abs(velocity.y) {
      return shouldRecognizeHorizontalDrag
    }

    if abs(velocity.x) < abs(velocity.y) {
      if prefersEmbeddedVerticalScroll,
         shouldEmbeddedScrollViewHandleVerticalDrag(for: topCard, velocityY: velocity.y) {
        return false
      }
      return shouldRecognizeVerticalDrag
    }

    return topCard.gestureRecognizerShouldBegin(gestureRecognizer)
  }

  // MARK: - Main Methods

  /// Triggers a swipe on the card stack in the specified direction.
  /// - Parameters:
  ///   - direction: The direction to swipe the top card.
  ///   - animated: A boolean indicating whether the swipe action should be animated.
  public func swipe(_ direction: XMNoteReviewSwipeDirection, animated: Bool) {
    if !isEnabled { return }

    if animated {
      topCard?.swipe(direction: direction)
    } else {
      topCard?.removeFromSuperview()
    }

    if let topCard = topCard {
      swipeAction(topCard: topCard,
                  direction: direction,
                  forced: true,
                  animated: animated)
    }
  }

  func swipeAction(topCard: XMNoteReviewSwipeCard,
                   direction: XMNoteReviewSwipeDirection,
                   forced: Bool,
                   animated: Bool) {
    guard let swipedIndex = topCardIndex else { return }
    stateManager.swipe(direction)
    visibleCards.remove(at: 0)

    // Insert new card if needed
    if (stateManager.remainingIndices.count - visibleCards.count) > 0 {
      let bottomCardIndex = stateManager.remainingIndices[visibleCards.count]
      if let card = loadCard(at: bottomCardIndex) {
        insertCard(Card(index: bottomCardIndex, card: card), at: visibleCards.count)
      }
    }

    delegate?.cardStack?(self, didSwipeCardAt: swipedIndex, with: direction)

    let didSwipeAllCards = stateManager.remainingIndices.isEmpty
    if didSwipeAllCards {
      delegate?.didSwipeAllCards?(self)
    }

    isAnimating = true
    animator.animateSwipe(self,
                          topCard: topCard,
                          direction: direction,
                          forced: forced,
                          animated: animated) { [weak self] finished in
      if finished {
        self?.isAnimating = false
      }
    }
  }

  /// Returns the most recently swiped card to the top of the card stack.
  /// - Parameter animated: A boolean indicating whether the undo action should be animated.
  public func undoLastSwipe(animated: Bool) {
    if !isEnabled { return }
    guard let previousSwipe = stateManager.undoSwipe() else { return }

    reloadVisibleCards()
    delegate?.cardStack?(self, didUndoCardAt: previousSwipe.index, from: previousSwipe.direction)

    if animated {
      topCard?.reverseSwipe(from: previousSwipe.direction)
    }

    isAnimating = true
    if let topCard = topCard {
      animator.animateUndo(self,
                           topCard: topCard,
                           animated: animated) { [weak self] finished in
        if finished {
          self?.isAnimating = false
        }
      }
    }
  }

  /// Shifts the remaining cards in the card stack by the specified distance. Any swiped cards are ignored.
  /// - Parameters:
  ///   - distance: The distance to shift the remaining cards by.
  ///   - animated: A boolean indicating whether the undo action should be animated.
  public func shift(withDistance distance: Int = 1, animated: Bool) {
    if !isEnabled || distance == 0 || visibleCards.count <= 1 { return }

    stateManager.shift(withDistance: distance)
    reloadVisibleCards()

    isAnimating = true
    animator.animateShift(self,
                          withDistance: distance,
                          animated: animated) { [weak self] finished in
      if finished {
        self?.isAnimating = false
      }
    }
  }

  /// Performs a structured refresh animation that minimizes the current card group before reloading the stack.
  /// The method owns UIKit interaction locking for the duration of the choreography; callers are
  /// responsible for updating the data source order before invoking shuffled refresh.
  func performRefreshAnimation(
    mode: NoteReviewCardStackRefreshMode,
    reduceMotion: Bool,
    completion: @escaping () -> Void
  ) {
    guard dataSource != nil, !isAnimating else {
      completion()
      return
    }

    guard !visibleCards.isEmpty else {
      reloadData()
      completion()
      return
    }

    _ = mode
    animator.removeAllCardAnimations(self)
    removeRefreshProxyCards()
    isAnimating = true
    isUserInteractionEnabled = false

    if reduceMotion {
      performReducedMotionRefresh(completion: completion)
      return
    }

    let complete: () -> Void = { [weak self] in
      guard let self else {
        completion()
        return
      }
      self.clearRefreshAnimationState()
      completion()
    }

    _ = installRefreshProxyCards()
    animateRefreshPress {
      self.animateRefreshMinimizeOut {
        self.reloadCardsForRefresh()
        self.animateRefreshBloomIn(completion: complete)
      }
    }
  }

  // MARK: - Data Source

  public func reloadData() {
    guard let dataSource = dataSource else { return }
    let numberOfCards = dataSource.numberOfCards(in: self)
    stateManager.reset(withNumberOfCards: numberOfCards)
    reloadVisibleCards()
    isAnimating = false
  }

  /// Resets the stack and places the card at the given data source index on top.
  public func scrollToIndex(_ index: Int) {
    guard let dataSource = dataSource else { return }
    let numberOfCards = dataSource.numberOfCards(in: self)
    guard index >= 0, index < numberOfCards else { return }
    stateManager.reset(withNumberOfCards: numberOfCards)
    stateManager.shift(withDistance: index)
    reloadVisibleCards()
    isAnimating = false
  }

  /// Returns the `XMNoteReviewSwipeCard` at the specified index.
  /// - Parameter index: The index of the card in the data source.
  /// - Returns: The `XMNoteReviewSwipeCard` at the specified index, or `nil` if the card is not visible or the index is
  /// out of range.
  public func card(forIndexAt index: Int) -> XMNoteReviewSwipeCard? {
    for value in visibleCards where value.index == index {
      return value.card
    }
    return nil
  }

  func reloadVisibleCards() {
    visibleCards.forEach { $0.card.removeFromSuperview() }
    visibleCards.removeAll()

    let numberOfCards = min(stateManager.remainingIndices.count, numberOfVisibleCards)
    for position in 0..<numberOfCards {
      let index = stateManager.remainingIndices[position]
      if let card = loadCard(at: index) {
        insertCard(Card(index: index, card: card), at: position)
      }
    }
  }

  func insertCard(_ value: Card, at position: Int) {
    cardContainer.insertSubview(value.card, at: visibleCards.count - position)
    layoutCard(value.card, at: position)
    visibleCards.insert(value, at: position)
  }

  func loadCard(at index: Int) -> XMNoteReviewSwipeCard? {
    let card = dataSource?.cardStack(self, cardForIndexAt: index)
    card?.delegate = self
    card?.panGestureRecognizer.delegate = self
    return card
  }

  // MARK: - State Management

  /// Returns the current position of the card at the specified index.
  ///
  /// A returned value of `0` indicates that the card is the topmost card in the stack.
  /// - Parameter index: The index of the card in the data source.
  /// - Returns: The current position of the card at the specified index, or `nil` if the index if out of range or the
  /// card has been swiped.
  public func positionforCard(at index: Int) -> Int? {
    return stateManager.remainingIndices.firstIndex(of: index)
  }

  /// Returns the remaining number of cards in the card stack.
  /// - Returns: The number of cards in the card stack which have not yet been swiped.
  public func numberOfRemainingCards() -> Int {
    return stateManager.remainingIndices.count
  }

  /// Returns the indices of the swiped cards in the order they were swiped.
  /// - Returns: The indices of the swiped cards in the data source.
  public func swipedCards() -> [Int] {
    return stateManager.swipes.map { $0.index }
  }

  /// Inserts a new card with the given index at the specified position.
  ///
  /// Calling this method will not clear the swipe history nor trigger a reload of the data source.
  /// - Parameters:
  ///   - index: The index of the card in the data source.
  ///   - position: The position of the new card in the card stack.
  public func insertCard(atIndex index: Int, position: Int) {
    guard let dataSource = dataSource else { return }

    let oldNumberOfCards = stateManager.totalIndexCount
    let newNumberOfCards = dataSource.numberOfCards(in: self)

    stateManager.insert(index, at: position)

    if newNumberOfCards != oldNumberOfCards + 1 {
      let errorString = XMNoteReviewStringUtils.createInvalidUpdateErrorString(newCount: newNumberOfCards,
                                                                   oldCount: oldNumberOfCards,
                                                                   insertedCount: 1)
      assertionFailure(errorString)
      reloadData()
      return
    }

    reloadVisibleCards()
  }

  /// Appends a collection of new cards with the specifed indices to the bottom of the card stack.
  ///
  /// Calling this method will not clear the swipe history nor trigger a reload of the data source.
  /// - Parameter indices: The indices of the cards in the data source.
  public func appendCards(atIndices indices: [Int]) {
    guard let dataSource = dataSource else { return }

    let oldNumberOfCards = stateManager.totalIndexCount
    let newNumberOfCards = dataSource.numberOfCards(in: self)

    for index in indices {
      stateManager.insert(index, at: numberOfRemainingCards())
    }

    if newNumberOfCards != oldNumberOfCards + indices.count {
      let errorString = XMNoteReviewStringUtils.createInvalidUpdateErrorString(newCount: newNumberOfCards,
                                                                   oldCount: oldNumberOfCards,
                                                                   insertedCount: indices.count)
      assertionFailure(errorString)
      reloadData()
      return
    }

    reloadVisibleCards()
  }

  /// Deletes the cards at the specified indices. If an index corresponds to a card that has been swiped,
  /// it is removed from the swipe history.
  ///
  /// Calling this method will not clear the swipe history nor trigger a reload of the data source.
  /// - Parameter indices: The indices of the cards in the data source to delete.
  public func deleteCards(atIndices indices: [Int]) {
    guard let dataSource = dataSource else { return }

    let oldNumberOfCards = stateManager.totalIndexCount
    let newNumberOfCards = dataSource.numberOfCards(in: self)

    if newNumberOfCards != oldNumberOfCards - indices.count {
      let errorString = XMNoteReviewStringUtils.createInvalidUpdateErrorString(newCount: newNumberOfCards,
                                                                   oldCount: oldNumberOfCards,
                                                                   deletedCount: indices.count)
      assertionFailure(errorString)
      reloadData()
      return
    }

    stateManager.delete(indices)
    reloadVisibleCards()
  }

  /// Deletes the cards at the specified positions in the card stack.
  ///
  /// Calling this method will not clear the swipe history nor trigger a reload of the data source.
  /// - Parameter positions: The positions of the cards to delete in the card stack.
  public func deleteCards(atPositions positions: [Int]) {
    guard let dataSource = dataSource else { return }

    let oldNumberOfCards = stateManager.totalIndexCount
    let newNumberOfCards = dataSource.numberOfCards(in: self)

    if newNumberOfCards != oldNumberOfCards - positions.count {
      let errorString = XMNoteReviewStringUtils.createInvalidUpdateErrorString(newCount: newNumberOfCards,
                                                                   oldCount: oldNumberOfCards,
                                                                   deletedCount: positions.count)
      assertionFailure(errorString)
      reloadData()
      return
    }

    stateManager.delete(indicesAtPositions: positions)
    reloadVisibleCards()
  }

  // MARK: - XMNoteReviewSwipeCardDelegate

  func cardDidTap(_ card: XMNoteReviewSwipeCard) {
    guard let topCardIndex = topCardIndex else { return }
    delegate?.cardStack?(self, didSelectCardAt: topCardIndex)
  }

  func cardDidBeginSwipe(_ card: XMNoteReviewSwipeCard) {
    animator.removeBackgroundCardAnimations(self)
  }

  func cardDidContinueSwipe(_ card: XMNoteReviewSwipeCard) {
    for (position, backgroundCard) in backgroundCards.enumerated() {
      backgroundCard.transform = backgroundCardDragTransform(topCard: card, currentPosition: position + 1)
    }
  }

  func cardDidCancelSwipe(_ card: XMNoteReviewSwipeCard) {
    animator.animateReset(self, topCard: card)
  }

  func cardDidFinishSwipeAnimation(_ card: XMNoteReviewSwipeCard) {
    card.removeFromSuperview()
  }

  func cardDidSwipe(_ card: XMNoteReviewSwipeCard, withDirection direction: XMNoteReviewSwipeDirection) {
    swipeAction(topCard: card, direction: direction, forced: false, animated: true)
  }
}

private extension XMNoteReviewSwipeCardStack {
  func performReducedMotionRefresh(completion: @escaping () -> Void) {
    let installedProxy = installRefreshProxyCards()
    let feedbackViews: [UIView]
    if installedProxy {
      feedbackViews = refreshProxyCards.map(\.view)
    } else {
      feedbackViews = visibleCards.map(\.card)
    }

    UIView.animate(
      withDuration: XMNoteReviewRefreshMotion.reducedFadeOutDuration,
      delay: 0,
      options: [.curveEaseOut],
      animations: {
        feedbackViews.forEach { $0.alpha = 0.88 }
      },
      completion: { [weak self] _ in
        guard let self else {
          completion()
          return
        }
        UIView.performWithoutAnimation {
          self.removeRefreshProxyCards()
          self.reloadData()
          self.visibleCards.forEach { $0.card.alpha = 0.88 }
        }
        self.isAnimating = true
        UIView.animate(
          withDuration: XMNoteReviewRefreshMotion.reducedFadeInDuration,
          delay: 0,
          options: [.curveEaseOut],
          animations: { [weak self] in
            guard let self else { return }
            self.visibleCards.forEach { $0.card.alpha = 1 }
          },
          completion: { [weak self] _ in
            self?.clearRefreshAnimationState()
            completion()
          }
        )
      }
    )
  }

  func installRefreshProxyCards() -> Bool {
    let visiblePairs = Array(visibleCards.enumerated())
    guard !visiblePairs.isEmpty else { return false }

    var proxies: [XMNoteReviewRefreshProxyCard] = []
    for (position, value) in visiblePairs.reversed() {
      guard let snapshot = value.card.snapshotView(afterScreenUpdates: false) else {
        proxies.forEach { $0.view.removeFromSuperview() }
        refreshProxyCards.removeAll()
        return false
      }
      snapshot.bounds = value.card.bounds
      snapshot.center = value.card.center
      snapshot.transform = value.card.transform
      snapshot.alpha = value.card.alpha
      snapshot.isUserInteractionEnabled = false
      cardContainer.addSubview(snapshot)
      proxies.append(XMNoteReviewRefreshProxyCard(position: position, view: snapshot))
    }

    refreshProxyCards = proxies.sorted { $0.position < $1.position }
    visibleCards.forEach { $0.card.alpha = 0 }
    return true
  }

  func removeRefreshProxyCards() {
    refreshProxyCards.forEach {
      $0.view.layer.removeAllAnimations()
      $0.view.removeFromSuperview()
    }
    refreshProxyCards.removeAll()
  }

  func clearRefreshAnimationState() {
    for (position, value) in visibleCards.enumerated() {
      value.card.layer.removeAllAnimations()
      value.card.alpha = 1
      layoutCard(value.card, at: position)
    }
    removeRefreshProxyCards()
    isAnimating = false
    isUserInteractionEnabled = true
  }

  func hasRefreshProxyCards() -> Bool {
    !refreshProxyCards.isEmpty
  }

  func activeRefreshCards() -> [XMNoteReviewRefreshAnimatedCard] {
    if hasRefreshProxyCards() {
      return refreshProxyCards.map {
        XMNoteReviewRefreshAnimatedCard(position: $0.position, view: $0.view)
      }
    }
    return visibleCards.enumerated().map { position, value in
      XMNoteReviewRefreshAnimatedCard(position: position, view: value.card)
    }
  }

  func animateRefreshPress(completion: @escaping () -> Void) {
    UIView.animate(
      withDuration: XMNoteReviewRefreshMotion.pressDuration,
      delay: 0,
      options: [.curveEaseOut],
      animations: { [weak self] in
        guard let self else { return }
        for target in self.activeRefreshCards() {
          target.view.transform = self.refreshPressTransform(for: target.position)
        }
      },
      completion: { _ in completion() }
    )
  }

  func animateRefreshMinimizeOut(completion: @escaping () -> Void) {
    UIView.animateKeyframes(
      withDuration: XMNoteReviewRefreshMotion.minimizeDuration,
      delay: 0,
      options: [.calculationModeCubic],
      animations: { [weak self] in
        guard let self else { return }
        UIView.addKeyframe(withRelativeStartTime: 0.00, relativeDuration: 0.74) {
          for target in self.activeRefreshCards() {
            target.view.transform = self.refreshMinimizedTransform(for: target.position)
          }
        }
        UIView.addKeyframe(withRelativeStartTime: 0.42, relativeDuration: 0.58) {
          for target in self.activeRefreshCards() {
            target.view.alpha = 0
          }
        }
      },
      completion: { _ in completion() }
    )
  }

  func reloadCardsForRefresh() {
    UIView.performWithoutAnimation {
      removeRefreshProxyCards()
      reloadData()
      for (position, value) in visibleCards.enumerated() {
        value.card.alpha = 0
        value.card.transform = refreshBloomStartTransform(for: position)
      }
    }
    isAnimating = true
  }

  func animateRefreshBloomIn(completion: @escaping () -> Void) {
    guard !visibleCards.isEmpty else {
      completion()
      return
    }

    let maxPosition = max(visibleCards.count - 1, 0)
    var pendingCompletions = visibleCards.count
    let finishOne: () -> Void = { [weak self] in
      pendingCompletions -= 1
      guard pendingCompletions == 0 else { return }
      self?.removeRefreshProxyCards()
      completion()
    }

    for (position, value) in visibleCards.enumerated() {
      let delay = refreshBloomDelay(for: position, maxPosition: maxPosition)
      UIView.animate(
        withDuration: XMNoteReviewRefreshMotion.bloomDuration,
        delay: delay,
        usingSpringWithDamping: XMNoteReviewRefreshMotion.bloomDamping,
        initialSpringVelocity: XMNoteReviewRefreshMotion.bloomInitialVelocity,
        options: [.curveEaseOut],
        animations: { [weak self] in
          guard let self else { return }
          value.card.alpha = 1
          self.layoutCard(value.card, at: position)
        },
        completion: { _ in finishOne() }
      )
    }
  }

  func refreshBloomDelay(for position: Int, maxPosition: Int) -> TimeInterval {
    TimeInterval(maxPosition - min(position, maxPosition)) * XMNoteReviewRefreshMotion.bloomStagger
  }

  func refreshPressTransform(for position: Int) -> CGAffineTransform {
    if position == 0 {
      return CGAffineTransform(translationX: 0, y: 8)
        .scaledBy(x: 0.970, y: 0.970)
    }
    let scale = min(1, scaleFactor(forCardAtPosition: position).x + 0.010)
    let yOffset = CGFloat(position) * translationInterval + 3
    return CGAffineTransform(translationX: 0, y: yOffset)
      .scaledBy(x: scale, y: scale)
  }

  func refreshMinimizedTransform(for position: Int) -> CGAffineTransform {
    let scale = max(0.18, 0.24 - CGFloat(position) * 0.02)
    return CGAffineTransform(translationX: 0, y: CGFloat(position) * 1.5)
      .scaledBy(x: scale, y: scale)
  }

  func refreshBloomStartTransform(for position: Int) -> CGAffineTransform {
    CGAffineTransform(translationX: 0, y: CGFloat(position) * 1.5)
      .scaledBy(x: 0.28, y: 0.28)
  }

  func shouldEmbeddedScrollViewHandleVerticalDrag(
    for topCard: XMNoteReviewSwipeCard,
    velocityY: CGFloat
  ) -> Bool {
    let velocity = topCard.panGestureRecognizer.velocity(in: topCard)
    guard abs(velocity.y) > abs(velocity.x) * horizontalGestureDominance else {
      return false
    }

    let touchLocation = topCard.panGestureRecognizer.location(in: topCard)
    guard let touchedView = topCard.hitTest(touchLocation, with: nil),
          let scrollView = touchedView.nearestSuperview(of: UIScrollView.self),
          scrollView.isScrollEnabled,
          scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom > scrollView.bounds.height
    else {
      return false
    }

    let topBoundary = -scrollView.adjustedContentInset.top
    let bottomBoundary = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
    if velocityY > 0 {
      return scrollView.contentOffset.y > topBoundary
    }
    if velocityY < 0 {
      return scrollView.contentOffset.y < bottomBoundary
    }
    return false
  }
}
