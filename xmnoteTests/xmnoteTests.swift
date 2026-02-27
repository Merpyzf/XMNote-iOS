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

    @Test func heatmapLevelFromCheckInSecondsThresholds() {
        #expect(HeatmapLevel.from(checkInSeconds: 0) == .none)
        #expect(HeatmapLevel.from(checkInSeconds: 1) == .veryLess)
        #expect(HeatmapLevel.from(checkInSeconds: 1200) == .veryLess)
        #expect(HeatmapLevel.from(checkInSeconds: 1201) == .less)
        #expect(HeatmapLevel.from(checkInSeconds: 2400) == .less)
        #expect(HeatmapLevel.from(checkInSeconds: 2401) == .more)
        #expect(HeatmapLevel.from(checkInSeconds: 3600) == .more)
        #expect(HeatmapLevel.from(checkInSeconds: 3601) == .veryMore)
    }

    @Test func heatmapDayLevelIncludesCheckInActivity() {
        let day = HeatmapDay(
            id: Date(timeIntervalSince1970: 0),
            readSeconds: 0,
            noteCount: 0,
            checkInCount: 1,
            checkInSeconds: 20 * 60
        )
        #expect(day.level == .veryLess)
    }

    @Test func heatmapDayLevelPicksMaxAcrossThreeSources() {
        let day = HeatmapDay(
            id: Date(timeIntervalSince1970: 0),
            readSeconds: 500,
            noteCount: 8,
            checkInCount: 3,
            checkInSeconds: 5000
        )
        #expect(day.level == .veryMore)
    }
}
