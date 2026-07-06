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

extension UIView {

  /// Sets the `isUserInteractionEnabled` property on the view and all of it's subviews.
  ///
  /// - Parameter isEnabled: the value to set the `isUserInteractionEnabled` property to.
  func setUserInteraction(_ isEnabled: Bool) {
    isUserInteractionEnabled = isEnabled
    for subview in subviews {
      subview.setUserInteraction(isEnabled)
    }
  }

  func nearestSuperview<T: UIView>(of type: T.Type) -> T? {
    var current: UIView? = self
    while let view = current {
      if let typedView = view as? T {
        return typedView
      }
      current = view.superview
    }
    return nil
  }
}
