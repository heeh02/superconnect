import XCTest
@testable import SuperconnectCore

/// Contract test for the PairSecretStore abstraction (via the in-memory impl — the Keychain impl is a
/// thin SecItem wrapper verified on a signed device, where the test sandbox can't reach the Keychain).
final class PairSecretStoreTests: XCTestCase {
    func testStoreContract() {
        let s: PairSecretStore = InMemoryPairSecretStore()
        XCTAssertNil(s.secret(for: "peer-1"))                       // absent → nil (caller must pair)

        let secret = Data((0..<32).map { UInt8($0) })
        s.store(secret, for: "peer-1")
        XCTAssertEqual(s.secret(for: "peer-1"), secret)            // round-trip
        XCTAssertNil(s.secret(for: "peer-2"))                       // keyed per peer

        let secret2 = Data(repeating: 0x9, count: 32)
        s.store(secret2, for: "peer-1")                            // upsert replaces
        XCTAssertEqual(s.secret(for: "peer-1"), secret2)

        s.remove(for: "peer-1")
        XCTAssertNil(s.secret(for: "peer-1"))                       // forgotten
    }
}
