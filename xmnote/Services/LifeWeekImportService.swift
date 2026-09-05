/**
 * [INPUT]: 依赖三联中读公开 HTTPS 接口与手机号/密码
 * [OUTPUT]: 对仓储分别提供登录票据、全刊笔记抓取和统一 NoteImport Draft 转换
 * [POS]: Services 的三联生活周刊特殊导入边界，对齐 Android LifeWeekRepository
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated enum LifeWeekImportError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let value):
            value
        }
    }
}

/// 三联网络边界，将登录成功与笔记抓取分开，使仓储能在认证完成后保存凭证。
nonisolated struct LifeWeekImportService: Sendable {
    private let session: URLSession

    /// 默认使用不落盘的网络会话，也允许调用方注入明确的会话。
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else { let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 10; self.session = URLSession(configuration: configuration) }
    }

    /// 持有效票据抓取所有期刊笔记；非隔离异步执行，父任务取消沿 URLSession 请求链传播。
    func fetchBooks(ticket: String) async throws -> [NoteImportDraftBook] {
        let response: MagazineResponse = try await get("https://apis.lifeweek.com.cn/speedReding/note?ticket=\(Self.escaped(ticket))&pageNo=1&pageSize=2147483647&type=5")
        guard response.success, let magazines = response.model?.list else { throw LifeWeekImportError.message(response.resultMsg ?? "获取笔记失败") }
        var books: [NoteImportDraftBook] = []
        for magazine in magazines {
            try Task.checkCancellation()
            let notes: NoteResponse = try await get("https://apis.lifeweek.com.cn/user/myNotes/\(magazine.id)?ticket=\(Self.escaped(ticket))&currPage=1&pageSize=2147483647&type=5")
            guard notes.success, let groups = notes.model?.underlined.list else { throw LifeWeekImportError.message(notes.resultMsg ?? "获取笔记失败") }
            var book = NoteImportDraftBook()
            book.name = magazine.title; book.rawName = magazine.title; book.cover = magazine.pic; book.summary = magazine.subTitle
            book.author = "三联编辑部"; book.press = "生活·读书·新知三联书店"; book.type = 1; book.source = 22; book.positionUnit = 1; book.currentPositionUnit = 1
            for group in groups {
                for source in group.articleUnderlined {
                    book.notes.append(NoteImportDraftNote(content: source.underlinedContent, idea: source.contentComment, positionUnit: 1, isIncludeTime: false, chapter: NoteImportDraftChapter(title: group.title)))
                }
            }
            books.append(book)
        }
        return books
    }

    /// 非隔离异步验证凭证，仅在服务端成功并返回票据后完成；父任务取消传播到请求。
    func login(phoneNumber: String, password: String) async throws -> String {
        let response: LoginResponse = try await get("https://www.lifeweek.com.cn/api/login/login?phone=\(Self.escaped(phoneNumber))&countryCode=86&password=\(Self.escaped(password))")
        guard response.success, let ticket = response.model?.ticket, !ticket.isEmpty else { throw LifeWeekImportError.message(response.resultMsg ?? "登录失败") }
        return ticket
    }

    /// 非隔离异步读取三联响应，校验 HTTP 状态并保持网络取消语义。
    private func get<T: Decodable>(_ value: String) async throws -> T {
        guard let url = URL(string: value) else { throw LifeWeekImportError.message("请求地址无效") }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw LifeWeekImportError.message("网络请求失败") }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 保持三联既有接口参数编码方式。
    private nonisolated static func escaped(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value }
}

private extension LifeWeekImportService {
    nonisolated struct LoginResponse: Decodable { struct Model: Decodable { var ticket: String }; var model: Model?; var resultMsg: String?; var success: Bool }
    nonisolated struct MagazineResponse: Decodable { struct Model: Decodable { var list: [Magazine] }; var model: Model?; var resultMsg: String?; var success: Bool }
    nonisolated struct Magazine: Decodable { var id: Int; var pic: String; var subTitle: String; var title: String }
    nonisolated struct NoteResponse: Decodable { struct Model: Decodable { var underlined: Underlined }; struct Underlined: Decodable { var list: [Group] }; struct Group: Decodable { var title: String; var articleUnderlined: [UnderlinedNote] }; struct UnderlinedNote: Decodable { var contentComment: String; var underlinedContent: String }; var model: Model?; var resultMsg: String?; var success: Bool }
}
