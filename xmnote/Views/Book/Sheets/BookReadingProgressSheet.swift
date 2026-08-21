/**
 * [INPUT]: 依赖 BookReadingDetailBook/BookReadingProgress、AppTypography 与异步保存闭包
 * [OUTPUT]: 对外提供 BookReadingProgressSheet，按 Android 纸书/电子书单位规则校验并提交阅读进度
 * [POS]: Views/Book/Sheets 阅读详情业务 Sheet，页面只负责注入当前快照与 Repository 编排闭包
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 进度编辑 Sheet；写入开始后即时禁用入口，错误留在当前任务上下文中展示。
struct BookReadingProgressSheet: View {
    let isSaving: Bool
    let onSave: (Double, Int64?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentText: String
    @State private var totalText: String
    @State private var errorMessage: String?
    private let unit: Int64

    /// 纸书始终使用页码；电子书再依据 position_unit 选择百分比、位置或页码。
    init(
        book: BookReadingDetailBook,
        progress: BookReadingProgress,
        isSaving: Bool,
        onSave: @escaping (Double, Int64?) async throws -> Void
    ) {
        self.unit = book.bookType == 0 ? 2 : book.positionUnit
        self.isSaving = isSaving
        self.onSave = onSave
        _currentText = State(initialValue: Self.initialCurrentText(progress.currentValue, unit: unit))
        let initialTotal: Int64
        if unit == 1 {
            initialTotal = book.totalPosition
        } else if unit == 2 {
            initialTotal = book.totalPagination
        } else {
            initialTotal = 0
        }
        _totalText = State(initialValue: initialTotal > 0 ? String(initialTotal) : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(currentSectionTitle) {
                    TextField(currentPlaceholder, text: $currentText)
                        .keyboardType(unit == 0 ? .decimalPad : .numberPad)
                        .textInputAutocapitalization(.never)
                }

                if unit != 0 {
                    Section(totalSectionTitle) {
                        TextField(totalPlaceholder, text: $totalText)
                            .keyboardType(.numberPad)
                            .textInputAutocapitalization(.never)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.feedbackError)
                    }
                }
            }
            .navigationTitle("更新阅读进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(!isFormComplete || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSaving)
    }

    private var isFormComplete: Bool {
        !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (unit == 0 || !totalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var currentSectionTitle: String {
        switch unit {
        case 0: "阅读进度"
        case 1: "已读位置"
        default: "已读页码"
        }
    }

    private var totalSectionTitle: String { unit == 1 ? "总位置" : "总页数" }
    private var currentPlaceholder: String { unit == 0 ? "0-100" : (unit == 1 ? "请输入已读位置" : "请输入已读页码") }
    private var totalPlaceholder: String { unit == 1 ? "请输入总位置" : "请输入总页数" }

    /// 在主 Actor 发起一次保存；父级任务取消会取消当前 Task，门闩由 ViewModel defer 释放。
    private func save() async {
        do {
            let values = try validatedValues()
            errorMessage = nil
            try await onSave(values.current, values.total)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 复刻 Android UpdateBookProgressSheetValidator 的字段顺序和用户可见文案。
    private func validatedValues() throws -> (current: Double, total: Int64?) {
        let current = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if unit == 0 {
            guard !current.isEmpty else { throw ValidationError("请输入进度") }
            guard let value = Double(current), value.isFinite else { throw ValidationError("请输入有效进度") }
            guard (0...100).contains(value) else { throw ValidationError("进度值应在 0-100 之间") }
            return (value, nil)
        }

        let isPosition = unit == 1
        guard !current.isEmpty else { throw ValidationError(isPosition ? "请输入已读位置" : "请输入已读页码") }
        guard let currentValue = Int64(current) else { throw ValidationError(isPosition ? "位置只能输入整数" : "页码只能输入整数") }
        guard currentValue > 0 else { throw ValidationError(isPosition ? "位置应大于 0" : "页码应大于 0") }

        let total = totalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !total.isEmpty else { throw ValidationError(isPosition ? "请输入总位置" : "请输入总页数") }
        guard let totalValue = Int64(total) else { throw ValidationError(isPosition ? "总位置只能输入整数" : "总页数只能输入整数") }
        guard totalValue > 0 else { throw ValidationError(isPosition ? "总位置应大于 0" : "总页数应大于 0") }
        guard currentValue <= totalValue else {
            throw ValidationError(isPosition ? "位置不能超过总位置（\(totalValue)）" : "页码不能超过总页码（\(totalValue) 页）")
        }
        return (Double(currentValue), totalValue)
    }

    private static func initialCurrentText(_ value: Double, unit: Int64) -> String {
        guard value > 0 else { return "" }
        if unit == 0 {
            return value.formatted(.number.precision(.fractionLength(0...1)))
        }
        return String(Int64(value.rounded()))
    }
}

private struct ValidationError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        self.errorDescription = message
    }
}
