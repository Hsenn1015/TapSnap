#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Used only in Sparkle's downloader session, for requests with a discovered PAC and a manual loopback proxy.
@interface TSUpdateURLProtocol : NSURLProtocol
+ (NSURLRequest *)prepareRequest:(NSURLRequest *)request
                   configuration:(NSURLSessionConfiguration *)configuration
                   proxySettings:(nullable NSDictionary *)settings NS_SWIFT_NAME(prepare(_:configuration:proxySettings:));
- (NSURLSessionConfiguration *)sessionConfigurationWithProxy:(nullable NSDictionary *)proxy NS_SWIFT_NAME(sessionConfiguration(proxy:));
@end

NS_ASSUME_NONNULL_END
