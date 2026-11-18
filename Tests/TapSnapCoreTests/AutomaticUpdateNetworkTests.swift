import Foundation
import XCTest
import TapSnapUpdateNetwork

final class AutomaticUpdateNetworkTests: XCTestCase {
    private let settings: [String: Any] = [
        "ProxyAutoDiscoveryEnable": 1, "ProxyAutoConfigEnable": 1,
        "ProxyAutoConfigURLString": "http://wpad/wpad.dat",
        "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890
    ]

    private func request(_ scenario: String) -> URLRequest {
        URLRequest(url: URL(string: "https://updates.example/\(scenario)")!)
    }

    func test仅自动发现配合有效本机代理时启用备用线路() {
        func enabled(_ parameters: [String: Any], _ req: URLRequest) -> Bool {
            let config = URLSessionConfiguration.ephemeral
            _ = TSUpdateURLProtocol.prepare(req, configuration: config, proxySettings: parameters)
            return config.protocolClasses?.first == TSUpdateURLProtocol.self
        }
        let req = request("appcast.xml")
        XCTAssertTrue(enabled(settings, req))
        XCTAssertTrue(enabled(["ProxyAutoDiscoveryEnable": 1, "SOCKSEnable": 1,
                               "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1080], req))
        for override in [
            ["ProxyAutoDiscoveryEnable": 0], ["HTTPSEnable": 0], ["HTTPSProxy": "proxy.example"],
            ["HTTPSPort": 65536], ["ProxyAutoConfigURLString": "https://company.example/managed.pac"],
            ["ExceptionsList": ["updates.example"]]
        ] as [[String: Any]] {
            XCTAssertFalse(enabled(settings.merging(override) { _, new in new }, req), "\(override)")
        }
        XCTAssertFalse(enabled(settings, URLRequest(url: URL(string: "http://127.0.0.1/feed.xml")!)))
    }

    private func session(_ scenario: String) -> (URLSession, URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        let prepared = TestUpdateTransport.prepare(request(scenario), configuration: config, proxySettings: settings)
        return (URLSession(configuration: config), prepared)
    }

    func test正常系统连接直接交付响应() async throws {
        let (session, req) = session("normal")
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "system-body")
        XCTAssertEqual(response.url?.host, "assets.example")
    }

    func test清单等待首个响应时自动切换() async throws {
        let (session, req) = session("stalled")
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: req)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "proxy-body")
    }

    func test安装包连接失败后自动切换并完整落盘() async throws {
        let (session, req) = session("unreachable")
        defer { session.invalidateAndCancel() }
        let (file, _) = try await session.download(for: req)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "proxy-body")
    }

    func test备用代理不可用时原连接仍可完成() async throws {
        let (session, req) = session("proxy-down")
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: req)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "system-body")
    }

    func test已经开始传输的慢下载保持同一条连接() async throws {
        let (session, req) = session("slow-body")
        defer { session.invalidateAndCancel() }
        let (file, _) = try await session.download(for: req)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "system-body")
    }

    func test取消等待时停止两条线路() async {
        let (session, req) = session("cancel")
        defer { session.invalidateAndCancel() }
        let started = expectation(forNotification: .init("route-test-proxy-started"), object: nil)
        let stopped = ["system", "proxy"].map {
            expectation(forNotification: .init("route-test-\($0)-stopped"), object: nil)
        }
        let completed = expectation(description: "收到一次取消结果")
        let task = session.dataTask(with: req) { _, _, error in
            XCTAssertEqual((error as NSError?)?.code, NSURLErrorCancelled)
            completed.fulfill()
        }
        task.resume()
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        await fulfillment(of: stopped + [completed], timeout: 3)
    }

    func test两条线路均失败时保留原始连接错误() async {
        let (session, req) = session("both-down")
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(for: req); XCTFail("预期连接失败") }
        catch { XCTAssertEqual((error as NSError).code, NSURLErrorCannotConnectToHost) }
    }

    func test服务器拒绝或证书错误原样返回() async throws {
        let (session, req) = session("http-error")
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
        let (tlsSession, tlsRequest) = self.session("tls-error")
        defer { tlsSession.invalidateAndCancel() }
        do { _ = try await tlsSession.data(for: tlsRequest); XCTFail("预期证书错误") }
        catch { XCTAssertEqual((error as NSError).code, NSURLErrorServerCertificateUntrusted) }
    }
}

private final class TestUpdateTransport: TSUpdateURLProtocol, @unchecked Sendable {
    override func sessionConfiguration(proxy: [AnyHashable: Any]?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [proxy == nil ? SystemUpdateFixture.self : ProxyUpdateFixture.self]
        return config
    }
}

private class UpdateFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scenario = request.url!.lastPathComponent
        let proxy = self is ProxyUpdateFixture
        if scenario == "cancel" {
            if proxy { NotificationCenter.default.post(name: .init("route-test-proxy-started"), object: nil) }
            return
        }
        if scenario == "slow-body", proxy { XCTFail("传输已有进度时不能重复下载") }
        if scenario == "stalled", !proxy { return }
        var error: URLError.Code?
        switch (scenario, proxy) {
        case ("unreachable", false), ("both-down", false): error = .cannotConnectToHost
        case ("proxy-down", true), ("both-down", true): error = .timedOut
        case ("tls-error", false): error = .serverCertificateUntrusted
        default: break
        }
        if let error {
            client?.urlProtocol(self, didFailWithError: URLError(error))
            return
        }
        let send = { [self] in
            let response = HTTPURLResponse(url: URL(string: "https://assets.example/\(scenario)")!,
                                           statusCode: scenario == "http-error" && !proxy ? 403 : 200,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream",
                                                                                  "Content-Length": proxy ? "10" : "11"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((proxy ? "proxy" : "system").utf8))
            let finish = { [self] in
                client?.urlProtocol(self, didLoad: Data("-body".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            if scenario == "slow-body" { DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: finish) }
            else { finish() }
        }
        if scenario == "proxy-down", !proxy { DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: send) }
        else { send() }
    }

    override func stopLoading() {
        if request.url?.lastPathComponent == "cancel" {
            let route = self is ProxyUpdateFixture ? "proxy" : "system"
            NotificationCenter.default.post(name: .init("route-test-\(route)-stopped"), object: nil)
        }
    }
}

private final class SystemUpdateFixture: UpdateFixture, @unchecked Sendable {}
private final class ProxyUpdateFixture: UpdateFixture, @unchecked Sendable {}
