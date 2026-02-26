//
//  RichTextTestViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import Foundation
import UIKit

// MARK: - 示例 HTML 数据

/// 覆盖所有格式的测试用例
struct HTMLSample: Identifiable {
    let id: Int
    let title: String
    let html: String
}

private let htmlSamples: [HTMLSample] = [
    HTMLSample(id: 0, title: "粗体 + 斜体", html: "<b>粗体文字</b> 普通文字 <i>斜体文字</i> <b><i>粗斜体</i></b>"),
    HTMLSample(id: 1, title: "下划线 + 删除线", html: "<u>下划线文字</u> 普通文字 <del>删除线文字</del> <u><del>双重装饰</del></u>"),
    HTMLSample(id: 2, title: "高亮（多色）", html: """
        <mark style="background-color:-394337">黄色高亮</mark> \
        <mark style="background-color:-1974791">粉色高亮</mark> \
        <mark style="background-color:-3670802">绿色高亮</mark>
        """),
    HTMLSample(id: 3, title: "链接", html: "访问 <a href=\"https://example.com\">示例网站</a> 了解更多"),
    HTMLSample(id: 4, title: "无序列表", html: "<ul><li>第一项</li><li>第二项</li><li>第三项</li></ul>"),
    HTMLSample(id: 5, title: "引用块", html: "<blockquote>这是一段引用文字，来自某本书的精彩段落。</blockquote>"),
    HTMLSample(id: 6, title: "混合格式", html: """
        <b>重要提示：</b>这段文字包含<i>斜体</i>、<u>下划线</u>和\
        <mark style="background-color:-394337">高亮</mark>。<br>\
        <del>这行被删除了</del><br>\
        <a href=\"https://example.com\">点击链接</a>
        """),
    HTMLSample(id: 7, title: "Android &zwj; 前缀", html: "&zwj;<b>Android</b> 端序列化的 HTML 会带 <i>零宽连接符</i> 前缀"),
]

// MARK: - ViewModel

@Observable
class RichTextTestViewModel {

    // MARK: - 编辑器状态

    var contentText = NSAttributedString()
    var contentFormats = Set<RichTextFormat>()

    var ideaText = NSAttributedString()
    var ideaFormats = Set<RichTextFormat>()

    // MARK: - 示例选择

    var selectedSampleIndex = 0
    let samples = htmlSamples

    // MARK: - 高亮色

    var selectedHighlightARGB: UInt32 = HighlightColors.defaultHighlightColor

    // MARK: - HTML 输出

    var contentHTML = ""
    var ideaHTML = ""

    // MARK: - 往返测试

    var roundTripResult: RoundTripResult?

    enum RoundTripResult {
        case consistent
        case inconsistent(original: String, roundTripped: String)
    }

    // MARK: - 操作

    /// 将选中的示例 HTML 加载到摘录编辑器
    func loadSampleToContent() {
        let sample = samples[selectedSampleIndex]
        contentText = HTMLParser.parse(sample.html)
    }

    /// 序列化摘录编辑器内容为 HTML
    func serializeContent() {
        contentHTML = HTMLSerializer.serialize(contentText)
    }

    /// 序列化想法编辑器内容为 HTML
    func serializeIdea() {
        ideaHTML = HTMLSerializer.serialize(ideaText)
    }

    /// HTML 往返一致性测试：HTML → NSAttributedString → HTML
    func roundTripTest() {
        let sample = samples[selectedSampleIndex]
        let originalHTML = sample.html

        // HTML → NSAttributedString
        let attributed = HTMLParser.parse(originalHTML)
        // NSAttributedString → HTML
        let reserializedHTML = HTMLSerializer.serialize(attributed)

        // 再做一次往返确认稳定性：reserialized → parse → serialize
        let secondPass = HTMLSerializer.serialize(HTMLParser.parse(reserializedHTML))

        if reserializedHTML == secondPass {
            roundTripResult = .consistent
        } else {
            roundTripResult = .inconsistent(original: reserializedHTML, roundTripped: secondPass)
        }
    }
}
