import Foundation

/**
 * [INPUT]: 依赖 Foundation 的 Date/DateFormatter 进行时间格式化
 * [OUTPUT]: 对外提供 BookItem、BookDetail、NoteExcerpt 三个书籍域展示模型
 * [POS]: Domain/Models 的书籍聚合模型定义，被 BookViewModel 与 BookRepository 实现共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct BookItem: Identifiable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let readStatusId: Int64
    let noteCount: Int
    let pinned: Bool
}

struct BookDetail: Identifiable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let press: String
    let noteCount: Int
    let readStatusName: String
}

struct NoteExcerpt: Identifiable {
    let id: Int64
    let content: String
    let idea: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64

    var footerText: String {
        var parts: [String] = []
        if !position.isEmpty {
            let unit = switch positionUnit {
            case 1: "位置"
            case 2: "%"
            default: "页"
            }
            parts.append(positionUnit == 2 ? "\(position)\(unit)" : "第\(position)\(unit)")
        }
        if includeTime, createdDate > 0 {
            parts.append(Self.formatDate(createdDate))
        }
        return parts.joined(separator: " | ")
    }

    private static func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}
