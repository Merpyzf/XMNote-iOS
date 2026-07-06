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

struct XMNoteReviewSwipe: Equatable {
  var index: Int
  var direction: XMNoteReviewSwipeDirection
}

protocol XMNoteReviewCardStackStateManaging {
  var remainingIndices: [Int] { get }
  var swipes: [XMNoteReviewSwipe] { get }
  var totalIndexCount: Int { get }

  func insert(_ index: Int, at position: Int)

  func delete(_ index: Int)
  func delete(_ indices: [Int])
  func delete(indexAtPosition position: Int)
  func delete(indicesAtPositions positions: [Int])

  func swipe(_ direction: XMNoteReviewSwipeDirection)
  func undoSwipe() -> XMNoteReviewSwipe?
  func shift(withDistance distance: Int)
  func reset(withNumberOfCards numberOfCards: Int)
}

/// An internal class to manage the current state of the card stack.
class XMNoteReviewCardStackStateManager: XMNoteReviewCardStackStateManaging {

  /// The indices of the data source which have yet to be swiped.
  ///
  /// This array reflects the current order of the card stack, with the first element equal to the index of
  /// the top card in the data source. The order of this array accounts for both swiped and shifted cards in the stack.
  var remainingIndices: [Int] = []

  /// An array containing the swipe history of the card stack.
  var swipes: [XMNoteReviewSwipe] = []

  var totalIndexCount: Int {
    return remainingIndices.count + swipes.count
  }

  // MARK: - Insertion

  func insert(_ index: Int, at position: Int) {
    precondition(index >= 0, "Attempt to insert card at index \(index)")
    //swiftlint:disable:next line_length
    precondition(index <= totalIndexCount, "Attempt to insert card at index \(index), but there are only \(totalIndexCount + 1) cards after the update")
    precondition(position >= 0, "Attempt to insert card at position \(position)")
    //swiftlint:disable:next line_length
    precondition(position <= remainingIndices.count, "Attempt to insert card at position \(position), but there are only \(remainingIndices.count + 1) cards remaining in the stack after the update")

    // Increment all stored indices greater than or equal to index by 1
    remainingIndices = remainingIndices.map { $0 >= index ? $0 + 1 : $0 }
    swipes = swipes.map { $0.index >= index ? XMNoteReviewSwipe(index: $0.index + 1, direction: $0.direction) : $0 }

    remainingIndices.insert(index, at: position)
  }

  // MARK: - Deletion

  func delete(_ index: Int) {
    precondition(index >= 0, "Attempt to delete card at index \(index)")
    //swiftlint:disable:next line_length
    precondition(index < totalIndexCount, "Attempt to delete card at index \(index), but there are only \(totalIndexCount) cards before the update")

    swipes.removeAll { return $0.index == index }

    if let position = remainingIndices.firstIndex(of: index) {
      remainingIndices.remove(at: position)
    }

    // Decrement all stored indices greater than or equal to index by 1
    remainingIndices = remainingIndices.map { $0 >= index ? $0 - 1 : $0 }
    swipes = swipes.map { $0.index >= index ? XMNoteReviewSwipe(index: $0.index - 1, direction: $0.direction) : $0 }
  }

  func delete(_ indices: [Int]) {
    var remainingIndices = indices.removingDuplicates()

    while !remainingIndices.isEmpty {
      let index = remainingIndices[0]
      delete(index)

      remainingIndices.remove(at: 0)

      // Decrement all remaining indices greater than or equal to index by 1
      remainingIndices = remainingIndices.map { $0 >= index ? $0 - 1 : $0 }
    }
  }

  func delete(indexAtPosition position: Int) {
    precondition(position >= 0, "Attempt to delete card at position \(position)")
    //swiftlint:disable:next line_length
    precondition(position < remainingIndices.count, "Attempt to delete card at position \(position), but there are only \(remainingIndices.count) cards remaining in the stack before the update")

    // Decrement all stored indices greater than or equal to index by 1
    let index = remainingIndices.remove(at: position)
    remainingIndices = remainingIndices.map { $0 >= index ? $0 - 1 : $0 }
    swipes = swipes.map { $0.index >= index ? XMNoteReviewSwipe(index: $0.index - 1, direction: $0.direction) : $0 }
  }

  func delete(indicesAtPositions positions: [Int]) {
    var remainingPositions = positions.removingDuplicates()

    while !remainingPositions.isEmpty {
      let position = remainingPositions[0]
      delete(indexAtPosition: position)

      remainingPositions.remove(at: 0)

      // Decrement all remaining positions greater than or equal to position by 1
      remainingPositions = remainingPositions.map { $0 >= position ? $0 - 1 : $0 }
    }
  }

  // MARK: - Main Methods

  func swipe(_ direction: XMNoteReviewSwipeDirection) {
    if remainingIndices.isEmpty { return }
    let firstIndex = remainingIndices.removeFirst()
    let swipe = XMNoteReviewSwipe(index: firstIndex, direction: direction)
    swipes.append(swipe)
  }

  func undoSwipe() -> XMNoteReviewSwipe? {
    if swipes.isEmpty { return nil }
    let lastSwipe = swipes.removeLast()
    remainingIndices.insert(lastSwipe.index, at: 0)
    return lastSwipe
  }

  func shift(withDistance distance: Int) {
    remainingIndices.shift(withDistance: distance)
  }

  func reset(withNumberOfCards numberOfCards: Int) {
    self.remainingIndices = Array(0..<numberOfCards)
    self.swipes = []
  }
}
