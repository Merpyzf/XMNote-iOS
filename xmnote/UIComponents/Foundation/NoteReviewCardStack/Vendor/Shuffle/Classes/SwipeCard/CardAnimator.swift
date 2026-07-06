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

protocol XMNoteReviewCardAnimating {
  func animateReset(on card: XMNoteReviewSwipeCard)
  func animateReverseSwipe(on card: XMNoteReviewSwipeCard,
                           from direction: XMNoteReviewSwipeDirection,
                           completion: ((Bool) -> Void)?)
  func animateSwipe(on card: XMNoteReviewSwipeCard,
                    direction: XMNoteReviewSwipeDirection,
                    forced: Bool,
                    completion: ((Bool) -> Void)?)
  func removeAllAnimations(on card: XMNoteReviewSwipeCard)
}

class XMNoteReviewCardAnimator: XMNoteReviewCardAnimating {

  static var shared = XMNoteReviewCardAnimator()

  // MARK: - Main Methods

  /// Calling this method triggers a spring-like animation on the card, eventually settling back to
  ///  it's original position.
  /// - Parameter card: The card to animate.
  func animateReset(on card: XMNoteReviewSwipeCard) {
    removeAllAnimations(on: card)

    XMNoteReviewAnimator.animateSpring(
      withDuration: card.animationOptions.totalResetDuration,
      usingSpringWithDamping: card.animationOptions.resetSpringDamping,
      options: [.curveLinear, .allowUserInteraction]) {
      if let direction = card.activeDirection(),
         let overlay = card.overlay(forDirection: direction) {
        overlay.alpha = 0
      }
      card.transform = .identity
    }
  }

  /// Calling this method triggers a reverse swipe (i.e. undo) animation on the card.
  /// - Parameters:
  ///   - card: The card to animate.
  ///   - direction: The direction from which the card will be coming off-screen.
  ///   - completion: An optional block which is called once the animation has completed.
  func animateReverseSwipe(on card: XMNoteReviewSwipeCard,
                           from direction: XMNoteReviewSwipeDirection,
                           completion: ((Bool) -> Void)?) {
    removeAllAnimations(on: card)

    // Recreate swipe
    XMNoteReviewAnimator.animateKeyFrames(withDuration: 0.0) { [weak self] in
      self?.addSwipeAnimationKeyFrames(card,
                                       direction: direction,
                                       forced: true)
    }

    // Reverse swipe
    XMNoteReviewAnimator.animateKeyFrames(
      withDuration: card.animationOptions.totalReverseSwipeDuration,
      options: .calculationModeLinear,
      animations: { [weak self] in
        self?.addReverseSwipeAnimationKeyFrames(card, direction: direction)
      },
      completion: completion)
  }

  /// Calling this method triggers a swipe animation on the card.
  /// - Parameters:
  ///   - card: The card to animate.
  ///   - direction: The direction to which the card will swipe off-screen.
  ///   - forced: A boolean idicating whether the card was swiped programmatically
  ///   - completion: An optional block which is called once the animation has completed.
  func animateSwipe(on card: XMNoteReviewSwipeCard,
                    direction: XMNoteReviewSwipeDirection,
                    forced: Bool,
                    completion: ((Bool) -> Void)?) {
    removeAllAnimations(on: card)

    let duration = swipeDuration(card, direction: direction, forced: forced)
    XMNoteReviewAnimator.animateKeyFrames(
      withDuration: duration,
      options: .calculationModeLinear,
      animations: { [weak self] in
        self?.addSwipeAnimationKeyFrames(card,
                                         direction: direction,
                                         forced: forced)
      },
      completion: completion)
  }

  /// Calling this method will remove any active animations on the card and its layers.
  /// - Parameter card: The card on which the animations will be removed.
  func removeAllAnimations(on card: XMNoteReviewSwipeCard) {
    card.layer.removeAllAnimations()
    card.swipeDirections.forEach {
      card.overlay(forDirection: $0)?.layer.removeAllAnimations()
    }
  }

  // MARK: - Animation Keyframes

  func addReverseSwipeAnimationKeyFrames(_ card: XMNoteReviewSwipeCard, direction: XMNoteReviewSwipeDirection) {
    let overlay = card.overlay(forDirection: direction)
    let relativeOverlayDuration = overlay != nil ? card.animationOptions.relativeReverseSwipeOverlayFadeDuration : 0.0

    // Transform
    XMNoteReviewAnimator.addTransformKeyFrame(to: card,
                                  relativeDuration: 1 - relativeOverlayDuration,
                                  transform: .identity)

    // Overlays
    for swipeDirection in card.swipeDirections {
      card.overlay(forDirection: direction)?.alpha = swipeDirection == direction ? 1.0 : 0.0
    }

    XMNoteReviewAnimator.addFadeKeyFrame(to: overlay,
                             withRelativeStartTime: 1 - relativeOverlayDuration,
                             relativeDuration: relativeOverlayDuration,
                             alpha: 0.0)
  }

  func addSwipeAnimationKeyFrames(_ card: XMNoteReviewSwipeCard, direction: XMNoteReviewSwipeDirection, forced: Bool) {
    let overlay = card.overlay(forDirection: direction)

    // Overlays
    for swipeDirection in card.swipeDirections.filter({ $0 != direction }) {
      card.overlay(forDirection: swipeDirection)?.alpha = 0.0
    }

    let relativeOverlayDuration = (forced && overlay != nil)
      ? card.animationOptions.relativeSwipeOverlayFadeDuration
      : 0.0
    XMNoteReviewAnimator.addFadeKeyFrame(to: overlay,
                             relativeDuration: relativeOverlayDuration,
                             alpha: 1.0)

    // Transform
    let transform = swipeTransform(card, direction: direction, forced: forced)
    XMNoteReviewAnimator.addTransformKeyFrame(to: card,
                                  withRelativeStartTime: relativeOverlayDuration,
                                  relativeDuration: 1 - relativeOverlayDuration,
                                  transform: transform)
  }

  // MARK: - Animation Calculations

  func swipeDuration(_ card: XMNoteReviewSwipeCard, direction: XMNoteReviewSwipeDirection, forced: Bool) -> TimeInterval {
    if forced {
      return card.animationOptions.totalSwipeDuration
    }

    let velocityFactor = card.dragSpeed(on: direction) / card.minimumSwipeSpeed(on: direction)

    // Card swiped below the minimum swipe speed
    if velocityFactor < 1.0 {
      return card.animationOptions.totalSwipeDuration
    }

    // Card swiped at least the minimum swipe speed -> return relative duration
    return 1.0 / TimeInterval(velocityFactor)
  }

  func swipeRotationAngle(_ card: XMNoteReviewSwipeCard, direction: XMNoteReviewSwipeDirection, forced: Bool) -> CGFloat {
    if direction == .up || direction == .down { return 0.0 }

    let rotationDirectionY: CGFloat = direction == .left ? -1.0 : 1.0

    if forced {
      return 2 * rotationDirectionY * card.animationOptions.maximumRotationAngle
    }

    guard let touchPoint = card.touchLocation else {
      return 2 * rotationDirectionY * card.animationOptions.maximumRotationAngle
    }

    if (direction == .left && touchPoint.y < card.bounds.height / 2)
        || (direction == .right && touchPoint.y >= card.bounds.height / 2) {
      return -2 * card.animationOptions.maximumRotationAngle
    }

    return 2 * card.animationOptions.maximumRotationAngle
  }

  func swipeTransform(_ card: XMNoteReviewSwipeCard, direction: XMNoteReviewSwipeDirection, forced: Bool) -> CGAffineTransform {
    let dragTranslation = CGVector(to: card.panGestureRecognizer.translation(in: card.superview))
    let normalizedDragTranslation = forced ? direction.vector : dragTranslation.normalized
    let actualTranslation = CGPoint(swipeTranslation(card,
                                                     direction: direction,
                                                     directionVector: normalizedDragTranslation))
    return CGAffineTransform(rotationAngle: swipeRotationAngle(card, direction: direction, forced: forced))
      .concatenating(CGAffineTransform(translationX: actualTranslation.x, y: actualTranslation.y))
  }

  func swipeTranslation(_ card: XMNoteReviewSwipeCard, direction: XMNoteReviewSwipeDirection, directionVector: CGVector) -> CGVector {
    let cardDiagonalLength = CGVector(card.bounds.size).length
    let windowLength = max(card.window?.bounds.width ?? 0, card.window?.bounds.height ?? 0)
    let superviewLength = max(card.superview?.bounds.width ?? 0, card.superview?.bounds.height ?? 0)
    let cardLength = max(card.bounds.width, card.bounds.height)
    let containerLength = max(cardLength, max(windowLength, superviewLength))
    let minimumOffscreenTranslation = CGVector(dx: containerLength + cardDiagonalLength,
                                               dy: containerLength + cardDiagonalLength)
    return CGVector(dx: directionVector.dx * minimumOffscreenTranslation.dx,
                    dy: directionVector.dy * minimumOffscreenTranslation.dy)
  }
}
