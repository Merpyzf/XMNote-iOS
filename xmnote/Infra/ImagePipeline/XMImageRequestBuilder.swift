import Foundation
import Nuke

/**
 * [INPUT]: 依赖 URL/URLRequest 与 Nuke ImageRequest，依赖业务防盗链规则（UA/Referer）
 * [OUTPUT]: 对外提供 XMImageRequestBuilder（统一图片请求构造）
 * [POS]: Infra 图片请求层，确保 UI 与 Data 的图片下载请求头、缓存策略与优先级一致
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

enum XMImageRequestBuilder {
    /// 图片加载优先级，映射到 Nuke 请求优先级。
    enum Priority {
        case low
        case normal
        case high

        var nukePriority: ImageRequest.Priority {
            switch self {
            case .low:
                return .low
            case .normal:
                return .normal
            case .high:
                return .high
            }
        }
    }

    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 规范化并校验图片 URL，过滤空串与非法地址。
    static func normalizedURL(from rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// 根据 URL 构建统一图片加载请求对象。
    static func makeImageRequest(
        url: URL,
        priority: Priority = .normal,
        timeout: TimeInterval = 12,
        cachePolicy: URLRequest.CachePolicy = .returnCacheDataElseLoad
    ) -> ImageRequest {
        let urlRequest = makeURLRequest(
            url: url,
            timeout: timeout,
            cachePolicy: cachePolicy
        )
        return ImageRequest(
            urlRequest: urlRequest,
            priority: priority.nukePriority
        )
    }

    /// 构建底层 URLRequest 并注入网络策略参数。
    static func makeURLRequest(
        url: URL,
        timeout: TimeInterval = 12,
        cachePolicy: URLRequest.CachePolicy = .returnCacheDataElseLoad
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = cachePolicy
        applyAntiHotlinkHeaders(to: &request)
        return request
    }

    /// 根据扩展名或查询参数判断 URL 是否指向 GIF 资源。
    static func isGIFURL(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "gif" {
            return true
        }
        let urlString = url.absoluteString.lowercased()
        return urlString.contains(".gif?")
    }

    /// 根据响应 MIME 类型判断返回资源是否 GIF。
    static func isGIFResponse(_ response: URLResponse?) -> Bool {
        guard let mimeType = response?.mimeType?.lowercased() else {
            return false
        }
        return mimeType == "image/gif" || mimeType.hasSuffix("/gif")
    }

    /// 通过文件头签名判断二进制数据是否 GIF。
    static func isGIFData(_ data: Data) -> Bool {
        guard data.count >= 6 else {
            return false
        }
        let signature = data.prefix(6)
        return signature.elementsEqual([0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) // GIF87a
            || signature.elementsEqual([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]) // GIF89a
    }

    /// 判断是否需要额外探测数据头，避免将 GIF 误判为静态图。
    static func shouldProbeGIFData(for url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else {
            return true
        }
        if ext == "gif" {
            return false
        }
        let nonGIFExtensions: Set<String> = [
            "jpg", "jpeg", "png", "webp", "heif", "heic", "avif",
            "bmp", "tif", "tiff", "svg"
        ]
        return !nonGIFExtensions.contains(ext)
    }

    /// 为请求注入 UA/Referer，兼容豆瓣等站点的防盗链策略。
    static func applyAntiHotlinkHeaders(to request: inout URLRequest) {
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let host = request.url?.host?.lowercased(), host.contains("douban") {
            request.setValue("https://douban.com/", forHTTPHeaderField: "Referer")
        }
    }
}
