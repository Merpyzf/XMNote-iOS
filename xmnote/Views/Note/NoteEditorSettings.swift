/**
 * [INPUT]: 依赖 UserDefaults 持久化书摘编辑设置项，依赖 NoteEditorLayoutMode/NoteEditorOCREntryMode 定义编辑模式语义
 * [OUTPUT]: 对外提供 NoteEditorSettings 与 NoteEditorOCREntryMode，供 NoteEditorView 与设置页双向绑定
 * [POS]: Note 模块书摘编辑设置状态容器，统一管理布局、OCR 入口与屏幕行为偏好
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// OCR 入口模式：单入口（工具栏按钮）或双入口（摘录/想法独立按钮）。
enum NoteEditorOCREntryMode: Int, CaseIterable, Identifiable {
    case singleEntry = 0
    case splitButtons = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .singleEntry:
            return "单入口"
        case .splitButtons:
            return "双入口"
        }
    }
}

/// 书摘编辑设置状态源，负责本地持久化与设置值合法性收口。
@MainActor
@Observable
final class NoteEditorSettings {
    var layoutModeRawValue: Int {
        didSet {
            if NoteEditorLayoutMode(rawValue: layoutModeRawValue) == nil {
                layoutModeRawValue = NoteEditorLayoutMode.classic.rawValue
            }
            save(layoutModeRawValue, forKey: Keys.layoutModeRawValue)
        }
    }

    var continueEditEnabled: Bool {
        didSet { save(continueEditEnabled, forKey: Keys.continueEditEnabled) }
    }

    var ocrEntryModeRawValue: Int {
        didSet {
            if NoteEditorOCREntryMode(rawValue: ocrEntryModeRawValue) == nil {
                ocrEntryModeRawValue = NoteEditorOCREntryMode.singleEntry.rawValue
            }
            save(ocrEntryModeRawValue, forKey: Keys.ocrEntryModeRawValue)
        }
    }

    var keepScreenOnEnabled: Bool {
        didSet { save(keepScreenOnEnabled, forKey: Keys.keepScreenOnEnabled) }
    }

    var autoDimSeconds: Int {
        didSet {
            if !Self.autoDimSecondOptions.contains(autoDimSeconds) {
                autoDimSeconds = 0
            }
            save(autoDimSeconds, forKey: Keys.autoDimSeconds)
        }
    }

    var autoDimBrightness: Double {
        didSet {
            autoDimBrightness = min(max(autoDimBrightness, 0.1), 1.0)
            save(autoDimBrightness, forKey: Keys.autoDimBrightness)
        }
    }

    var ocrEntryMode: NoteEditorOCREntryMode {
        NoteEditorOCREntryMode(rawValue: ocrEntryModeRawValue) ?? .singleEntry
    }

    static let autoDimSecondOptions: [Int] = [0, 5, 10, 20, 30, 40, 50, 60, 120]
    static let defaultAutoDimBrightness = 0.4

    init(defaults: UserDefaults = .standard) {
        let storedLayoutMode = defaults.integer(forKey: Keys.layoutModeRawValue)
        self.layoutModeRawValue = NoteEditorLayoutMode(rawValue: storedLayoutMode)?.rawValue ?? NoteEditorLayoutMode.classic.rawValue
        self.continueEditEnabled = defaults.object(forKey: Keys.continueEditEnabled) as? Bool ?? false

        let storedOCREntryMode = defaults.integer(forKey: Keys.ocrEntryModeRawValue)
        self.ocrEntryModeRawValue = NoteEditorOCREntryMode(rawValue: storedOCREntryMode)?.rawValue ?? NoteEditorOCREntryMode.singleEntry.rawValue

        self.keepScreenOnEnabled = defaults.object(forKey: Keys.keepScreenOnEnabled) as? Bool ?? false

        let storedAutoDimSeconds = defaults.integer(forKey: Keys.autoDimSeconds)
        self.autoDimSeconds = Self.autoDimSecondOptions.contains(storedAutoDimSeconds) ? storedAutoDimSeconds : 0

        let storedBrightness = defaults.object(forKey: Keys.autoDimBrightness) as? Double
        self.autoDimBrightness = min(max(storedBrightness ?? Self.defaultAutoDimBrightness, 0.1), 1.0)
    }

    /// 封装autoDimDisplayTitle对应的业务步骤，确保调用方可以稳定复用该能力。
    static func autoDimDisplayTitle(seconds: Int) -> String {
        switch seconds {
        case 0:
            return "关"
        case 5:
            return "5秒"
        case 10:
            return "10秒"
        case 20:
            return "20秒"
        case 30:
            return "30秒"
        case 40:
            return "40秒"
        case 50:
            return "50秒"
        case 60:
            return "1分钟"
        case 120:
            return "2分钟"
        default:
            return "\(seconds)秒"
        }
    }
}

private extension NoteEditorSettings {
    enum Keys {
        static let layoutModeRawValue = "note.editor.layout_mode"
        static let continueEditEnabled = "note.editor.continue_edit"
        static let ocrEntryModeRawValue = "note.editor.ocr_entry_mode"
        static let keepScreenOnEnabled = "note.editor.keep_screen_on"
        static let autoDimSeconds = "note.editor.auto_dim_seconds"
        static let autoDimBrightness = "note.editor.auto_dim_brightness"
    }

    func save(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func save(_ value: Int, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func save(_ value: Double, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
