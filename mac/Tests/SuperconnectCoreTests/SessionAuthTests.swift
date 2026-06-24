import XCTest
@testable import SuperconnectCore

/// Regression tests for the SC-AUTH-v1 CLIENT (Mac) fail-closed posture (audit H4). The Mac must NOT
/// connect to a WIRELESS peer that sends no challenge, and must NOT silently re-enroll over a secret it
/// already holds. Driven through a mock transport (no network).
final class SessionAuthTests: XCTestCase {

    private final class MockTransport: Transport {
        var onReceive: ((Data) -> Void)?
        var onStateChange: ((TransportState) -> Void)?
        private(set) var sent: [Data] = []
        func start() { onStateChange?(.ready) }   // → Session.sendHello
        func send(_ data: Data) { sent.append(data) }
        func stop() {}
        func feed(_ object: [String: Any]) {
            let payload = try! JSONSerialization.data(withJSONObject: object)
            onReceive?(FrameCodec.encode(channel: .control, payload: payload))
        }
    }

    /// FAIL-OPEN guard: a wireless dial (peerIsLoopback=false) that receives hello_ack with authVersion
    /// but NO nonce must REFUSE (auth_required) and never fire onConnected.
    func testWirelessNoChallengeFailsClosed() {
        let t = MockTransport()
        let s = Session(transport: t, role: "mac")
        s.secretStore = InMemoryPairSecretStore()
        s.peerIsLoopback = false   // wireless
        var connected = false; var error: String?
        s.onConnected = { connected = true }
        s.onError = { error = $0 }
        s.start()
        t.feed(["type": "hello_ack", "authVersion": 1, "peerId": "tablet-1"])   // no nonce
        XCTAssertFalse(connected, "a wireless peer that sent no challenge must NOT connect")
        XCTAssertTrue(error?.contains("auth_required") ?? false, "should fail closed: \(error ?? "nil")")
    }

    /// The wired/loopback exemption is a CLIENT fact: peerIsLoopback=true + nonce-less hello_ack connects.
    func testLoopbackNoChallengeConnects() {
        let t = MockTransport()
        let s = Session(transport: t, role: "mac")
        s.secretStore = InMemoryPairSecretStore()
        s.peerIsLoopback = true   // wired hdc
        var connected = false
        s.onConnected = { connected = true }
        s.onError = { _ in }
        s.start()
        t.feed(["type": "hello_ack", "authVersion": 1, "peerId": "tablet-1"])
        XCTAssertTrue(connected, "wired/loopback dial is exempt and connects")
    }

    /// Un-upgraded peer (no authVersion) is refused even on a wireless dial — never peerId-trust fallback.
    func testMissingAuthVersionFailsClosed() {
        let t = MockTransport()
        let s = Session(transport: t, role: "mac")
        s.secretStore = InMemoryPairSecretStore()
        s.peerIsLoopback = false
        var connected = false; var error: String?
        s.onConnected = { connected = true }
        s.onError = { error = $0 }
        s.start()
        t.feed(["type": "hello_ack", "peerId": "tablet-1"])   // no authVersion, no nonce
        XCTAssertFalse(connected)
        XCTAssertTrue(error?.contains("auth_required") ?? false)
    }

    /// SECRET-OVERWRITE guard: if we already hold a secret for the tablet, an unsolicited needsPairing
    /// (re-enroll) must FAIL CLOSED rather than clobber the stored secret.
    func testUnsolicitedReEnrollOverKnownSecretFailsClosed() {
        let t = MockTransport()
        let store = InMemoryPairSecretStore()
        store.store(Data(repeating: 7, count: 32), for: "tablet-1")   // already enrolled
        let s = Session(transport: t, role: "mac")
        s.secretStore = store
        s.peerIsLoopback = false
        var connected = false; var error: String?
        s.onConnected = { connected = true }
        s.onError = { error = $0 }
        s.start()
        t.feed(["type": "hello_ack", "authVersion": 1, "peerId": "tablet-1",
                "nonce": Data(repeating: 1, count: 32).base64EncodedString(),
                "needsPairing": true,
                "ephPub": Data(repeating: 4, count: 65).base64EncodedString()])
        XCTAssertFalse(connected, "must not enroll over an existing secret")
        XCTAssertTrue(error?.contains("auth_failed") ?? false, "should fail closed: \(error ?? "nil")")
        XCTAssertEqual(store.secret(for: "tablet-1"), Data(repeating: 7, count: 32), "stored secret must be untouched")
    }
}
