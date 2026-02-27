/**
 * [INPUT]: 依赖 Alamofire HTTPMethod
 * [OUTPUT]: 对外提供 .propfind 与 .mkcol 两个 WebDAV HTTP 方法扩展
 * [POS]: Services 模块的 HTTP 方法扩展，被 WebDAVClient 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Alamofire

extension HTTPMethod {
    static let propfind = HTTPMethod(rawValue: "PROPFIND")
    static let mkcol = HTTPMethod(rawValue: "MKCOL")
}
