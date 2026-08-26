#if DEBUG
/**
 * [INPUT]: 依赖 BookSelectionTestViewModel 提供业务映射与固定仓储替身，依赖 BookPickerView 承接统一书籍选择体验
 * [OUTPUT]: 对外提供 BookSelectionTestView，集中展示业务场景矩阵、系统搜索交互与选择结果预览
 * [POS]: Debug 模块书籍选择测试中心，用固定数据回归验证统一 BookPicker，不依赖真实书架和外部网络
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct BookSelectionTestView: View {
    @State private var viewModel = BookSelectionTestViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.double) {
                overviewSection

                if let bootstrapErrorMessage = viewModel.bootstrapErrorMessage {
                    bootstrapErrorSection(bootstrapErrorMessage)
                }

                ForEach(BookSelectionScenarioGroup.allCases) { group in
                    groupSection(group)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("书籍选择")
        .navigationBarTitleDisplayMode(.inline)
        .scrollBounceBehavior(.always)
        .sheet(
            item: presentedScenarioBinding,
            onDismiss: {
                viewModel.clearPresentedScenario()
            }
        ) { scenario in
            let repository = viewModel.fixtureRepository(for: scenario)
            BookPickerView(
                configuration: viewModel.configuration(for: scenario),
                bookRepository: repository,
                searchRepository: repository,
                onComplete: { result in
                    viewModel.record(result, for: scenario)
                }
            )
        }
    }

    private var overviewSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("这里同时保留 Android 业务映射，并用固定数据展示单选、多选、已选管理、书单去重与异常状态。")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.base) {
                    overviewBadge("\(viewModel.scenarioCount) 个场景")
                    overviewBadge("\(BookSelectionScenarioGroup.allCases.count) 组")
                    overviewBadge("\(viewModel.sampleLocalBooks.count) 本本地书")
                }

                Text(viewModel.localBookSummary)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func bootstrapErrorSection(_ message: String) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Label("本地书架样本读取失败", systemImage: "exclamationmark.triangle.fill")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.feedbackWarning)

                Text(message)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func groupSection(_ group: BookSelectionScenarioGroup) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text(group.subtitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(viewModel.scenarios(in: group)) { scenario in
                scenarioCard(scenario)
            }
        }
    }

    private func scenarioCard(_ scenario: BookSelectionTestScenario) -> some View {
        let preview = viewModel.preview(for: scenario)

        return CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scenario.title)
                            .font(AppTypography.body.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)

                        Text(scenario.androidEntry)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }

                    Spacer(minLength: Spacing.base)

                    Button("打开实现") {
                        viewModel.open(scenario)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appTint)
                }

                flowLayout(scenario.capabilityTags)

                infoBlock(title: "iOS 对应实现", content: scenario.configurationSpec.implementationDescription)

                if let runtimeHint = scenario.runtimeHint {
                    infoBlock(title: "场景说明", content: runtimeHint)
                }

                previewBlock(preview)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func infoBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)

            Text(content)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func previewBlock(_ preview: BookSelectionScenarioPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(preview.title)
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(Color.textSecondary)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(preview.message)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !preview.details.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        ForEach(preview.details, id: \.self) { line in
                            Text(line)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
            }
        }
    }

    private func overviewBadge(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.caption.weight(.medium))
            .foregroundStyle(Color.appTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.appTint.opacity(0.10), in: Capsule())
    }

    private func flowLayout(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.half) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(AppTypography.caption.weight(.medium))
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.controlFillSecondary, in: Capsule())
                }
            }
        }
        .scrollBounceBehavior(.always)
    }

    private var presentedScenarioBinding: Binding<BookSelectionTestScenario?> {
        Binding(
            get: { viewModel.presentedScenario },
            set: { viewModel.presentedScenario = $0 }
        )
    }
}

#Preview {
    NavigationStack {
        BookSelectionTestView()
    }
}
#endif
