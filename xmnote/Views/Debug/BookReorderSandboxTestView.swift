#if DEBUG
/**
 * [INPUT]: 依赖 BookReorderSandboxTestViewModel 提供 DEBUG 内存书架样本、拖拽状态、禁用原因与模拟写入日志
 * [OUTPUT]: 对外提供 BookReorderSandboxTestView，用 SwiftUI LazyVGrid 验证 Android 首页书籍管理迁移风险
 * [POS]: Debug 模块书架手动排序验证页，只用于技术验证，不进入生产书籍管理路径
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct BookReorderSandboxTestView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = BookReorderSandboxTestViewModel()
    @State private var itemFrames: [Int64: CGRect] = [:]

    private static let gridCoordinateSpace = "book-reorder-sandbox-grid"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.double) {
                summarySection
                controlsSection
                gridSection
                orderLogSection
                migrationNotesSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("书架手动排序验证")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: viewModel.feedbackTick)
    }

    private var summarySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Label("SwiftUI 网格重排沙盒", systemImage: "square.grid.3x3")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text("验证结论：List 的系统行移动不能直接平替当前书籍页 LazyVGrid。网格手动排序可用 SwiftUI 完成，但需要独立处理命中、占位、置顶边界与提交回滚。")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.half) {
                    statusBadge("DEBUG 沙盒", tint: Color.brand)
                    statusBadge("不写真实数据库", tint: Color.feedbackSuccess)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var controlsSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: Spacing.tiny) {
                        Text("验证控制")
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textPrimary)
                        Text("切换编辑态、排序规则、列数和搜索过滤，观察拖拽是否按 Android 迁移边界启停。")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }

                    Spacer(minLength: Spacing.base)

                    Button {
                        withAnimation(reorderAnimation) {
                            viewModel.reset()
                        }
                    } label: {
                        Label("重置", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                Toggle(
                    "编辑模式",
                    isOn: Binding(
                        get: { viewModel.isEditMode },
                        set: { viewModel.isEditMode = $0 }
                    )
                )
                .font(AppTypography.body)

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("排序规则")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textSecondary)

                    Picker(
                        "排序规则",
                        selection: Binding(
                            get: { viewModel.sortMode },
                            set: { viewModel.sortMode = $0 }
                        )
                    ) {
                        ForEach(BookReorderSandboxTestViewModel.SortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("网格列数")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textSecondary)

                    Picker(
                        "网格列数",
                        selection: Binding(
                            get: { viewModel.columnCount },
                            set: { viewModel.columnCount = $0 }
                        )
                    ) {
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                    }
                    .pickerStyle(.segmented)
                }

                TextField(
                    "搜索书名、作者或分组",
                    text: Binding(
                        get: { viewModel.searchText },
                        set: { viewModel.searchText = $0 }
                    )
                )
                .font(AppTypography.body)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.tight)
                .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }

                if let reason = viewModel.dragDisabledReason {
                    disabledReasonRow(reason)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .lastTextBaseline) {
                Text("拖拽验证")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                Text("\(viewModel.displayedItems.count) 项")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }

            LazyVGrid(columns: gridColumns, spacing: Spacing.section) {
                ForEach(Array(viewModel.displayedItems.enumerated()), id: \.element.id) { index, item in
                    BookReorderSandboxItemCard(
                        item: item,
                        displayIndex: index + 1,
                        isDragged: viewModel.draggedItemID == item.id,
                        isTargeted: viewModel.dragTargetItemID == item.id && viewModel.draggedItemID != item.id,
                        isDragAvailable: viewModel.isDragAvailable,
                        coverColor: coverColor(for: item.coverTone),
                        groupCoverColors: item.groupCoverTones.map(coverColor(for:))
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: BookReorderSandboxFramePreferenceKey.self,
                                value: [item.id: proxy.frame(in: .named(Self.gridCoordinateSpace))]
                            )
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(reorderGesture(for: item))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel(for: item, index: index + 1))
                }
            }
            .coordinateSpace(name: Self.gridCoordinateSpace)
            .onPreferenceChange(BookReorderSandboxFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
        }
    }

    private var orderLogSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Label("顺序与提交日志", systemImage: "list.number")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                HStack(alignment: .top, spacing: Spacing.base) {
                    orderSummary
                    Divider()
                    logList
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var migrationNotesSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Label("Android / iOS 对照", systemImage: "arrow.left.arrow.right")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                factRow(
                    title: "Android",
                    content: "DefaultBookListFragment 使用 reorderable LazyVerticalGrid，拖拽结束后延迟调用 updateBookListOrder() 写入 book_order / group_order。"
                )
                factRow(
                    title: "iOS 建议",
                    content: "正式迁移时沿用 SwiftUI 网格原型的交互层，落盘收束到 Repository orderedIDs 写入；失败时回滚拖拽前快照。"
                )

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    ForEach(viewModel.migrationRiskSummary, id: \.self) { item in
                        HStack(alignment: .top, spacing: Spacing.cozy) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.feedbackSuccess)
                                .padding(.top, 2)
                            Text(item)
                                .font(AppTypography.subheadline)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var orderSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("当前手动顺序")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textSecondary)
            Text(viewModel.orderedSummary)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logList: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("模拟写入日志")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textSecondary)
            ForEach(viewModel.orderLog) { log in
                Text(log.message)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Spacing.base),
            count: viewModel.columnCount
        )
    }

    private var reorderAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .snappy
    }

    private func reorderGesture(for item: BookReorderSandboxTestViewModel.SandboxItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridCoordinateSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    viewModel.beginDrag(itemID: item.id)
                case .second(true, let drag):
                    guard let drag else { return }
                    withAnimation(reorderAnimation) {
                        viewModel.updateDrag(
                            itemID: item.id,
                            location: drag.location,
                            itemFrames: itemFrames
                        )
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                withAnimation(reorderAnimation) {
                    viewModel.endDrag(itemID: item.id)
                }
            }
    }

    private func disabledReasonRow(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppTypography.caption)
                .foregroundStyle(Color.feedbackWarning)
                .padding(.top, 2)

            Text(reason)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.feedbackWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
    }

    private func factRow(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.brand)
            Text(content)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(AppTypography.captionMedium)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func coverColor(for tone: Int) -> Color {
        let palette: [Color] = [
            Color.brand.opacity(0.32),
            Color.statusReading.opacity(0.28),
            Color.feedbackWarning.opacity(0.24),
            Color.statusDone.opacity(0.24),
            Color.statusOnHold.opacity(0.22),
            Color.statusWish.opacity(0.22),
            Color.readCalendarSelectionFill.opacity(0.36),
            Color.surfaceNested
        ]
        return palette[tone % palette.count]
    }

    private func accessibilityLabel(
        for item: BookReorderSandboxTestViewModel.SandboxItem,
        index: Int
    ) -> String {
        var parts = ["第 \(index) 项", item.kind.title, item.title]
        if item.isPinned {
            parts.append("置顶，不可拖拽")
        } else if viewModel.isDragAvailable {
            parts.append("可长按拖拽")
        } else {
            parts.append("当前不可拖拽")
        }
        return parts.joined(separator: "，")
    }
}

private struct BookReorderSandboxItemCard: View {
    let item: BookReorderSandboxTestViewModel.SandboxItem
    let displayIndex: Int
    let isDragged: Bool
    let isTargeted: Bool
    let isDragAvailable: Bool
    let coverColor: Color
    let groupCoverColors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            cover
            metadata
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: isTargeted ? 1.4 : CardStyle.borderWidth, dash: isTargeted ? [5, 4] : []))
        }
        .shadow(color: Color.black.opacity(isDragged ? 0.16 : 0.04), radius: isDragged ? 16 : 4, y: isDragged ? 8 : 2)
        .scaleEffect(isDragged ? 1.035 : 1)
        .opacity(opacity)
        .zIndex(isDragged ? 2 : 0)
    }

    @ViewBuilder
    private var cover: some View {
        switch item.kind {
        case .book:
            XMBookCover.responsive(
                urlString: item.coverURL,
                cornerRadius: CornerRadius.inlaySmall,
                border: XMBookCover.Border(color: Color.surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderBackground: coverColor,
                surfaceStyle: .spine
            )
            .overlay(alignment: .topLeading) {
                orderBadge
            }
            .overlay(alignment: .topTrailing) {
                pinBadge
            }
        case .group:
            groupCover
                .overlay(alignment: .topLeading) {
                    orderBadge
                }
                .overlay(alignment: .topTrailing) {
                    pinBadge
                }
        }
    }

    private var groupCover: some View {
        GeometryReader { proxy in
            let spacing = Spacing.compact
            let side = max(24, (proxy.size.width - spacing * 3) / 2)
            LazyVGrid(
                columns: [
                    GridItem(.fixed(side), spacing: spacing),
                    GridItem(.fixed(side), spacing: spacing)
                ],
                spacing: spacing
            ) {
                ForEach(Array(groupCoverColors.prefix(4).enumerated()), id: \.offset) { _, color in
                    XMBookCover.fixedWidth(
                        side,
                        urlString: "",
                        cornerRadius: CornerRadius.inlayTiny,
                        border: XMBookCover.Border(color: Color.surfaceBorderSubtle, width: CardStyle.borderWidth),
                        placeholderBackground: color,
                        placeholderIconSize: .hidden,
                        surfaceStyle: .plain
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(XMBookCover.aspectRatio, contentMode: .fit)
        .padding(Spacing.cozy)
        .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            HStack(spacing: Spacing.half) {
                Text(item.kind.title)
                    .font(AppTypography.caption2Medium)
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, Spacing.half)
                    .padding(.vertical, Spacing.tiny)
                    .background(Color.brand.opacity(0.10), in: Capsule())

                Text("\(item.noteCount)")
                    .font(AppTypography.caption2Medium)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Spacing.half)
                    .padding(.vertical, Spacing.tiny)
                    .background(Color.controlFillSecondary, in: Capsule())
            }

            Text(item.title)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(item.displaySubtitle)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var orderBadge: some View {
        Text("\(displayIndex)")
            .font(AppTypography.caption2Semibold)
            .foregroundStyle(Color.white)
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.tiny)
            .background(Color.black.opacity(0.68), in: Capsule())
            .padding(Spacing.compact)
    }

    @ViewBuilder
    private var pinBadge: some View {
        if item.isPinned {
            Image(systemName: "pin.fill")
                .font(AppTypography.caption2Semibold)
                .foregroundStyle(Color.white)
                .padding(Spacing.half)
                .background(Color.black.opacity(0.68), in: Circle())
                .padding(Spacing.compact)
        }
    }

    private var borderColor: Color {
        if isTargeted {
            return Color.brand
        }
        if item.isPinned {
            return Color.feedbackWarning.opacity(0.56)
        }
        if isDragAvailable {
            return Color.surfaceBorderSubtle
        }
        return Color.surfaceBorderSubtle.opacity(0.56)
    }

    private var opacity: Double {
        if isDragged {
            return 0.92
        }
        if item.isPinned || isDragAvailable {
            return 1
        }
        return 0.72
    }
}

private struct BookReorderSandboxFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]

    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

#Preview {
    NavigationStack {
        BookReorderSandboxTestView()
    }
}
#endif
