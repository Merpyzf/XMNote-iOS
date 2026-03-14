/**
 * [INPUT]: 依赖 Foundation、UIKit 与 Objective-C Runtime，在不静态链接百度 SDK 的前提下提供动态调用入口
 * [OUTPUT]: 对外提供 XMBaiduOCRRuntimeInvoker，负责加载嵌入 framework、鉴权与触发 OCR 识别
 * [POS]: Infra/BaiduOCR 的 Objective-C 动态调用桥，隔离 device-only framework 与 Swift 主工程的链接关系
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C Runtime 调用桥，避免主 target 在模拟器构建时直接链接百度 OCR framework。
@interface XMBaiduOCRRuntimeInvoker : NSObject

/// 加载嵌入到 App Frameworks 目录下的百度 OCR framework。
+ (BOOL)loadEmbeddedFrameworksAndReturnError:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(loadEmbeddedFrameworks());

/// 清理 SDK 的鉴权缓存，供 Debug 页面切换 AK/SK 或恢复异常链路时使用。
+ (void)clearCache;

/// 使用 AK / SK 配置 SDK 鉴权信息。
+ (BOOL)authenticateWithAPIKey:(NSString *)apiKey
                     secretKey:(NSString *)secretKey
                         error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(authenticate(apiKey:secretKey:));

/// 对裁切后的图片执行通用文字识别。
+ (void)recognizeTextFromImage:(UIImage *)image
                 highPrecision:(BOOL)highPrecision
                       options:(NSDictionary<NSString *, NSString *> *)options
                       success:(void (^)(NSDictionary<NSString *, id> *result))success
                       failure:(void (^)(NSError *error))failure
    NS_SWIFT_NAME(recognizeText(from:highPrecision:options:success:failure:));

@end

NS_ASSUME_NONNULL_END
