import Foundation
import Nuke

/**
 * [INPUT]: 依赖 Nuke 的 ImagePipeline/DataLoader/DataCache，依赖 URLSessionConfiguration 统一网络缓存策略
 * [OUTPUT]: 对外提供 XMImagePipelineFactory（应用级图片管线工厂）
 * [POS]: Infra 图片基础设施，集中管理图片请求超时、缓存与并发策略，供 UI 展示与取色下载共用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 应用级图片管线工厂，统一网络、缓存与解码配置。
enum XMImagePipelineFactory {
    private static let diskCacheName = "com.merpyzf.xmnote.image.datacache.v1"
    private static let diskCacheSizeLimit = 220 * 1024 * 1024

    /// 构建默认图片加载管线实例。
    static func makeDefault() -> ImagePipeline {
        ImagePipeline(configuration: makeConfiguration())
    }

    /// 构建图片加载管线配置（缓存、解码、并发策略）。
    static func makeConfiguration() -> ImagePipeline.Configuration {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 12
        sessionConfiguration.timeoutIntervalForResource = 16
        sessionConfiguration.requestCachePolicy = .returnCacheDataElseLoad
        sessionConfiguration.urlCache = URLCache.shared

        let dataLoader = DataLoader(configuration: sessionConfiguration)

        var configuration = ImagePipeline.Configuration(dataLoader: dataLoader)
        configuration.imageCache = ImageCache.shared
        configuration.dataCachePolicy = .storeOriginalData
        configuration.isTaskCoalescingEnabled = true
        configuration.isRateLimiterEnabled = true
        configuration.isResumableDataEnabled = true
        configuration.isProgressiveDecodingEnabled = false
        configuration.isStoringPreviewsInMemoryCache = false

        if let dataCache = try? DataCache(name: diskCacheName) {
            dataCache.sizeLimit = diskCacheSizeLimit
            configuration.dataCache = dataCache
        }

        return configuration
    }
}
