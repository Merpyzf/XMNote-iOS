import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 ReadingTimerSupplementViewModel 驱动补录表单，依赖 ReadingTimerSupplementMode 提供日期/精确时间两种产品模式
 * [OUTPUT]: 对外提供 ReadingTimerSupplementView（补录阅读页面，覆盖日期时长、精确起止、位置、感悟与读完状态）
 * [POS]: Reading 模块阅读补录任务页，由书籍详情的“补录阅读”入口进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读补录页面，默认使用“日期 + 时长”的轻量补录路径，并保留精确开始/结束时间模式。
struct ReadingTimerSupplementView: View {
    let bookId: Int64

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ReadingTimerSupplementViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var shouldPresentLongDurationConfirmation = false

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if let viewModel {
                supplementForm(viewModel)
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在准备补录阅读…", style: .card)
            }
        }
        .navigationTitle("补录阅读")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let supplementViewModel = ReadingTimerSupplementViewModel(repository: repositories.readingTimerRepository)
            viewModel = supplementViewModel
            bootstrapLoadingGate.update(intent: .none)
            await supplementViewModel.load(bookId: bookId)
        }
        .onChange(of: viewModel?.didSave) { _, didSave in
            guard didSave == true else { return }
            dismiss()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
        .xmSystemAlert(
            isPresented: $shouldPresentLongDurationConfirmation,
            descriptor: longDurationDescriptor
        )
    }

    @ViewBuilder
    private func supplementForm(_ viewModel: ReadingTimerSupplementViewModel) -> some View {
        Form {
            if let book = viewModel.bookContext {
                Section {
                    HStack(spacing: Spacing.base) {
                        XMBookCover.fixedWidth(
                            52,
                            urlString: book.coverURL,
                            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                            surfaceStyle: .spine
                        )

                        VStack(alignment: .leading, spacing: Spacing.micro) {
                            Text(book.name)
                                .font(AppTypography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)

                            if !book.author.isEmpty {
                                Text(book.author)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.micro)
                }
            }

            Section {
                Picker("记录方式", selection: Binding(
                    get: { viewModel.mode },
                    set: { viewModel.mode = $0 }
                )) {
                    ForEach(ReadingTimerSupplementMode.allSupplementModes, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch viewModel.mode {
            case .dateDuration:
                Section("按日期记录") {
                    DatePicker(
                        "阅读日期",
                        selection: Binding(get: { viewModel.readDate }, set: { viewModel.readDate = $0 }),
                        in: ...Date(),
                        displayedComponents: [.date]
                    )

                    HStack(spacing: Spacing.base) {
                        TextField("小时", text: Binding(get: { viewModel.hoursText }, set: { viewModel.hoursText = $0 }))
                            .keyboardType(.numberPad)
                        Text("小时")
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textSecondary)
                        TextField("分钟", text: Binding(get: { viewModel.minutesText }, set: { viewModel.minutesText = $0 }))
                            .keyboardType(.numberPad)
                        Text("分钟")
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            case .timeRange:
                Section("按开始结束记录") {
                    DatePicker(
                        "开始时间",
                        selection: Binding(get: { viewModel.startAt }, set: { viewModel.startAt = $0 }),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "结束时间",
                        selection: Binding(get: { viewModel.endAt }, set: { viewModel.endAt = $0 }),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }

            Section("阅读位置") {
                TextField(positionPlaceholder(for: viewModel.bookContext), text: Binding(
                    get: { viewModel.positionText },
                    set: { viewModel.positionText = $0 }
                ))
                .keyboardType(positionKeyboardType(for: viewModel.bookContext))
            }

            Section("本次感悟") {
                insightEditor(viewModel)
            }

            Section {
                Toggle("标记为读完", isOn: Binding(
                    get: { viewModel.markReadDone },
                    set: { viewModel.markReadDone = $0 }
                ))
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.feedbackError)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            supplementSaveBar(viewModel)
        }
    }

    private var longDurationDescriptor: XMSystemAlertDescriptor? {
        guard let viewModel else { return nil }
        return XMSystemAlertDescriptor(
            title: "确认保存长时长记录",
            message: "这次阅读记录为 \(ReadDurationFormatter.format(seconds: viewModel.durationSeconds))，是否保存？",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "保存") {
                    Task { await viewModel.save() }
                }
            ]
        )
    }

    private func positionPlaceholder(for book: ReadingTimerBookContext?) -> String {
        guard let book else { return "输入阅读位置" }
        switch book.resolvedPositionUnit {
        case .progress:
            return "输入 0 - 100"
        case .position:
            return "输入位置"
        case .pagination:
            return "输入页码"
        }
    }

    private func positionKeyboardType(for book: ReadingTimerBookContext?) -> UIKeyboardType {
        guard let book else { return .decimalPad }
        return book.resolvedPositionUnit == .progress ? .decimalPad : .numberPad
    }

    private func supplementSaveBar(_ viewModel: ReadingTimerSupplementViewModel) -> some View {
        VStack(spacing: 0) {
            Divider()

            Button {
                if viewModel.needsLongDurationConfirmation {
                    shouldPresentLongDurationConfirmation = true
                } else {
                    Task { await viewModel.save() }
                }
            } label: {
                HStack(spacing: Spacing.tiny) {
                    Spacer(minLength: 0)
                    if viewModel.isSaving {
                        LoadingStateView(style: .inline)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                            .font(AppTypography.bodyMedium)
                        Text("保存记录")
                            .font(AppTypography.bodyMedium)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .disabled(viewModel.isSaving || viewModel.isLoading)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.compact)
        }
        .background(.regularMaterial)
    }

    private func insightEditor(_ viewModel: ReadingTimerSupplementViewModel) -> some View {
        ZStack(alignment: .topLeading) {
            if viewModel.insight.isEmpty {
                Text("补充这次阅读后的想法")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textHint)
                    .padding(.horizontal, Spacing.micro)
                    .padding(.vertical, Spacing.tiny)
                    .allowsHitTesting(false)
            }

            TextEditor(text: Binding(
                get: { viewModel.insight },
                set: { viewModel.insight = $0 }
            ))
            .font(AppTypography.body)
            .frame(minHeight: 96)
            .scrollContentBackground(.hidden)
        }
    }
}

private extension ReadingTimerSupplementMode {
    static var allSupplementModes: [ReadingTimerSupplementMode] {
        [.dateDuration, .timeRange]
    }

    var title: String {
        switch self {
        case .dateDuration:
            return "按日期记录"
        case .timeRange:
            return "按开始结束记录"
        }
    }
}
