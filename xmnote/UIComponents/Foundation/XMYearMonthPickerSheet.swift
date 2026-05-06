/**
 * [INPUT]: 依赖可选月份或年份集合、当前选择、当前年月标记、Calendar 与选择/取消回调
 * [OUTPUT]: 对外提供 XMYearMonthPickerSheet（项目级年月/年份选择 Sheet）
 * [POS]: UIComponents/Foundation 基础组件，服务需要随机访问选择年份或年月的业务场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 项目级年月/年份选择弹层，只维护 Sheet 内草稿状态，由宿主在关闭后提交真实业务状态。
struct XMYearMonthPickerSheet: View {
    enum Mode {
        case yearMonth
        case year
    }

    private enum Layout {
        static let yearMonthRegularPresentationHeight: CGFloat = 450
        static let yearMonthAccessibilityPresentationHeight: CGFloat = 540
        static let yearRegularPresentationHeight: CGFloat = 300
        static let yearAccessibilityPresentationHeight: CGFloat = 380
        static let sheetTopPadding: CGFloat = Spacing.section
        static let headerBottomPadding: CGFloat = Spacing.base
        static let sheetBottomPadding: CGFloat = Spacing.double
        static let headerMinHeight: CGFloat = Spacing.actionReserved
        static let closeButtonHitSize: CGFloat = Spacing.actionReserved
        static let closeButtonVisualSize: CGFloat = 32
        static let yearChipMinHeight: CGFloat = 38
        static let yearButtonMinHeight: CGFloat = 54
        static let monthButtonMinHeight: CGFloat = 54
        static let gridSpacing: CGFloat = Spacing.base
        static let selectedStrokeWidth: CGFloat = 1
        static let currentDotSize: CGFloat = 6
        static let currentDotInset: CGFloat = Spacing.half
    }

    let mode: Mode
    let title: String
    let calendar: Calendar
    let availableMonths: [Date]
    let selectedMonth: Date?
    let currentMonth: Date?
    let onSelectMonth: ((Date) -> Void)?
    let availableYears: [Int]
    let selectedYear: Int?
    let currentYear: Int?
    let onSelectYear: ((Int) -> Void)?
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draftYear: Int

    /// 创建年月选择 Sheet，月份输入会被归一到月份首日并去重排序。
    init(
        title: String = "选择年月",
        availableMonths: [Date],
        selectedMonth: Date,
        currentMonth: Date,
        calendar: Calendar,
        onSelectMonth: @escaping (Date) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        let normalizedSelectedMonth = Self.monthStart(of: selectedMonth, using: calendar)
        self.mode = .yearMonth
        self.title = title
        self.calendar = calendar
        self.availableMonths = Self.normalizedUniqueMonths(availableMonths, using: calendar)
        self.selectedMonth = normalizedSelectedMonth
        self.currentMonth = Self.monthStart(of: currentMonth, using: calendar)
        self.onSelectMonth = onSelectMonth
        self.availableYears = []
        self.selectedYear = nil
        self.currentYear = nil
        self.onSelectYear = nil
        self.onCancel = onCancel
        _draftYear = State(initialValue: calendar.component(.year, from: normalizedSelectedMonth))
    }

    /// 创建年份选择 Sheet，年份输入保持调用方顺序并去重。
    init(
        title: String = "选择年份",
        availableYears: [Int],
        selectedYear: Int,
        currentYear: Int,
        calendar: Calendar,
        onSelectYear: @escaping (Int) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.mode = .year
        self.title = title
        self.calendar = calendar
        self.availableMonths = []
        self.selectedMonth = nil
        self.currentMonth = nil
        self.onSelectMonth = nil
        self.availableYears = Self.normalizedUniqueYears(availableYears, fallback: selectedYear)
        self.selectedYear = selectedYear
        self.currentYear = currentYear
        self.onSelectYear = onSelectYear
        self.onCancel = onCancel
        _draftYear = State(initialValue: selectedYear)
    }

    /// 返回统一的选择弹层高度，让宿主以内容模式和动态字体共同决定固定 detent。
    static func preferredPresentationHeight(for dynamicTypeSize: DynamicTypeSize, mode: Mode) -> CGFloat {
        switch mode {
        case .yearMonth:
            return dynamicTypeSize >= .accessibility1
                ? Layout.yearMonthAccessibilityPresentationHeight
                : Layout.yearMonthRegularPresentationHeight
        case .year:
            return dynamicTypeSize >= .accessibility1
                ? Layout.yearAccessibilityPresentationHeight
                : Layout.yearRegularPresentationHeight
        }
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            header
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Layout.sheetTopPadding)
                .padding(.bottom, Layout.headerBottomPadding)

            ScrollView {
                content
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.bottom, Layout.sheetBottomPadding)
            }
        }
        .background(Color.surfaceSheet)
    }
}

private extension XMYearMonthPickerSheet {
    var header: some View {
        ZStack(alignment: .center) {
            Text(title)
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Layout.closeButtonHitSize)

            HStack {
                Spacer(minLength: 0)
                closeButton
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Layout.headerMinHeight)
    }

    var closeButton: some View {
        Button {
            onCancel()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textSecondary)
                .frame(width: Layout.closeButtonVisualSize, height: Layout.closeButtonVisualSize)
                .background(Color.controlFillSecondary.opacity(0.82), in: Circle())
                .frame(width: Layout.closeButtonHitSize, height: Layout.closeButtonHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(closeButtonAccessibilityLabel)
    }

    @ViewBuilder
    var content: some View {
        switch mode {
        case .yearMonth:
            VStack(alignment: .leading, spacing: Spacing.section) {
                yearSelector
                monthGrid
            }
        case .year:
            yearGrid
        }
    }

    var yearSelector: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.half) {
                    ForEach(monthModeYears, id: \.self) { year in
                        yearChip(year)
                            .id(year)
                    }
                }
                .padding(.vertical, Spacing.compact)
            }
            .onAppear {
                scrollProxy.scrollTo(draftYear, anchor: .center)
            }
            .onChange(of: draftYear) { _, year in
                withAnimation(.snappy(duration: 0.24)) {
                    scrollProxy.scrollTo(year, anchor: .center)
                }
            }
        }
    }

    var monthGrid: some View {
        LazyVGrid(columns: monthGridColumns, spacing: Layout.gridSpacing) {
            ForEach(1...12, id: \.self) { month in
                monthButton(month)
            }
        }
    }

    var yearGrid: some View {
        LazyVGrid(columns: yearGridColumns, spacing: Layout.gridSpacing) {
            ForEach(availableYears, id: \.self) { year in
                yearButton(year)
            }
        }
    }

    func yearChip(_ year: Int) -> some View {
        let isSelected = year == draftYear
        return Button {
            guard year != draftYear else { return }
            withAnimation(.snappy(duration: 0.24)) {
                draftYear = year
            }
        } label: {
            Text(verbatim: "\(year)")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(isSelected ? Color.brandDeep : Color.textPrimary)
                .monospacedDigit()
                .padding(.horizontal, Spacing.base)
                .frame(minHeight: Layout.yearChipMinHeight)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.brand.opacity(0.10) : Color.controlFillSecondary.opacity(0.82))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected ? Color.brand.opacity(0.30) : Color.surfaceBorderSubtle.opacity(0.72),
                            lineWidth: CardStyle.borderWidth
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择 \(year) 年")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func monthButton(_ month: Int) -> some View {
        let monthStart = monthStart(year: draftYear, month: month)
        let isEnabled = monthStart.map { availableMonthSet.contains($0) } ?? false
        let isSelected = monthStart.map { monthStart in
            selectedMonth.map { selectedMonth in
                calendar.isDate(monthStart, equalTo: selectedMonth, toGranularity: .month)
            } ?? false
        } ?? false
        let isCurrent = monthStart.map { monthStart in
            currentMonth.map { currentMonth in
                calendar.isDate(monthStart, equalTo: currentMonth, toGranularity: .month)
            } ?? false
        } ?? false

        return Button {
            guard let monthStart, isEnabled else { return }
            onSelectMonth?(monthStart)
            dismiss()
        } label: {
            ZStack(alignment: .topTrailing) {
                Text("\(month)月")
                    .font(isSelected ? AppTypography.headlineSemibold : AppTypography.headline)
                    .foregroundStyle(titleColor(isEnabled: isEnabled, isSelected: isSelected))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: Layout.monthButtonMinHeight)

                if isCurrent {
                    currentDot(isEnabled: isEnabled)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Layout.monthButtonMinHeight)
            .background(buttonBackground(isEnabled: isEnabled, isSelected: isSelected))
            .overlay(buttonStroke(isEnabled: isEnabled, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(monthAccessibilityLabel(month: month, isCurrent: isCurrent))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func yearButton(_ year: Int) -> some View {
        let isSelected = year == selectedYear
        let isCurrent = year == currentYear
        return Button {
            onSelectYear?(year)
            dismiss()
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(verbatim: "\(year)")
                    .font(isSelected ? AppTypography.headlineSemibold : AppTypography.headline)
                    .foregroundStyle(titleColor(isEnabled: true, isSelected: isSelected))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: Layout.yearButtonMinHeight)

                if isCurrent {
                    currentDot(isEnabled: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Layout.yearButtonMinHeight)
            .background(buttonBackground(isEnabled: true, isSelected: isSelected))
            .overlay(buttonStroke(isEnabled: true, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(yearAccessibilityLabel(year: year, isCurrent: isCurrent))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func currentDot(isEnabled: Bool) -> some View {
        Circle()
            .fill(isEnabled ? Color.brand : Color.textHint.opacity(0.45))
            .frame(width: Layout.currentDotSize, height: Layout.currentDotSize)
            .padding(.top, Layout.currentDotInset)
            .padding(.trailing, Layout.currentDotInset)
    }

    func titleColor(isEnabled: Bool, isSelected: Bool) -> Color {
        if !isEnabled {
            return Color.textHint.opacity(0.45)
        }
        return isSelected ? Color.brandDeep : Color.textPrimary
    }

    func buttonBackground(isEnabled: Bool, isSelected: Bool) -> some ShapeStyle {
        if isSelected {
            return Color.brand.opacity(0.18)
        }
        if isEnabled {
            return Color.surfaceNested
        }
        return Color.controlFillSecondary.opacity(0.28)
    }

    func buttonStroke(isEnabled: Bool, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
            .stroke(
                isSelected
                    ? Color.brand.opacity(0.45)
                    : (isEnabled ? Color.surfaceBorderSubtle : Color.surfaceBorderSubtle.opacity(0.22)),
                lineWidth: isSelected ? Layout.selectedStrokeWidth : CardStyle.borderWidth
            )
    }

    func monthAccessibilityLabel(month: Int, isCurrent: Bool) -> String {
        if isCurrent {
            return "选择 \(draftYear) 年 \(month) 月，当前月份"
        }
        return "选择 \(draftYear) 年 \(month) 月"
    }

    func yearAccessibilityLabel(year: Int, isCurrent: Bool) -> String {
        if isCurrent {
            return "选择 \(year) 年，当前年份"
        }
        return "选择 \(year) 年"
    }

    var closeButtonAccessibilityLabel: String {
        switch mode {
        case .yearMonth:
            return "关闭年月选择"
        case .year:
            return "关闭年份选择"
        }
    }

    var monthGridColumns: [GridItem] {
        let count = dynamicTypeSize >= .accessibility1 ? 2 : 3
        return Array(
            repeating: GridItem(.flexible(), spacing: Layout.gridSpacing),
            count: count
        )
    }

    var yearGridColumns: [GridItem] {
        let count = dynamicTypeSize >= .accessibility1 ? 2 : 3
        return Array(
            repeating: GridItem(.flexible(), spacing: Layout.gridSpacing),
            count: count
        )
    }

    var monthModeYears: [Int] {
        let years = yearRangeBounds
        guard years.lowerBound <= years.upperBound else {
            return [selectedMonth.map { calendar.component(.year, from: $0) } ?? draftYear]
        }
        return Array(years.lowerBound...years.upperBound)
    }

    var yearRangeBounds: ClosedRange<Int> {
        let selectedYear = selectedMonth.map { calendar.component(.year, from: $0) } ?? draftYear
        let currentYear = currentMonth.map { calendar.component(.year, from: $0) } ?? selectedYear
        let availableYearValues = availableMonths.map { calendar.component(.year, from: $0) }
        let lower = min(availableYearValues.min() ?? selectedYear, selectedYear, currentYear)
        let upper = max(availableYearValues.max() ?? selectedYear, selectedYear, currentYear)
        return lower...upper
    }

    var availableMonthSet: Set<Date> {
        Set(availableMonths)
    }

    func monthStart(year: Int, month: Int) -> Date? {
        let components = DateComponents(year: year, month: month, day: 1)
        guard let date = calendar.date(from: components) else { return nil }
        return Self.monthStart(of: date, using: calendar)
    }

    static func normalizedUniqueMonths(_ months: [Date], using calendar: Calendar) -> [Date] {
        months
            .map { monthStart(of: $0, using: calendar) }
            .reduce(into: [Date]()) { result, month in
                if !result.contains(month) {
                    result.append(month)
                }
            }
            .sorted()
    }

    static func normalizedUniqueYears(_ years: [Int], fallback: Int) -> [Int] {
        let uniqueYears = years.reduce(into: [Int]()) { result, year in
            if !result.contains(year) {
                result.append(year)
            }
        }
        return uniqueYears.isEmpty ? [fallback] : uniqueYears
    }

    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month], from: normalized)
        let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: start)
    }
}

#Preview("年月选择") {
    let calendar = Calendar.current
    let currentMonth = XMYearMonthPickerSheet.monthStart(of: Date(), using: calendar)
    let months = (-18...0).compactMap { offset in
        calendar.date(byAdding: .month, value: offset, to: currentMonth)
    }

    XMYearMonthPickerSheet(
        availableMonths: months,
        selectedMonth: currentMonth,
        currentMonth: currentMonth,
        calendar: calendar,
        onSelectMonth: { _ in }
    )
    .presentationDetents([.height(XMYearMonthPickerSheet.preferredPresentationHeight(for: .medium, mode: .yearMonth))])
}

#Preview("年份选择") {
    let calendar = Calendar.current
    let year = calendar.component(.year, from: Date())
    let years = Array((year - 5)...year).reversed()

    XMYearMonthPickerSheet(
        availableYears: Array(years),
        selectedYear: year,
        currentYear: year,
        calendar: calendar,
        onSelectYear: { _ in }
    )
    .presentationDetents([.height(XMYearMonthPickerSheet.preferredPresentationHeight(for: .medium, mode: .year))])
}
