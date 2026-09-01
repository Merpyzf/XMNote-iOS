/**
 * [INPUT]: 依赖 NoteImportRepository、统一预览和 UserDefaults
 * [OUTPUT]: 对外提供三联中读账号登录与笔记导入页面
 * [POS]: Views/Personal/DataImport 的三联生活周刊特殊入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct LifeWeekImportView: View {
    private enum Field: Hashable {
        case phone
        case password
    }

    let repository: any NoteImportRepositoryProtocol
    @State private var phoneNumber = UserDefaults.standard.string(forKey: "lifeWeekPhoneNumber") ?? ""
    @State private var password = UserDefaults.standard.string(forKey: "lifeWeekPassword") ?? ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var loadingText = ""
    @State private var books: [NoteImportDraftBook] = []
    @State private var opensPreview = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                TextField("请输入手机号", text: $phoneNumber)
                    .keyboardType(.phonePad)
                    .focused($focusedField, equals: .phone)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                HStack {
                    Group {
                        if isPasswordVisible {
                            TextField("请输入密码", text: $password)
                        } else {
                            SecureField("请输入密码", text: $password)
                        }
                    }
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(beginImport)

                    Button(action: togglePasswordVisibility) {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Button { beginImport() } label: { HStack { Spacer(); if isLoading { ProgressView().controlSize(.small) }; Text(isLoading ? loadingText : "开始导入"); Spacer() } }.disabled(isLoading)
            }
            Section { Text("点击开始导入后，将会登录你的「三联中读」账户以获取笔记数据") .font(AppTypography.caption).foregroundStyle(Color.textSecondary) }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("三联生活周刊")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $opensPreview) { UnifiedNoteImportPreviewView(books: books, repository: repository) }
        .onDisappear {
            focusedField = nil
            task?.cancel()
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

    private func beginImport() {
        guard !phoneNumber.isEmpty, !password.isEmpty else { errorMessage = "手机号和密码不能为空"; return }
        focusedField = nil
        isLoading = true; loadingText = "正在登录三联中读，请稍候"
        task = Task {
            do {
                UserDefaults.standard.set(phoneNumber, forKey: "lifeWeekPhoneNumber"); UserDefaults.standard.set(password, forKey: "lifeWeekPassword")
                loadingText = "正在获取全部笔记，请稍候"
                let result = try await repository.fetchLifeWeekBooks(phoneNumber: phoneNumber, password: password)
                guard !result.isEmpty else { throw NoteImportParserError.noteNotFound }
                books = result; opensPreview = true
            } catch is CancellationError {
            } catch let error as LifeWeekImportError { errorMessage = error.localizedDescription }
            catch { errorMessage = "登录失败：\(error.localizedDescription)" }
            isLoading = false
        }
    }

    /// SecureField 与 TextField 互换后在下一轮布局恢复密码字段焦点，避免显隐切换打断输入。
    private func togglePasswordVisibility() {
        let shouldRestoreFocus = focusedField == .password
        isPasswordVisible.toggle()
        guard shouldRestoreFocus else { return }
        Task { @MainActor in
            await Task.yield()
            focusedField = .password
        }
    }
}
