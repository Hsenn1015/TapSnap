#import "TSUpdateURLProtocol.h"
#import <CFNetwork/CFNetwork.h>
#import <os/log.h>

static NSString *const TSLocalUpdateProxy = @"TapSnapUpdateLocalProxy";

// Use only the manual route macOS selects for this URL after excluding auto-discovery.
// This also honors the user's proxy exceptions. Explicit company PAC files take precedence.
static NSDictionary *LocalUpdateProxy(NSURLRequest *request, NSDictionary *settings)
{
    if (![request.HTTPMethod isEqual:@"GET"] || ![request.URL.scheme.lowercaseString isEqual:@"https"] ||
        ![settings[(__bridge NSString *)kCFNetworkProxiesProxyAutoDiscoveryEnable] boolValue]) {
        return nil;
    }
    if ([settings[(__bridge NSString *)kCFNetworkProxiesProxyAutoConfigEnable] boolValue]) {
        NSString *pac = settings[(__bridge NSString *)kCFNetworkProxiesProxyAutoConfigURLString];
        if (![pac.lowercaseString isEqual:@"http://wpad/wpad.dat"]) return nil;
    }
    NSMutableDictionary *manual = [@{@"ProxyAutoDiscoveryEnable": @NO, @"ProxyAutoConfigEnable": @NO} mutableCopy];
    for (NSString *key in @[@"HTTPSEnable", @"HTTPSProxy", @"HTTPSPort", @"SOCKSEnable", @"SOCKSProxy",
                             @"SOCKSPort", @"ExceptionsList", @"ExcludeSimpleHostnames"]) {
        manual[key] = settings[key];
    }
    NSArray *routes = CFBridgingRelease(CFNetworkCopyProxiesForURL((__bridge CFURLRef)request.URL,
                                                                   (__bridge CFDictionaryRef)manual));
    NSDictionary *route = routes.firstObject;
    NSString *type = route[(__bridge NSString *)kCFProxyTypeKey];
    NSString *host = [route[(__bridge NSString *)kCFProxyHostNameKey] lowercaseString];
    NSInteger port = [route[(__bridge NSString *)kCFProxyPortNumberKey] integerValue];
    BOOL socks = [type isEqual:(__bridge NSString *)kCFProxyTypeSOCKS];
    BOOL web = [type isEqual:(__bridge NSString *)kCFProxyTypeHTTPS] || [type isEqual:(__bridge NSString *)kCFProxyTypeHTTP];
    if ((!socks && !web) || !host || ![@[@"localhost", @"127.0.0.1", @"::1", @"[::1]"] containsObject:host] ||
        port <= 0 || port > 65535) {
        return nil;
    }
    // Only the selected loopback route may participate, including after a redirect.
    manual[socks ? @"HTTPSEnable" : @"SOCKSEnable"] = @NO;
    return manual;
}

@interface TSUpdateURLProtocol () <NSURLSessionDataDelegate>
@property(atomic) BOOL stopped;
@end

@implementation TSUpdateURLProtocol {
    NSURLSession *_systemSession;
    NSURLSessionDataTask *_systemTask;
    NSURLSession *_proxySession;
    NSURLSession *_winner;
    NSError *_systemError;
    BOOL _proxyAttempted;
    BOOL _finished;
}

+ (NSURLRequest *)prepareRequest:(NSURLRequest *)request configuration:(NSURLSessionConfiguration *)configuration
                   proxySettings:(NSDictionary *)settings
{
    NSDictionary *proxy = LocalUpdateProxy(request, settings);
    if (!proxy) return request;
    NSMutableURLRequest *marked = [request mutableCopy];
    [NSURLProtocol setProperty:proxy forKey:TSLocalUpdateProxy inRequest:marked];
    configuration.protocolClasses = [@[self] arrayByAddingObjectsFromArray:configuration.protocolClasses ?: @[]];
    return marked;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    return [NSURLProtocol propertyForKey:TSLocalUpdateProxy inRequest:request] != nil;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (NSURLSessionConfiguration *)sessionConfigurationWithProxy:(NSDictionary *)proxy
{
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.connectionProxyDictionary = proxy;
    return configuration;
}

- (NSURLSession *)startSessionWithProxy:(NSDictionary *)proxy
{
    NSMutableURLRequest *request = [self.request mutableCopy];
    [NSURLProtocol removePropertyForKey:TSLocalUpdateProxy inRequest:request];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[self sessionConfigurationWithProxy:proxy]
                                                         delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    if (!proxy) _systemTask = task;
    [task resume];
    return session;
}

- (void)tryLocalProxy
{
    if (self.stopped || _finished || _winner || _proxyAttempted) return;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)_systemTask.response;
    if (!_systemError && ((response.statusCode >= 200 && response.statusCode < 300) ||
                          (!response && _systemTask.countOfBytesReceived > 0))) return;
    _proxyAttempted = YES;
    _proxySession = [self startSessionWithProxy:[NSURLProtocol propertyForKey:TSLocalUpdateProxy inRequest:self.request]];
}

- (void)startLoading
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stopped || self->_finished) return;
        self->_systemSession = [self startSessionWithProxy:nil];
        __weak TSUpdateURLProtocol *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf tryLocalProxy];
        });
    });
}

- (void)closeSessions
{
    _finished = YES;
    [_systemSession invalidateAndCancel];
    [_proxySession invalidateAndCancel];
    _systemSession = nil;
    _systemTask = nil;
    _proxySession = nil;
    _winner = nil;
}

- (void)stopLoading
{
    self.stopped = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self closeSessions]; });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion
{
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    if (self.stopped || _finished || _winner || (session == _proxySession && !_systemError && (status < 200 || status >= 300))) {
        completion(NSURLSessionResponseCancel);
        return;
    }
    _winner = session;
    if (session == _proxySession) os_log_info(OS_LOG_DEFAULT, "TapSnap update continued through the configured local proxy");
    [(session == _systemSession ? _proxySession : _systemSession) invalidateAndCancel];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completion(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    if (!self.stopped && !_finished && session == _winner) [self.client URLProtocol:self didLoadData:data];
}

static BOOL IsConnectionError(NSError *error)
{
    if (![error.domain isEqual:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorTimedOut: case NSURLErrorCannotFindHost: case NSURLErrorDNSLookupFailed:
        case NSURLErrorCannotConnectToHost: case NSURLErrorNetworkConnectionLost: case NSURLErrorNotConnectedToInternet:
            return YES;
        default: return NO;
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (self.stopped || _finished || (_winner && session != _winner)) return;
    if (!_winner && session == _systemSession && IsConnectionError(error)) {
        _systemError = error;
        [self tryLocalProxy];
        if (_proxySession) return;
    } else if (!_winner && session == _proxySession) {
        [_proxySession finishTasksAndInvalidate];
        _proxySession = nil;
        if (!_systemError) return;
        error = _systemError;
    }
    if (error) [self.client URLProtocol:self didFailWithError:error];
    else [self.client URLProtocolDidFinishLoading:self];
    [self closeSessions];
}
@end
