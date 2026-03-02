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

protocol XMCoverImageLoading {
    func loadImage(for request: XMImageLoadRequest) async throws -> UIImage
    func loadData(for request: XMImageLoadRequest) async throws -> Data
}

struct NukeCoverImageLoader: XMCoverImageLoading {
    private let pipeline: ImagePipeline

    init(pipeline: ImagePipeline = .shared) {
        self.pipeline = pipeline
    }

    func loadImage(for request: XMImageLoadRequest) async throws -> UIImage {
        try await pipeline.image(for: request.imageRequest)
    }

    func loadData(for request: XMImageLoadRequest) async throws -> Data {
        let (data, _) = try await pipeline.data(for: request.imageRequest)
        return data
    }
}
