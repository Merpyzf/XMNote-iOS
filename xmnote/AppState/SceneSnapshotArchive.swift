/**
 * [INPUT]: 依赖 Foundation 文件系统与 UISceneSession 的持久标识
 * [OUTPUT]: 对外提供按 scene 隔离的原子快照读写器 SceneSnapshotArchive
 * [POS]: AppState 模块的耐久恢复介质，在系统 SceneStorage 尚未落盘或前台异常终止时保留最后一次完整快照
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 按系统 scene 会话标识读写小型 JSON 快照；每次保存都使用同目录原子替换，避免留下半份导航状态。
struct SceneSnapshotArchive {
    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SceneSnapshots", isDirectory: true)
    }

    /// 读取指定 scene 最近一次完整快照；文件不存在表示该会话尚无耐久状态。
    func load(for sessionIdentifier: String) throws -> Data? {
        let url = snapshotURL(for: sessionIdentifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// 同步原子保存指定 scene 快照；数据体积受路由深度限制，写入完成后才返回给调用方。
    func save(_ data: Data, for sessionIdentifier: String) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: snapshotURL(for: sessionIdentifier), options: .atomic)
    }

    /// 将系统持久标识约束为单个安全文件名，避免任何路径分隔符进入恢复目录。
    private func snapshotURL(for sessionIdentifier: String) -> URL {
        let safeIdentifier = sessionIdentifier.replacingOccurrences(
            of: "[^A-Za-z0-9.-]",
            with: "_",
            options: .regularExpression
        )
        return rootDirectory.appendingPathComponent(
            "scene-\(safeIdentifier).json",
            isDirectory: false
        )
    }
}
