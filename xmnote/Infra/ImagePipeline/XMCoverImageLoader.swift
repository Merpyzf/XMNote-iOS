import Foundation
import UIKit
import Nuke

/**
 * [INPUT]: 依赖 Nuke ImagePipeline 与统一请求构造器 XMImageRequestBuilder
 * [OUTPUT]: 对外提供 XMCoverImageLoading 协议、XMImageLoadRequest 输入模型与 NukeCoverImageLoader 默认实现
 * [POS]: Infra 图片下载抽象层，供取色仓储与其它非 UI 场景复用同一下载与缓存管线
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct XMImageLoadRequest {
    let url: URL
    let priority: XMImageRequestBuilder.Priority
    let timeout: TimeInterval
    let cachePolicy: URLRequest.CachePolicy

    /// 组装封面加载请求参数，统一超时、优先级与缓存策略。
    init(
        url: URL,
        priority: XMImageRequestBuilder.Priority = .normal,
        timeout: TimeInterval = 12,
        cachePolicy: URLRequest.CachePolicy = .returnCacheDataElseLoad
    ) {
        self.url = url
        self.priority = priority
        self.timeout = timeout
        self.cachePolicy = cachePolicy
    }

    var imageRequest: ImageRequest {
        XMImageRequestBuilder.makeImageRequest(
            url: url,
            priority: priority,
            timeout: timeout,
            cachePolicy: cachePolicy
        )
    }
}

/// XMCoverImageLoading 约束图片加载链路下的协作契约，明确调用方与实现方边界。
protocol XMCoverImageLoading {
    /// 下载并解码图片，供取色与封面渲染等场景直接消费 UIImage。
    func loadImage(for request: XMImageLoadRequest) async throws -> UIImage
    /// 下载原始二进制数据，供 GIF 探测或自定义解析链路使用。
    func loadData(for request: XMImageLoadRequest) async throws -> Data
}

/// 默认图片加载实现，复用 Nuke 管线统一处理缓存与并发请求。
struct NukeCoverImageLoader: XMCoverImageLoading {
    private let pipeline: ImagePipeline

    /// 注入图片管线，允许在测试或特定模块替换 pipeline。
    init(pipeline: ImagePipeline = .shared) {
        self.pipeline = pipeline
    }

    /// 通过 Nuke 加载并返回解码后的 UIImage。
    func loadImage(for request: XMImageLoadRequest) async throws -> UIImage {
        try await pipeline.image(for: request.imageRequest)
    }

    /// 通过 Nuke 下载原始二进制数据。
    func loadData(for request: XMImageLoadRequest) async throws -> Data {
        let (data, _) = try await pipeline.data(for: request.imageRequest)
        return data
    }
}
