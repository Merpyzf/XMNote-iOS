/**
 * [INPUT]: 依赖 XMBaiduOCRRuntimeInvoker.h、Objective-C Runtime 与主 Bundle 的私有 Frameworks 目录
 * [OUTPUT]: 对外提供百度 OCR framework 的动态加载与 selector 调度实现
 * [POS]: Infra/BaiduOCR 的 Objective-C 实现文件，负责规避 Swift 侧对 device-only framework 的直接链接
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

#import "XMBaiduOCRRuntimeInvoker.h"

#import <objc/message.h>

static NSString * const XMBaiduOCRRuntimeErrorDomain = @"com.merpyzf.xmnote.baidu-ocr.runtime";

typedef id _Nullable (*XMClassMessageNoArgs)(Class, SEL);
typedef void (*XMObjectMessageNoArgs)(id, SEL);
typedef void (*XMObjectMessageTwoObjects)(id, SEL, id, id);
typedef void (*XMObjectRecognizeMessage)(id, SEL, UIImage *, NSDictionary *, void (^)(id), void (^)(NSError *));

@implementation XMBaiduOCRRuntimeInvoker

+ (NSArray<NSString *> *)frameworkNames {
    return @[
        @"AipBase.framework",
        @"IdcardQuality.framework",
        @"AipOcrSdk.framework",
    ];
}

+ (NSError *)runtimeErrorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:XMBaiduOCRRuntimeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (BOOL)loadEmbeddedFrameworksAndReturnError:(NSError * _Nullable __autoreleasing *)error {
    NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
    if (frameworksPath.length == 0) {
        if (error != NULL) {
            *error = [self runtimeErrorWithCode:1001 message:@"未找到 App 的 Frameworks 目录，请确认 Debug 构建已嵌入百度 OCR SDK。"];
        }
        return NO;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *frameworkName in self.frameworkNames) {
        NSString *frameworkPath = [frameworksPath stringByAppendingPathComponent:frameworkName];
        if (![fileManager fileExistsAtPath:frameworkPath]) {
            if (error != NULL) {
                NSString *message = [NSString stringWithFormat:@"未找到 %@，请确认 Debug 构建阶段已复制百度 OCR framework。", frameworkName];
                *error = [self runtimeErrorWithCode:1002 message:message];
            }
            return NO;
        }

        NSBundle *bundle = [NSBundle bundleWithPath:frameworkPath];
        if (bundle == nil) {
            if (error != NULL) {
                NSString *message = [NSString stringWithFormat:@"无法创建 %@ 的 bundle 对象。", frameworkName];
                *error = [self runtimeErrorWithCode:1003 message:message];
            }
            return NO;
        }

        if (!bundle.isLoaded) {
            NSError *loadError = nil;
            if (![bundle loadAndReturnError:&loadError]) {
                if (error != NULL) {
                    *error = loadError ?: [self runtimeErrorWithCode:1004 message:[NSString stringWithFormat:@"%@ 加载失败。", frameworkName]];
                }
                return NO;
            }
        }
    }

    if (NSClassFromString(@"AipOcrService") == Nil) {
        if (error != NULL) {
            *error = [self runtimeErrorWithCode:1005 message:@"百度 OCR 主服务类未注册，framework 可能未被正确加载。"];
        }
        return NO;
    }

    return YES;
}

+ (id)serviceInstanceAndReturnError:(NSError * _Nullable __autoreleasing *)error {
    NSError *loadError = nil;
    if (![self loadEmbeddedFrameworksAndReturnError:&loadError]) {
        if (error != NULL) {
            *error = loadError;
        }
        return nil;
    }

    Class serviceClass = NSClassFromString(@"AipOcrService");
    SEL sharedSelector = NSSelectorFromString(@"shardService");
    if (![serviceClass respondsToSelector:sharedSelector]) {
        if (error != NULL) {
            *error = [self runtimeErrorWithCode:1006 message:@"百度 OCR framework 缺少 shardService 单例入口。"];
        }
        return nil;
    }

    XMClassMessageNoArgs sendMessage = (XMClassMessageNoArgs)objc_msgSend;
    id service = sendMessage(serviceClass, sharedSelector);
    if (service == nil) {
        if (error != NULL) {
            *error = [self runtimeErrorWithCode:1007 message:@"百度 OCR 单例初始化失败。"];
        }
        return nil;
    }
    return service;
}

+ (void)clearCache {
    NSError *error = nil;
    id service = [self serviceInstanceAndReturnError:&error];
    if (service == nil) {
        return;
    }

    SEL clearSelector = NSSelectorFromString(@"clearCache");
    if ([service respondsToSelector:clearSelector]) {
        XMObjectMessageNoArgs sendMessage = (XMObjectMessageNoArgs)objc_msgSend;
        sendMessage(service, clearSelector);
    }
}

+ (BOOL)authenticateWithAPIKey:(NSString *)apiKey
                     secretKey:(NSString *)secretKey
                         error:(NSError * _Nullable __autoreleasing *)error {
    id service = [self serviceInstanceAndReturnError:error];
    if (service == nil) {
        return NO;
    }

    SEL authSelector = NSSelectorFromString(@"authWithAK:andSK:");
    if (![service respondsToSelector:authSelector]) {
        if (error != NULL) {
            *error = [self runtimeErrorWithCode:1008 message:@"百度 OCR framework 缺少 authWithAK:andSK: 鉴权入口。"];
        }
        return NO;
    }

    XMObjectMessageTwoObjects sendMessage = (XMObjectMessageTwoObjects)objc_msgSend;
    sendMessage(service, authSelector, apiKey, secretKey);
    return YES;
}

+ (void)recognizeTextFromImage:(UIImage *)image
                 highPrecision:(BOOL)highPrecision
                       options:(NSDictionary<NSString *,NSString *> *)options
                       success:(void (^)(NSDictionary<NSString *,id> *))success
                       failure:(void (^)(NSError *))failure {
    NSError *error = nil;
    id service = [self serviceInstanceAndReturnError:&error];
    if (service == nil) {
        failure(error ?: [self runtimeErrorWithCode:1009 message:@"百度 OCR 服务不可用。"]);
        return;
    }

    SEL selector = highPrecision
        ? NSSelectorFromString(@"detectTextAccurateBasicFromImage:withOptions:successHandler:failHandler:")
        : NSSelectorFromString(@"detectTextBasicFromImage:withOptions:successHandler:failHandler:");
    if (![service respondsToSelector:selector]) {
        NSString *message = highPrecision
            ? @"当前 SDK 不支持高精度通用文字识别入口。"
            : @"当前 SDK 不支持通用文字识别入口。";
        failure([self runtimeErrorWithCode:1010 message:message]);
        return;
    }

    XMObjectRecognizeMessage sendMessage = (XMObjectRecognizeMessage)objc_msgSend;
    sendMessage(
        service,
        selector,
        image,
        options ?: @{},
        ^(id result) {
            if ([result isKindOfClass:[NSDictionary class]]) {
                success((NSDictionary<NSString *, id> *)result);
            } else {
                failure([self runtimeErrorWithCode:1011 message:@"百度 OCR 返回了无法解析的响应结构。"]);
            }
        },
        ^(NSError *sdkError) {
            failure(sdkError ?: [self runtimeErrorWithCode:1012 message:@"百度 OCR 返回了未知错误。"]);
        }
    );
}

@end
