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

open class XMNoteReviewSwipeCard: XMNoteReviewSwipeView {

  open var animationOptions = XMNoteReviewCardAnimationOptions()

  /// Whether taps on the card should be reported to the stack delegate.
  public var isTapEnabled = true

  /// The the main content view.
  public var content: UIView? {
    didSet {
      if let content = content {
        oldValue?.removeFromSuperview()
        addSubview(content)
      }
    }
  }

  /// The the footer view.
  public var footer: UIView? {
    didSet {
      if let footer = footer {
        oldValue?.removeFromSuperview()
        addSubview(footer)
      }
    }
  }

  /// The height of the footer view.
  public var footerHeight: CGFloat = 100 {
    didSet {
      setNeedsLayout()
    }
  }

  weak var delegate: XMNoteReviewSwipeCardDelegate?

  var touchLocation: CGPoint? {
    return internalTouchLocation
  }

  private var internalTouchLocation: CGPoint?

  private let overlayContainer = UIView()
  private var overlays = [XMNoteReviewSwipeDirection: UIView]()

  private var animator: XMNoteReviewCardAnimating = XMNoteReviewCardAnimator.shared

  // MARK: - Initialization

  override public init(frame: CGRect) {
    super.init(frame: frame)
    initialize()
  }

  public required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    initialize()
  }

  convenience init(animator: XMNoteReviewCardAnimating) {
    self.init(frame: .zero)
    self.animator = animator
  }

  private func initialize() {
    addSubview(overlayContainer)
    overlayContainer.setUserInteraction(false)
  }

  // MARK: - Layout & XMNoteReviewSwipe Transform

  override open func layoutSubviews() {
    super.layoutSubviews()
    footer?.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)

    // Content
    if let content = content {
      if let footer = footer, footer.isOpaque {
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - footerHeight)
      } else {
        content.frame = bounds
      }
      sendSubviewToBack(content)
    }

    // Overlays
    if footer != nil {
      overlayContainer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - footerHeight)
    } else {
      overlayContainer.frame = bounds
    }
    bringSubviewToFront(overlayContainer)
    overlays.values.forEach { $0.frame = overlayContainer.bounds }
  }

  func swipeTransform() -> CGAffineTransform {
    let dragTranslation = panGestureRecognizer.translation(in: self)
    let translation = CGAffineTransform(translationX: dragTranslation.x,
                                        y: dragTranslation.y)
    let rotation = CGAffineTransform(rotationAngle: swipeRotationAngle())
    return translation.concatenating(rotation)
  }

  func swipeRotationAngle() -> CGFloat {
    let superviewTranslation = panGestureRecognizer.translation(in: superview)
    let referenceWidth = max(1, max(bounds.width, max(superview?.bounds.width ?? 0, window?.bounds.width ?? 0)))
    let rotationStrength = min(superviewTranslation.x / referenceWidth, 1)
    return swipeRotationDirectionY()
      * rotationStrength
      * animationOptions.maximumRotationAngle
  }

  func swipeRotationDirectionY() -> CGFloat {
    if let touchPoint = touchLocation {
      return (touchPoint.y < bounds.height / 2) ? 1 : -1
    }
    return 0
  }

  func swipeOverlayPercentage(forDirection direction: XMNoteReviewSwipeDirection) -> CGFloat {
    if direction != activeDirection() { return 0 }
    let totalPercentage = swipeDirections.reduce(0) { sum, direction in
      return sum + dragPercentage(on: direction)
    }
    let actualPercentage = 2 * dragPercentage(on: direction) - totalPercentage
    return max(0, min(actualPercentage, 1))
  }

  // MARK: - Overrides

  override open func didTap(_ recognizer: UITapGestureRecognizer) {
    guard isTapEnabled else { return }
    super.didTap(recognizer)
    internalTouchLocation = recognizer.location(in: self)
    delegate?.cardDidTap(self)
  }

  override open func beginSwiping(_ recognizer: UIPanGestureRecognizer) {
    super.beginSwiping(recognizer)
    internalTouchLocation = recognizer.location(in: self)
    delegate?.cardDidBeginSwipe(self)
    animator.removeAllAnimations(on: self)
  }

  override open func continueSwiping(_ recognizer: UIPanGestureRecognizer) {
    super.continueSwiping(recognizer)
    delegate?.cardDidContinueSwipe(self)

    transform = swipeTransform()

    for (direction, overlay) in overlays {
      overlay.alpha = swipeOverlayPercentage(forDirection: direction)
    }
  }

  override open func didSwipe(_ recognizer: UIPanGestureRecognizer,
                              with direction: XMNoteReviewSwipeDirection) {
    super.didSwipe(recognizer, with: direction)
    delegate?.cardDidSwipe(self, withDirection: direction)
    swipeAction(direction: direction, forced: false)
  }

  override open func didCancelSwipe(_ recognizer: UIPanGestureRecognizer) {
    super.didCancelSwipe(recognizer)
    delegate?.cardDidCancelSwipe(self)
    animator.animateReset(on: self)
  }

  // MARK: - Main Methods

  public func setOverlay(_ overlay: UIView?, forDirection direction: XMNoteReviewSwipeDirection) {
    overlays[direction]?.removeFromSuperview()
    overlays[direction] = overlay

    if let overlay = overlay {
      overlayContainer.addSubview(overlay)
      overlay.alpha = 0
      overlay.setUserInteraction(false)
    }
  }

  public func setOverlays(_ overlays: [XMNoteReviewSwipeDirection: UIView]) {
    for (direction, overlay) in overlays {
      setOverlay(overlay, forDirection: direction)
    }
  }

  public func overlay(forDirection direction: XMNoteReviewSwipeDirection) -> UIView? {
    return overlays[direction]
  }

  /// Calling this method triggers a swipe animation.
  /// - Parameter direction: The direction to which the card will swipe off-screen.
  public func swipe(direction: XMNoteReviewSwipeDirection) {
    swipeAction(direction: direction, forced: true)
  }

  func swipeAction(direction: XMNoteReviewSwipeDirection, forced: Bool) {
    isUserInteractionEnabled = false
    animator.animateSwipe(on: self,
                          direction: direction,
                          forced: forced) { [weak self] finished in
      if let strongSelf = self, finished {
        strongSelf.delegate?.cardDidFinishSwipeAnimation(strongSelf)
      }
    }
  }

  /// Calling this method triggers a reverse swipe (undo) animation.
  /// - Parameter direction: The direction from which the card will be coming off-screen.
  public func reverseSwipe(from direction: XMNoteReviewSwipeDirection) {
    isUserInteractionEnabled = false
    animator.animateReverseSwipe(on: self, from: direction) { [weak self] finished in
      if finished {
        self?.isUserInteractionEnabled = true
      }
    }
  }

  public func removeAllAnimations() {
    layer.removeAllAnimations()
    animator.removeAllAnimations(on: self)
  }
}
