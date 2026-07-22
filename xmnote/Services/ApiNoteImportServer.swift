/**
 * [INPUT]: 依赖 Hummingbird 2.22.0、ApiNoteImportDTO 与会话回调
 * [OUTPUT]: 对外提供 8080 `/send` 本地服务、CORS、访问码和可取消生命周期
 * [POS]: Services 的 API 导入 HTTP 边界；页面显式启动，离开或进入后台时停止
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird
import HTTPTypes

actor ApiNoteImportServer {
    typealias BookHandler = @Sendable (ApiImportBookPayload) async -> Void
    typealias StateHandler = @Sendable (State) async -> Void

    enum State: Sendable, Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private var task: Task<Void, Never>?
    private(set) var state: State = .stopped

    func start(
        port: Int = 8080,
        accessCode: String,
        isPremium: Bool,
        onBook: @escaping BookHandler,
        onState: @escaping StateHandler
    ) async {
        guard task == nil else { return }
        state = .starting
        await onState(.starting)

        let router = Router()
        router.add(middleware: CORSMiddleware(allowOrigin: .all, allowHeaders: [.accept, .authorization, .contentType, .origin, .xmnoteAccessCode]))
        router.post("/send") { request, _ -> String in
            func message(_ code: Int, _ text: String) -> String {
                let data = try? JSONSerialization.data(withJSONObject: ["code": code, "message": text], options: [.sortedKeys])
                return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"code\":500,\"message\":\"\"}"
            }
            guard isPremium else { return message(500, "该功能仅限会员使用。") }
            if !accessCode.isEmpty, request.headers[.xmnoteAccessCode] != accessCode {
                return message(500, "访问码不正确。")
            }
            do {
                let buffer = try await request.body.collect(upTo: 10 * 1_024 * 1_024)
                let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
                let dto = try JSONDecoder().decode(ApiNoteImportDTO.self, from: Data(bytes))
                let payload = try dto.validatedPayload()
                await onBook(payload)
                return message(200, "success")
            } catch {
                return message(500, error.localizedDescription)
            }
        }

        let configuration = ApplicationConfiguration(
            address: .hostname("0.0.0.0", port: port),
            serverName: "XMNote",
            reuseAddress: false
        )
        let app = Application(router: router, configuration: configuration) { _ in
            await onState(.running)
        }
        task = Task { [weak self] in
            do {
                try await app.run()
                await self?.finished(onState: onState)
            } catch is CancellationError {
                await self?.finished(onState: onState)
            } catch {
                await self?.failed(error, onState: onState)
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        state = .stopped
    }

    private func finished(onState: StateHandler) async {
        task = nil
        state = .stopped
        await onState(.stopped)
    }

    private func failed(_ error: Error, onState: StateHandler) async {
        task = nil
        let value: State = .failed(Self.readableServerError(error))
        state = value
        await onState(value)
    }

    nonisolated private static func readableServerError(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("address already in use") || message.contains("48") {
            return "端口 8080 已被占用，请关闭占用服务后重试"
        }
        return "服务启动失败：\(message)"
    }
}

private extension HTTPField.Name {
    nonisolated static let xmnoteAccessCode = Self("X-XMNote-Access-Code")!
}
