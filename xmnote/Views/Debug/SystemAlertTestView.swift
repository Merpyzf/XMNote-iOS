#if DEBUG
/**
 * [INPUT]: 依赖 SystemAlertTestViewModel 与 XMSystemAlert 基础设施，集中验证系统型中心弹窗的消息与轻输入能力
 * [OUTPUT]: 对外提供 SystemAlertTestView，承接 XMSystemAlert 的可视化测试与日志验证
 * [POS]: Debug 模块系统中心弹窗测试页，用于验收统一 descriptor + SwiftUI/item 驱动链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct SystemAlertTestView: View {
    @State private var viewModel = SystemAlertTestViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                overviewSection
                scenariosSection
                logSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("System Alert 测试")
        .navigationBarTitleDisplayMode(.inline)
        .xmSystemAlert(
            isPresented: $viewModel.isSystemAlertPresented,
            descriptor: descriptor(for: viewModel.currentScenario)
        )
        .xmSystemAlert(item: $viewModel.presentedItem) { item in
            descriptor(for: item.scenario)
        }
        .onChange(of: viewModel.isSystemAlertPresented) { _, isPresented in
            guard !isPresented else { return }
            viewModel.recordDismissal(for: viewModel.currentScenario)
        }
        .onChange(of: viewModel.presentedItem?.id) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                viewModel.recordDismissal(for: .itemDriven)
            }
        }
    }

    private var overviewSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("这里验证项目统一的 XMSystemAlert 基础设施。覆盖消息提示、警告动作、item 驱动和轻输入。")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.base) {
                    badge("UIKit Alert")
                    badge("SwiftUI Bridge")
                    badge("Item + Input")
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var scenariosSection: some View {
        CardContainer {
            VStack(spacing: 0) {
                ForEach(Array(SystemAlertScenario.allCases.enumerated()), id: \.element.id) { index, scenario in
                    scenarioRow(for: scenario)

                    if index != SystemAlertScenario.allCases.count - 1 {
                        Divider()
                            .padding(.leading, Spacing.contentEdge)
                    }
                }
            }
        }
    }

    private var logSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("事件日志")
                    .font(AppTypography.subheadline.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)

                if viewModel.eventLog.isEmpty {
                    Text("暂无事件，点击上面的用例开始验证。")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(Array(viewModel.eventLog.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func scenarioRow(for scenario: SystemAlertScenario) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 4) {
                Text(scenario.title)
                    .font(AppTypography.body.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)

                Text(scenario.subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.base)

            Button("运行") {
                viewModel.present(scenario)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
        }
        .padding(Spacing.contentEdge)
    }

    private func descriptor(for scenario: SystemAlertScenario) -> XMSystemAlertDescriptor {
        switch scenario {
        case .singleAction:
            return XMSystemAlertDescriptor(
                title: "提示",
                message: "这是一条基础的系统中心提示，用来验证默认按钮颜色。",
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) {
                        viewModel.secondaryActionTapped(for: scenario)
                    }
                ]
            )
        case .decision:
            return XMSystemAlertDescriptor(
                title: "同步书籍信息",
                message: "检测到需要登录后才能继续同步，是否现在前往登录？",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) {
                        viewModel.secondaryActionTapped(for: scenario)
                    },
                    XMSystemAlertAction(title: "去登录") {
                        viewModel.primaryActionTapped(for: scenario)
                    }
                ]
            )
        case .destructive:
            return XMSystemAlertDescriptor(
                title: "提示",
                message: "当前操作会清理未保存内容，是否继续？",
                actions: [
                    XMSystemAlertAction(title: "继续编辑") {
                        viewModel.secondaryActionTapped(for: scenario)
                    },
                    XMSystemAlertAction(title: "离开", role: .destructive) {
                        viewModel.destructiveActionTapped(for: scenario)
                    }
                ]
            )
        case .longMessage:
            return XMSystemAlertDescriptor(
                title: "长文案验证",
                message: "这是一段较长的说明文案，用来观察系统 Alert 在多行正文下的排版、换行和按钮留白是否仍然稳定自然。后续如果业务里出现较长提示，也应该走这一条基础设施，而不是再发明新的中心弹窗实现。",
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) {
                        viewModel.secondaryActionTapped(for: scenario)
                    }
                ]
            )
        case .textField:
            return XMSystemAlertDescriptor(
                title: "添加链接",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) {
                        viewModel.secondaryActionTapped(for: scenario)
                    },
                    XMSystemAlertAction(title: "确定") {
                        viewModel.primaryActionTapped(for: scenario)
                    }
                ],
                textFields: [
                    XMSystemAlertTextField(
                        text: $viewModel.inputText,
                        placeholder: "https://example.com",
                        keyboardType: .URL,
                        textInputAutocapitalization: .none,
                        autocorrectionDisabled: true
                    )
                ]
            )
        case .itemDriven:
            return XMSystemAlertDescriptor(
                title: "Item 驱动提示",
                message: "这个场景验证 presentation model 置空后，系统中心弹窗会跟着关闭。",
                actions: [
                    XMSystemAlertAction(title: "关闭", role: .cancel) {
                        viewModel.secondaryActionTapped(for: scenario)
                    }
                ]
            )
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.caption.weight(.medium))
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.brand.opacity(0.10), in: Capsule())
    }
}

#Preview {
    NavigationStack {
        SystemAlertTestView()
    }
}
#endif
