// SPIKE (do not merge).
//
// Measures whether AsyncHTTPClient's `http1_1ConnectionDebugInitializer` can act as a
// connection-level SSRF address check: it should see the connected peer address
// (`channel.remoteAddress`) and, by failing its future, stop the request before any request
// bytes reach the peer. Every check has a negative control that runs the same request with
// the hook removed, so a failure in the hooked run can be attributed to the hook.
//
// Lines prefixed `SPIKE:` are the measurements; grep the test log for them.

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOPosix
import Synchronization
import Testing

// MARK: - Address policy under test

/// Error the hook fails its future with.
struct BlockedRemoteAddress: Error, CustomStringConvertible {
    let address: String
    var description: String { "BlockedRemoteAddress(\(address))" }
}

enum AddressPolicy {
    /// True when the peer must not be contacted: nil (fail closed), loopback, RFC 1918 private,
    /// CGNAT, link-local, unspecified, multicast/broadcast, IPv6 ULA/link-local, and IPv4-mapped
    /// IPv6 forms of any of those.
    static func isBlocked(_ address: SocketAddress?) -> Bool {
        guard let address else { return true }
        switch address {
        case .v4(let a):
            return isBlockedV4(withUnsafeBytes(of: a.address.sin_addr) { Array($0) })
        case .v6(let a):
            let b = withUnsafeBytes(of: a.address.sin6_addr) { Array($0) }
            // ::ffff:a.b.c.d (IPv4-mapped)
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isBlockedV4(Array(b[12..<16]))
            }
            if b.allSatisfy({ $0 == 0 }) { return true }  // ::
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }  // ::1
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }  // fe80::/10
            if (b[0] & 0xfe) == 0xfc { return true }  // fc00::/7
            if b[0] == 0xff { return true }  // ff00::/8 multicast
            return false
        case .unixDomainSocket:
            return true
        }
    }

    private static func isBlockedV4(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _), (10, _), (127, _): return true
        case (169, 254): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (100, 64...127): return true  // CGNAT 100.64/10
        case (224..., _): return true  // multicast, reserved, broadcast
        default: return false
        }
    }
}

// MARK: - Minimal recording HTTP/1.1 server

final class ServerStats: Sendable {
    private let state = Mutex<(connections: Int, bytes: Int, closes: Int)>((0, 0, 0))
    func connected() { state.withLock { $0.connections += 1 } }
    func received(_ n: Int) { state.withLock { $0.bytes += n } }
    func closed() { state.withLock { $0.closes += 1 } }
    var connections: Int { state.withLock { $0.connections } }
    var bytes: Int { state.withLock { $0.bytes } }
    var closes: Int { state.withLock { $0.closes } }
}

final class RecordingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let stats: ServerStats
    private let response: String
    private var received = ByteBuffer()
    private var responded = false

    init(stats: ServerStats, response: String) {
        self.stats = stats
        self.response = response
    }

    func channelActive(context: ChannelHandlerContext) {
        stats.connected()
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        stats.closed()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        stats.received(buffer.readableBytes)
        received.writeBuffer(&buffer)
        if !responded, String(buffer: received).contains("\r\n\r\n") {
            responded = true
            context.writeAndFlush(Self.wrapOutboundOut(ByteBuffer(string: response)), promise: nil)
        }
    }
}

struct TestServer {
    let channel: Channel
    let stats: ServerStats
    var port: Int { channel.localAddress!.port! }

    static func start(response: String) async throws -> TestServer {
        let stats = ServerStats()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        RecordingHandler(stats: stats, response: response))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return TestServer(channel: channel, stats: stats)
    }

    func stop() async throws { try await channel.close() }

    static let ok =
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
    static func redirect(to url: String) -> String {
        "HTTP/1.1 302 Found\r\nLocation: \(url)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }
}

// MARK: - Client construction

final class HookLog: Sendable {
    private let entries = Mutex<[String]>([])
    func record(_ s: String) { entries.withLock { $0.append(s) } }
    var all: [String] { entries.withLock { $0 } }
}

func makeClient(
    addressCheck: HookLog?,
    redirect: HTTPClient.Configuration.RedirectConfiguration = .disallow,
    retryConnectionEstablishment: Bool = false,
    closeOnBlock: Bool = false
) -> HTTPClient {
    var config = HTTPClient.Configuration(
        redirectConfiguration: redirect,
        timeout: .init(connect: .seconds(2), read: .seconds(2))
    )
    config.httpVersion = .http1Only
    config.proxy = nil
    config.connectionPool.retryConnectionEstablishment = retryConnectionEstablishment
    if let log = addressCheck {
        config.http1_1ConnectionDebugInitializer = { channel in
            let remote = channel.remoteAddress
            log.record(remote.map { "\($0)" } ?? "nil")
            if AddressPolicy.isBlocked(remote) {
                if closeOnBlock { channel.close(promise: nil) }
                return channel.eventLoop.makeFailedFuture(
                    BlockedRemoteAddress(address: remote.map { "\($0)" } ?? "nil"))
            }
            return channel.eventLoop.makeSucceededVoidFuture()
        }
    }
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: config)
}

/// Lets any in-flight bytes land on the server before counting.
func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

// MARK: - Tests

@Suite("Spike: AHC connection-level address check", .serialized)
struct SpikeAHCAddressCheckTests {

    // C1 + C2. Hook on, retryConnectionEstablishment = false.
    @Test func t1_hookBlocksLoopbackBeforeAnyRequestBytes() async throws {
        let server = try await TestServer.start(response: TestServer.ok)
        let log = HookLog()
        let client = makeClient(addressCheck: log)

        var caught: Error?
        let start = ContinuousClock.now
        do {
            _ = try await client.execute(
                HTTPClientRequest(url: "http://127.0.0.1:\(server.port)/"), timeout: .seconds(5))
        } catch {
            caught = error
        }
        let elapsed = ContinuousClock.now - start
        try await client.shutdown()
        try await settle()

        print("SPIKE: T1 thrown=\(caught.map { "\(type(of: $0)): \($0)" } ?? "none") elapsed=\(elapsed)")
        print("SPIKE: T1 hookCalls=\(log.all.count) remoteAddress=\(log.all) remoteAddressNonNil=\(log.all.allSatisfy { $0 != "nil" })")
        print("SPIKE: T1 server connections=\(server.stats.connections) bytes=\(server.stats.bytes) closes=\(server.stats.closes)")

        #expect(caught is BlockedRemoteAddress)
        #expect(server.stats.bytes == 0)
        #expect(server.stats.connections >= 1)  // TCP connection existed when the hook ran
        #expect(!log.all.isEmpty)
        #expect(log.all.allSatisfy { $0 != "nil" })
        try await server.stop()
    }

    // Negative control for T1: identical request, hook removed.
    @Test func t1Control_noHookRequestSucceedsAndBytesArrive() async throws {
        let server = try await TestServer.start(response: TestServer.ok)
        let client = makeClient(addressCheck: nil)

        let response = try await client.execute(
            HTTPClientRequest(url: "http://127.0.0.1:\(server.port)/"), timeout: .seconds(5))
        let body = try await response.body.collect(upTo: 1024)
        try await client.shutdown()
        try await settle()

        print("SPIKE: T1-control status=\(response.status.code) body=\(String(buffer: body))")
        print("SPIKE: T1-control server connections=\(server.stats.connections) bytes=\(server.stats.bytes) closes=\(server.stats.closes)")

        #expect(response.status == .ok)
        #expect(server.stats.bytes > 0)
        try await server.stop()
    }

    // T1 leaves the rejected connection open (server sees no close). Same as T1, but the hook
    // closes the channel itself before failing: does the hook's error still surface?
    @Test func t1c_hookClosesChannelOnBlock() async throws {
        let server = try await TestServer.start(response: TestServer.ok)
        let log = HookLog()
        let client = makeClient(addressCheck: log, closeOnBlock: true)

        var caught: Error?
        do {
            _ = try await client.execute(
                HTTPClientRequest(url: "http://127.0.0.1:\(server.port)/"), timeout: .seconds(5))
        } catch {
            caught = error
        }
        try await client.shutdown()
        try await settle()

        print("SPIKE: T1c(closeOnBlock) thrown=\(caught.map { "\(type(of: $0)): \($0)" } ?? "none")")
        print("SPIKE: T1c(closeOnBlock) hookCalls=\(log.all.count) server connections=\(server.stats.connections) bytes=\(server.stats.bytes) closes=\(server.stats.closes)")

        #expect(caught is BlockedRemoteAddress)
        #expect(server.stats.bytes == 0)
        try await server.stop()
    }

    // C1 under the pool's default retryConnectionEstablishment = true: does a hook failure
    // still surface as the hook's error, and how many connections does the pool open?
    @Test func t1b_hookWithDefaultRetryBehaviour() async throws {
        let server = try await TestServer.start(response: TestServer.ok)
        let log = HookLog()
        let client = makeClient(addressCheck: log, retryConnectionEstablishment: true)

        var caught: Error?
        let start = ContinuousClock.now
        do {
            _ = try await client.execute(
                HTTPClientRequest(url: "http://127.0.0.1:\(server.port)/"), timeout: .seconds(2))
        } catch {
            caught = error
        }
        let elapsed = ContinuousClock.now - start
        try await client.shutdown()
        try await settle()

        print("SPIKE: T1b(retry=true) thrown=\(caught.map { "\(type(of: $0)): \($0)" } ?? "none") elapsed=\(elapsed)")
        print("SPIKE: T1b(retry=true) hookCalls=\(log.all.count) server connections=\(server.stats.connections) bytes=\(server.stats.bytes) closes=\(server.stats.closes)")

        #expect(caught != nil)
        #expect(server.stats.bytes == 0)
        try await server.stop()
    }

    // C3. 302 with redirects disallowed is returned to the caller; the target is not contacted.
    @Test func t2_redirectDisallowReturns302AndTargetUntouched() async throws {
        let target = try await TestServer.start(response: TestServer.ok)
        let redirector = try await TestServer.start(
            response: TestServer.redirect(to: "http://127.0.0.1:\(target.port)/target"))
        let client = makeClient(addressCheck: nil, redirect: .disallow)

        let response = try await client.execute(
            HTTPClientRequest(url: "http://127.0.0.1:\(redirector.port)/"), timeout: .seconds(5))
        _ = try await response.body.collect(upTo: 1024)
        try await client.shutdown()
        try await settle()

        print("SPIKE: T2(.disallow) status=\(response.status.code) location=\(response.headers["location"])")
        print("SPIKE: T2(.disallow) redirector bytes=\(redirector.stats.bytes) target connections=\(target.stats.connections) bytes=\(target.stats.bytes)")

        #expect(response.status.code == 302)
        #expect(redirector.stats.bytes > 0)
        #expect(target.stats.connections == 0)
        #expect(target.stats.bytes == 0)
        try await redirector.stop()
        try await target.stop()
    }

    // Negative control for T2: same servers, redirects followed; the target receives the request.
    @Test func t2Control_redirectFollowReachesTarget() async throws {
        let target = try await TestServer.start(response: TestServer.ok)
        let redirector = try await TestServer.start(
            response: TestServer.redirect(to: "http://127.0.0.1:\(target.port)/target"))
        let client = makeClient(addressCheck: nil, redirect: .follow(max: 3, allowCycles: false))

        let response = try await client.execute(
            HTTPClientRequest(url: "http://127.0.0.1:\(redirector.port)/"), timeout: .seconds(5))
        _ = try await response.body.collect(upTo: 1024)
        try await client.shutdown()
        try await settle()

        print("SPIKE: T2-control(.follow) status=\(response.status.code) target connections=\(target.stats.connections) bytes=\(target.stats.bytes)")

        #expect(response.status == .ok)
        #expect(target.stats.bytes > 0)
        try await redirector.stop()
        try await target.stop()
    }

    // The policy itself, including IPv4-mapped IPv6.
    @Test(arguments: [
        ("127.0.0.1", true), ("10.1.2.3", true), ("172.16.0.1", true), ("172.31.255.255", true),
        ("192.168.1.1", true), ("169.254.169.254", true), ("100.64.0.1", true), ("0.0.0.0", true),
        ("224.0.0.1", true), ("::1", true), ("::", true), ("fe80::1", true), ("fd00::1", true),
        ("::ffff:127.0.0.1", true), ("::ffff:169.254.169.254", true), ("::ffff:10.0.0.1", true),
        ("8.8.8.8", false), ("172.32.0.1", false), ("2606:4700::1", false), ("::ffff:8.8.8.8", false),
    ])
    func policy(_ ip: String, _ blocked: Bool) throws {
        let address = try SocketAddress(ipAddress: ip, port: 443)
        #expect(AddressPolicy.isBlocked(address) == blocked, "\(ip)")
    }

    @Test func policyFailsClosedOnNil() {
        #expect(AddressPolicy.isBlocked(nil))
    }
}
