/**
 * [INPUT]: 依赖 BookshelfSearchDrawerPresentation、SwiftUI 动态布局与书架管理模式动效调用方
 * [OUTPUT]: 对外提供书架一级页与二级列表复用的编辑展示阶段和搜索抽屉状态
 * [POS]: Book 模块页面私有交互状态协作者，收敛书架浏览/整理模式在不同页面中的重复本地状态机
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架整理模式的本地 chrome 阶段，描述顶部编辑栏与普通浏览栏的展示交接。
enum BookshelfEditingChromePhase: Equatable {
    case normal
    case enteringEdit
    case editing
    case exitingEdit

    /// 当前阶段是否展示顶部编辑 chrome。
    var showsEditHeader: Bool {
        self == .enteringEdit || self == .editing || self == .exitingEdit
    }
}

/// 承载书架整理模式的页面本地展示状态，不持有业务选择，避免与 ViewModel 形成双 owner。
struct BookshelfEditingPresentationState: Equatable {
    var phase: BookshelfEditingChromePhase = .normal
    var isChoreographyActive = false

    /// 当前阶段是否展示顶部编辑 chrome。
    var showsEditHeader: Bool {
        phase.showsEditHeader
    }

    /// 页面失活或切换上下文时收束到普通浏览态。
    mutating func resetForContextLoss() {
        phase = .normal
        isChoreographyActive = false
    }
}

/// 承载书架搜索 drawer 的页面本地状态，业务关键词仍由对应 ViewModel 持有。
struct BookshelfSearchDrawerState: Equatable {
    var presentation: BookshelfSearchDrawerPresentation = .hidden
    var isFocused = false
    var draftKeyword = ""
    var focusTrigger = 0

    /// 当前输入草稿去除首尾空白后的关键词。
    var normalizedDraftKeyword: String {
        draftKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 当前是否存在用户可见的非空搜索草稿。
    var hasDraftKeyword: Bool {
        !normalizedDraftKeyword.isEmpty
    }

    /// 当前搜索 surface 是否需要保持展开。
    func isSurfacePresented(isSearchActive: Bool, hasSearchKeyword: Bool) -> Bool {
        presentation.isPinned || isFocused || isSearchActive || hasDraftKeyword || hasSearchKeyword
    }

    /// 若草稿为空且已有业务关键词，则用业务关键词回填输入草稿。
    mutating func seedDraftIfNeeded(hasSearchKeyword: Bool, searchKeyword: String) {
        guard draftKeyword.isEmpty, hasSearchKeyword else { return }
        draftKeyword = searchKeyword
    }

    /// 固定搜索 drawer，保持其在 collection 顶部可见。
    mutating func pin() {
        presentation = .pinned
    }

    /// 请求搜索输入框获得焦点。
    mutating func requestFocus() {
        focusTrigger += 1
    }

    /// 同步输入框焦点状态。
    mutating func updateFocus(_ isFocused: Bool) {
        self.isFocused = isFocused
    }

    /// 记录用户输入并返回供 ViewModel 过滤使用的标准化关键词。
    mutating func updateDraft(_ keyword: String) -> String {
        draftKeyword = keyword
        presentation = .pinned
        return normalizedDraftKeyword
    }

    /// 确认搜索输入并返回去除首尾空白后的关键词。
    mutating func submit(_ keyword: String) -> String {
        let submittedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        draftKeyword = submittedKeyword
        return submittedKeyword
    }

    /// 清空输入草稿并保持 drawer 固定。
    mutating func clearDraftAndPin(requestsFocus: Bool) {
        draftKeyword = ""
        presentation = .pinned
        if requestsFocus {
            requestFocus()
        }
    }

    /// 完整收起搜索 drawer 与输入焦点。
    mutating func collapse() {
        draftKeyword = ""
        presentation = .hidden
        isFocused = false
    }

    /// 进入整理态时收起键盘焦点；有业务关键词时继续固定 drawer 展示过滤结果。
    mutating func prepareForEditing(hasSearchKeyword: Bool, searchKeyword: String) {
        isFocused = false
        if hasSearchKeyword {
            draftKeyword = searchKeyword
            presentation = .pinned
        } else {
            draftKeyword = ""
            presentation = .hidden
        }
    }
}
