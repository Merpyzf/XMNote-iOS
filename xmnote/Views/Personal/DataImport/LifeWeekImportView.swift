/**
 * [INPUT]: 依赖 NoteImportRepository、三联横幅、Reicon 图标、XMInlineInfoView、品牌表面前景与选择语义色、紧凑记住密码样式与导入主按钮
 * [OUTPUT]: 对外提供带显式记住密码和安全凭证恢复的三联中读导入页面
 * [POS]: Views/Personal/DataImport 的三联生活周刊特殊入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 保留简洁双行登录表单，页面只持有输入与任务状态，凭证读写统一交给仓储。
struct LifeWeekImportView: View {
    /// 输入域的唯一焦点顺序。
    private enum Field: Hashable {
        case phone
        case password
    }

    /// 本页品牌与附件的光学尺寸，不推广为跨页面令牌。
    private enum Layout {
        static let bannerWidth: CGFloat = 180
        static let passwordIconSize: CGFloat = 18
    }

    let repository: any NoteImportRepositoryProtocol
    @State private var phoneNumber = ""
    @State private var password = ""
    @State private var remembersPassword = true
    @State private var hasRestoredCredentials = false
    @State private var isSavingPreference = false
    @State private var storageMessage: String?
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var loadingText = ""
    @State private var books: [NoteImportDraftBook] = []
    @State private var opensPreview = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var preferenceTask: Task<Void, Never>?
    @State private var focusTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                Image(.lifeWeekBanner)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: Layout.bannerWidth)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            Section {
                loginFields
                    .disabled(!canEditCredentials)
            }
            Section {
                VStack(spacing: Spacing.section) {
                    rememberPasswordControl
                        .padding(.horizontal, Spacing.screenEdge)
                    importButton
                    XMInlineInfoView("点击开始导入后，将登录你的「三联中读」账户，获取笔记数据。")
                        .padding(.horizontal, Spacing.screenEdge)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listSectionSpacing(Spacing.double)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("三联生活周刊")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $opensPreview) {
            UnifiedNoteImportPreviewView(books: books, repository: repository)
        }
        .task { await restoreCredentials() }
        .onDisappear {
            focusedField = nil
            task?.cancel()
            focusTask?.cancel()
        }
        .xmSystemAlert(
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            descriptor: errorMessage.map { message in
                .init(
                    title: "导入失败",
                    message: message,
                    actions: [.init(title: "知道了") { errorMessage = nil }]
                )
            }
        )
    }

    private var canEditCredentials: Bool {
        hasRestoredCredentials && !isLoading && !isSavingPreference
    }

    @ViewBuilder
    private var loginFields: some View {
        TextField("请输入手机号", text: $phoneNumber)
            .keyboardType(.phonePad)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("手机号")
            .focused($focusedField, equals: .phone)
            .submitLabel(.next)
            .onSubmit { focusedField = .password }

        HStack(spacing: Spacing.cozy) {
            Group {
                if isPasswordVisible {
                    TextField("请输入密码", text: $password)
                } else {
                    SecureField("请输入密码", text: $password)
                }
            }
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("密码")
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            .onSubmit(beginImport)

            Button(action: togglePasswordVisibility) {
                Image(isPasswordVisible ? .reiconEyeOffOutline : .reiconEyeOutline)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Layout.passwordIconSize, height: Layout.passwordIconSize)
                    .foregroundStyle(Color.iconSecondary)
                    .xmMinimumHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPasswordVisible ? "隐藏密码" : "显示密码")
        }
    }

    private var rememberPasswordControl: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Toggle("记住密码", isOn: Binding(
                get: { remembersPassword },
                set: updateRemembersPassword
            ))
            .toggleStyle(LifeWeekRememberPasswordToggleStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!canEditCredentials)

            if let storageMessage {
                Text(storageMessage)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.feedbackError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var importButton: some View {
        Button(action: beginImport) {
            HStack(spacing: Spacing.cozy) {
                ProgressView()
                    .controlSize(.small)
                    .opacity(isLoading ? 1 : 0)
                    .accessibilityHidden(true)
                Text(isLoading ? "正在导入" : "开始导入")
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView()
                    .controlSize(.small)
                    .hidden()
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NoteImportPrimaryButtonStyle())
        .disabled(!canEditCredentials)
        .accessibilityValue(isLoading ? loadingText : "")
    }

    /// MainActor 恢复一次输入快照；恢复前冻结输入，结构化任务取消后不回写，返回上一级也不覆盖草稿。
    private func restoreCredentials() async {
        guard !hasRestoredCredentials else { return }
        let state = await repository.loadLifeWeekLoginState()
        guard !Task.isCancelled else { return }
        phoneNumber = state.phoneNumber
        password = state.password
        remembersPassword = state.remembersPassword
        storageMessage = state.storageMessage
        hasRestoredCredentials = true
    }

    /// MainActor 发起偏好提交；提交期间禁止并发操作，离场仍让短暂持久化完成，失败恢复可见开关。
    private func updateRemembersPassword(_ enabled: Bool) {
        guard canEditCredentials, enabled != remembersPassword else { return }
        let previousValue = remembersPassword
        remembersPassword = enabled
        isSavingPreference = true
        preferenceTask = Task { @MainActor in
            defer { isSavingPreference = false }
            do {
                try await repository.setLifeWeekRemembersPassword(enabled)
                storageMessage = nil
            } catch {
                remembersPassword = previousValue
                storageMessage = "未能更新记住密码设置，请重试。"
            }
        }
    }

    /// MainActor 提交单次导入；快照冻结凭证，离场取消和阶段检查阻止旧任务导航，失败保留输入。
    private func beginImport() {
        guard canEditCredentials else { return }
        guard !phoneNumber.isEmpty, !password.isEmpty else {
            errorMessage = "手机号和密码不能为空"
            return
        }
        focusedField = nil
        focusTask?.cancel()
        isLoading = true
        loadingText = "正在登录三联中读"
        let submittedPhoneNumber = phoneNumber
        let submittedPassword = password
        task = Task { @MainActor in
            defer { isLoading = false }
            do {
                let result = try await repository.fetchLifeWeekBooks(
                    phoneNumber: submittedPhoneNumber,
                    password: submittedPassword
                ) { message in
                    storageMessage = message
                    loadingText = "正在获取全部笔记"
                }
                try Task.checkCancellation()
                guard !result.isEmpty else { throw NoteImportParserError.noteNotFound }
                books = result
                opensPreview = true
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// MainActor 在字段替换后恢复焦点；取消上一请求并在离场取消，避免快速切换或退出后重新唤起键盘。
    private func togglePasswordVisibility() {
        let shouldRestoreFocus = focusedField == .password
        isPasswordVisible.toggle()
        focusTask?.cancel()
        guard shouldRestoreFocus else { return }
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedField = .password
        }
    }
}

/// 三联登录附属选项的轻量勾选表达，保留 Toggle 状态语义，不将系统 Switch 缩放成非标准控件。
private struct LifeWeekRememberPasswordToggleStyle: ToggleStyle {
    /// 图文在行内垂直居中，由实际行高承载点击区域，并保持品牌表面内容色与主操作一致。
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(AppTypography.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        configuration.isOn ? Color.onBrandForeground : Color.selectionInactive,
                        configuration.isOn ? Color.selectionAccent : Color.selectionInactive
                    )
                    .accessibilityHidden(true)
                configuration.label
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(configuration)
                .toggleStyle(.switch)
        }
    }
}
