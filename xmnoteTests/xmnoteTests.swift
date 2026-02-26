//
//  xmnoteTests.swift
//  xmnoteTests
//
//  Created by 王珂 on 2026/2/9.
//

import Testing
import Foundation
@testable import xmnote

struct xmnoteTests {

    @Test func serializerCombinedParagraphWithBulletThenQuote() {
        let original = HTMLSerializer.comboParagraphOrderStrategy
        defer { HTMLSerializer.comboParagraphOrderStrategy = original }

        HTMLSerializer.comboParagraphOrderStrategy = .bulletThenQuote
        let attributed = HTMLParser.parse("<ul><li><blockquote>组合段落</blockquote></li></ul>")
        let html = HTMLSerializer.serialize(attributed)
        #expect(html == "<ul><li><blockquote>组合段落</blockquote></li></ul>")
    }

    @Test func serializerCombinedParagraphWithQuoteThenBullet() {
        let original = HTMLSerializer.comboParagraphOrderStrategy
        defer { HTMLSerializer.comboParagraphOrderStrategy = original }

        HTMLSerializer.comboParagraphOrderStrategy = .quoteThenBullet
        let attributed = HTMLParser.parse("<ul><li><blockquote>组合段落</blockquote></li></ul>")
        let html = HTMLSerializer.serialize(attributed)
        #expect(html == "<blockquote><ul><li>组合段落</li></ul></blockquote>")
    }

    @Test func richTextBridgeRemovesAndroidZWJPrefix() {
        let attributed = RichTextBridge.htmlToAttributed("&zwj;<b>Android</b> 兼容")
        #expect(attributed.string == "Android 兼容")
    }
}
