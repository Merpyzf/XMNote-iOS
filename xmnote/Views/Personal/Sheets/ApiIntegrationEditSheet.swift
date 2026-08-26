/**
 * [INPUT]: 依赖 ExternalAppDestination、ApiIntegrationViewModel 与公共 Settings/Sheet 组件
 * [OUTPUT]: 对外提供 ApiIntegrationEditSheet，承载单个外部应用的配置编辑与清空/保存动作
 * [POS]: Views/Personal/Sheets 的 API 集成业务 Sheet；状态与持久化仍由 ApiIntegrationViewModel 持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 编辑单个外部应用配置，并把字段变更与持久化动作转发给页面 ViewModel。
struct ApiIntegrationEditSheet: View {
    static let compactHeight: CGFloat = 360

    let destination: ExternalAppDestination
    @Bindable var viewModel: ApiIntegrationViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "\(destination.presentationTitle) 配置",
            subtitle: destination.sheetSubtitle,
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                XMSettingsGroup {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        ApiIntegrationStatusLine(
                            destination: destination,
                            isConfigured: viewModel.settings.isConfigured(destination)
                        )

                        XMSettingsDivider()

                        ApiIntegrationInputField(
                            destination: destination,
                            value: binding(for: destination)
                        )

                        Text(destination.configurationHint)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let error = viewModel.fieldError(for: destination) {
                            Text(error)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.feedbackError)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }
                    }
                }

                actionBar
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .onAppear {
            viewModel.resetDraft(for: destination)
        }
        .onDisappear {
            viewModel.resetDraft(for: destination)
        }
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.base) {
            Button(role: .destructive) {
                if viewModel.clear(destination) {
                    dismiss()
                }
            } label: {
                Text("清空配置")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: InteractionMetrics.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canClear(destination))

            Button {
                if viewModel.save(destination) {
                    dismiss()
                }
            } label: {
                Text("保存")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: InteractionMetrics.minimumTouchTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.primaryActionFill)
            .disabled(!viewModel.canSave(destination))
        }
    }

    private func binding(for destination: ExternalAppDestination) -> Binding<String> {
        Binding {
            viewModel.draftSettings.value(for: destination)
        } set: { value in
            viewModel.updateDraft(value, for: destination)
        }
    }
}

/// 展示当前外部应用是否已经具备可用配置。
private struct ApiIntegrationStatusLine: View {
    let destination: ExternalAppDestination
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text("当前状态")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            Spacer(minLength: Spacing.base)

            Text(destination.statusTitle(isConfigured: isConfigured))
                .font(AppTypography.captionMedium)
                .foregroundStyle(isConfigured ? Color.feedbackSuccess : Color.textHint)
                .lineLimit(1)
        }
        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        .accessibilityElement(children: .combine)
    }
}

/// 根据目标应用的凭证类型提供普通或隐私输入控件。
private struct ApiIntegrationInputField: View {
    let destination: ExternalAppDestination
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(destination.configurationTitle)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            inputControl
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, Spacing.base)
                .frame(
                    maxWidth: .infinity,
                    minHeight: XMSettingsPageLayout.inputMinHeight,
                    alignment: .leading
                )
                .background(
                    Color.surfaceNested,
                    in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var inputControl: some View {
        if destination == .writeathon {
            SecureField(destination.configurationTitle, text: $value)
                .privacySensitive()
        } else {
            TextField(destination.configurationTitle, text: $value, axis: .vertical)
                .keyboardType(.URL)
                .lineLimit(1...3)
        }
    }
}
