import Foundation
import XCTest
@testable import SuperconnectCore
import SuperconnectCoreFFI
@testable import superconnect_app_foss_preview

final class FOSSPreviewSecurityPathTests: XCTestCase {
    private final class CaptureTransport: Transport {
        var onReceive: ((Data) -> Void)?
        var onStateChange: ((TransportState) -> Void)?
        var onSend: ((Data, Int) -> Void)?
        private let lock = NSLock()
        private var storage = [Data]()
        var sent: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func start() { onStateChange?(.ready) }
        func send(_ data: Data) {
            lock.lock()
            storage.append(data)
            let count = storage.count
            let callback = onSend
            lock.unlock()
            callback?(data, count)
        }
        func stop() { onStateChange?(.cancelled) }
    }

    private final class ManualTimer: SessionTimerDriving {
        var token: UInt64?
        func arm(token: UInt64, fire: @escaping (UInt64) -> Void) { self.token = token }
        func cancel(token: UInt64) { if self.token == token { self.token = nil } }
    }

    private struct OuterFrame {
        let channel: UInt8
        let flags: UInt8
        let payload: Data
    }

    private struct ActivatedDriver {
        let driver: RustInitiatorSessionDriver
        let peer: CanonicalRecordPeer
        let credentialStore: PairSecretStore
        let recordsActiveAtCapabilityCommit: Bool
    }

    private enum TestFailure: Error {
        case invalidFrame
        case recordFailure(Int32)
    }

    private final class CanonicalRecordPeer {
        private var outboundSealer: OpaquePointer?
        private var inboundOpener: OpaquePointer?

        init(
            secret: Data,
            macPeerID: String,
            tabletPeerID: String,
            tabletChallenge: Data,
            macChallenge: Data
        ) throws {
            var contextRequest = ScRecordContextRequestV1()
            contextRequest.struct_size = UInt32(MemoryLayout<ScRecordContextRequestV1>.size)
            contextRequest.api_version = UInt32(SC_API_VERSION_V1)
            contextRequest.initiator_peer_id_length = UInt32(macPeerID.utf8.count)
            contextRequest.responder_peer_id_length = UInt32(tabletPeerID.utf8.count)
            Self.copy(Data(macPeerID.utf8), into: &contextRequest.initiator_peer_id)
            Self.copy(Data(tabletPeerID.utf8), into: &contextRequest.responder_peer_id)
            Self.copy(tabletChallenge, into: &contextRequest.responder_challenge)
            Self.copy(macChallenge, into: &contextRequest.initiator_challenge)

            var context = ScRecordContextV1()
            context.struct_size = UInt32(MemoryLayout<ScRecordContextV1>.size)
            context.api_version = UInt32(SC_API_VERSION_V1)
            let contextStatus = sc_record_context_derive_v1(&contextRequest, &context)
            Self.wipe(&contextRequest)
            guard contextStatus == SC_OK, context.session_generation != 0 else {
                throw TestFailure.recordFailure(Int32(contextStatus))
            }
            var contextBytes = context.bytes
            let contextData = withUnsafeBytes(of: &contextBytes) { Data($0) }

            var outbound = Self.configuration(
                secret: secret,
                context: contextData,
                generation: context.session_generation,
                direction: UInt8(SC_RECORD_DIRECTION_RESPONDER_TO_INITIATOR)
            )
            var inbound = Self.configuration(
                secret: secret,
                context: contextData,
                generation: context.session_generation,
                direction: UInt8(SC_RECORD_DIRECTION_INITIATOR_TO_RESPONDER)
            )
            defer {
                Self.wipe(&outbound)
                Self.wipe(&inbound)
            }
            let sealerStatus = sc_record_sealer_new_v1(&outbound, &outboundSealer)
            guard sealerStatus == SC_OK, outboundSealer != nil else {
                throw TestFailure.recordFailure(Int32(sealerStatus))
            }
            let openerStatus = sc_record_opener_new_v1(&inbound, &inboundOpener)
            guard openerStatus == SC_OK, inboundOpener != nil else {
                if let outboundSealer { _ = sc_record_sealer_free_v1(outboundSealer) }
                outboundSealer = nil
                throw TestFailure.recordFailure(Int32(openerStatus))
            }
        }

        deinit {
            if let outboundSealer {
                XCTAssertEqual(Int32(sc_record_sealer_free_v1(outboundSealer)), Int32(SC_OK))
            }
            if let inboundOpener {
                XCTAssertEqual(Int32(sc_record_opener_free_v1(inboundOpener)), Int32(SC_OK))
            }
        }

        func sealForMac(channel: Channel, flags: FrameFlags = [], payload: Data) throws -> Data {
            guard let outboundSealer else { throw TestFailure.recordFailure(-1) }
            let type = try Self.recordType(channel)
            var needed = 0
            let query = payload.withUnsafeBytes { input in
                sc_record_seal_v1(
                    outboundSealer,
                    type,
                    flags.rawValue,
                    input.bindMemory(to: UInt8.self).baseAddress,
                    input.count,
                    nil,
                    0,
                    &needed
                )
            }
            guard query == SC_BUFFER_TOO_SMALL else {
                throw TestFailure.recordFailure(Int32(query))
            }
            var result = Data(count: needed)
            let status = payload.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { output in
                    sc_record_seal_v1(
                        outboundSealer,
                        type,
                        flags.rawValue,
                        input.bindMemory(to: UInt8.self).baseAddress,
                        input.count,
                        output.bindMemory(to: UInt8.self).baseAddress,
                        output.count,
                        &needed
                    )
                }
            }
            guard status == SC_OK, needed == result.count else {
                throw TestFailure.recordFailure(Int32(status))
            }
            return result
        }

        func openFromMac(channel: Channel, record: Data) throws -> (flags: UInt8, payload: Data) {
            guard let inboundOpener else { throw TestFailure.recordFailure(-1) }
            let type = try Self.recordType(channel)
            var flags: UInt8 = 0
            var needed = 0
            let query = record.withUnsafeBytes { input in
                sc_record_open_v1(
                    inboundOpener,
                    type,
                    input.bindMemory(to: UInt8.self).baseAddress,
                    input.count,
                    &flags,
                    nil,
                    0,
                    &needed
                )
            }
            guard query == SC_BUFFER_TOO_SMALL else {
                throw TestFailure.recordFailure(Int32(query))
            }
            var result = Data(count: needed)
            let capacity = result.count
            let status = record.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { output in
                    sc_record_open_v1(
                        inboundOpener,
                        type,
                        input.bindMemory(to: UInt8.self).baseAddress,
                        input.count,
                        &flags,
                        output.bindMemory(to: UInt8.self).baseAddress,
                        output.count,
                        &needed
                    )
                }
            }
            guard status == SC_OK, needed == capacity else {
                throw TestFailure.recordFailure(Int32(status))
            }
            return (flags, result)
        }

        private static func configuration(
            secret: Data,
            context: Data,
            generation: UInt64,
            direction: UInt8
        ) -> ScRecordConfigV1 {
            var value = ScRecordConfigV1()
            value.struct_size = UInt32(MemoryLayout<ScRecordConfigV1>.size)
            value.api_version = UInt32(SC_API_VERSION_V1)
            value.session_generation = generation
            value.max_plaintext_bytes = UInt64(FrameCodec.maxPayload)
            value.direction = direction
            copy(secret, into: &value.pair_secret)
            copy(context, into: &value.session_context)
            return value
        }

        private static func recordType(_ channel: Channel) throws -> UInt8 {
            switch channel {
            case .control: return UInt8(SC_RECORD_TYPE_CONTROL)
            case .video: return UInt8(SC_RECORD_TYPE_VIDEO)
            case .input: return UInt8(SC_RECORD_TYPE_INPUT)
            default: throw TestFailure.recordFailure(-1)
            }
        }

        private static func copy<T>(_ data: Data, into destination: inout T) {
            precondition(data.count <= MemoryLayout<T>.size)
            withUnsafeMutableBytes(of: &destination) { output in
                output.initializeMemory(as: UInt8.self, repeating: 0)
                data.copyBytes(to: output)
            }
        }

        private static func wipe<T>(_ value: inout T) {
            _ = withUnsafeMutableBytes(of: &value) {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
    }

    func testCompositionAllowsOptInInputAndWriterFailsClosedBeforeRecords() throws {
        let transport = CaptureTransport()
        let identity = try PortableSessionIdentity("mac-foss-test")
        let factory = FOSSPreviewSessionFactory(
            localIdentity: identity,
            secretStore: InMemoryPairSecretStore()
        )
        let session = factory.makeSession(transport: transport)
        let driver = try RustInitiatorSessionDriver(
            localPeerID: identity.rawValue,
            localRole: .source,
            trustedLocal: false,
            store: InMemoryPairSecretStore(),
            crypto: SessionAuthCryptographyProvider.active,
            timer: ManualTimer()
        )
        session.rustSession = driver

        XCTAssertEqual(factory.collaborationIntent.inputPolicy, .remoteControl)
        XCTAssertEqual(FOSSPreviewProduct.appName, "Superconnect FOSS Preview")
        XCTAssertEqual(FOSSPreviewProduct.bundleIdentifier, "com.superconnect.foss.preview")
        XCTAssertEqual(FOSSPreviewProduct.executableName, "superconnect-app-foss-preview")
        XCTAssertEqual(FOSSPreviewProduct.shortVersion, "0.2.2")
        XCTAssertEqual(FOSSPreviewProduct.buildVersion, "5")
        XCTAssertEqual(
            FOSSPreviewProduct.keychainService,
            "com.superconnect.foss.preview.pairing.secret.v2"
        )
        XCTAssertEqual(
            FOSSPreviewProduct.localIdentityDefaultsKey,
            "com.superconnect.foss.preview.local-peer-id.v2"
        )
        XCTAssertNotEqual(FOSSPreviewProduct.bundleIdentifier, "com.superconnect.free")
        XCTAssertEqual(session.collaborationIntent.inputPolicy, .remoteControl)
        XCTAssertNil(session.onInput)
        XCTAssertNil(session.onInputReset)
        XCTAssertNil(session.onText)
        XCTAssertFalse(FOSSPreviewProduct.requiresAccessibility)
        XCTAssertFalse(ReliableVideoFrameWriter(session: session, transport: transport)
            .sendVideo(Data([1, 2, 3]), isKeyframe: true))
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testPairSecretIsScopedToLocalAndRemoteIdentity() throws {
        let tablet = "android-foss-tablet"
        let first = FOSSPreviewPairSecretStore(
            localIdentity: try PortableSessionIdentity("mac-foss-first"))
        let second = FOSSPreviewPairSecretStore(
            localIdentity: try PortableSessionIdentity("mac-foss-second"))
        XCTAssertNotEqual(first.keychainAccount(for: tablet), second.keychainAccount(for: tablet))
        XCTAssertNotEqual(first.keychainAccount(for: tablet), first.keychainAccount(for: "android-foss-other"))
    }

    func testProductionWriterSealsVideoAndControlAfterAuthRecordBarrier() throws {
        let secret = Data(repeating: 0x5a, count: 32)
        let transport = CaptureTransport()
        let identity = try PortableSessionIdentity("mac-foss-test")
        let store = InMemoryPairSecretStore()
        XCTAssertEqual(store.storeIfAbsent(secret, for: "tablet-foss-test"), .inserted)
        let factory = FOSSPreviewSessionFactory(localIdentity: identity, secretStore: store)
        let session = factory.makeSession(transport: transport)
        let activated = try activateDriver(
            macPeerID: identity.rawValue,
            tabletPeerID: "tablet-foss-test",
            secret: secret,
            store: store
        )
        session.rustSession = activated.driver

        XCTAssertTrue(activated.recordsActiveAtCapabilityCommit)
        XCTAssertTrue(session.hasAuthenticatedRecords)

        let encodedAccessUnit = Data([0, 0, 0, 1, 0x65, 0xde, 0xad, 0xbe, 0xef])
        let writer = ReliableVideoFrameWriter(session: session, transport: transport)
        XCTAssertTrue(writer.sendVideo(encodedAccessUnit, isKeyframe: true))

        let expectedControl = try XCTUnwrap(
            VideoConfigControl(width: 1920, height: 1080, refreshRate: 60)?.wirePayload
        )
        session.sendVideoConfig(width: 1920, height: 1080, refreshRate: 60)
        XCTAssertEqual(transport.sent.count, 2)

        let videoOuter = try decodeOuter(transport.sent[0])
        XCTAssertEqual(videoOuter.channel, Channel.video.rawValue)
        XCTAssertEqual(videoOuter.flags, 0)
        XCTAssertEqual(videoOuter.payload.prefix(4), Data("SCR1".utf8))
        XCTAssertNil(transport.sent[0].range(of: encodedAccessUnit))
        let openedVideo = try activated.peer.openFromMac(
            channel: .video,
            record: videoOuter.payload
        )
        XCTAssertEqual(openedVideo.flags, FrameFlags.keyframe.rawValue)
        XCTAssertEqual(openedVideo.payload, encodedAccessUnit)

        let controlOuter = try decodeOuter(transport.sent[1])
        XCTAssertEqual(controlOuter.channel, Channel.control.rawValue)
        XCTAssertEqual(controlOuter.flags, 0)
        XCTAssertEqual(controlOuter.payload.prefix(4), Data("SCR1".utf8))
        XCTAssertNil(transport.sent[1].range(of: expectedControl))
        let openedControl = try activated.peer.openFromMac(
            channel: .control,
            record: controlOuter.payload
        )
        XCTAssertEqual(openedControl.flags, 0)
        XCTAssertEqual(openedControl.payload, expectedControl)
        XCTAssertEqual(
            PortableControlEnvelopeCodec.decode(openedControl.payload)?.kind,
            UInt32(SC_CONTROL_KIND_VIDEO_CONFIG_V1)
        )
    }

    func testPostAuthPlaintextTamperAndReplayFailBeforeRouting() throws {
        let control = try XCTUnwrap(
            VideoConfigControl(width: 1280, height: 720, refreshRate: 60)?.wirePayload
        )

        do {
            let harness = try activatedHarness()
            let plaintext = FrameCodec.encode(channel: .control, payload: control)
            XCTAssertNil(harness.driver.receiveBytes(plaintext))
            XCTAssertEqual(harness.driver.phaseForTesting(), .fatal)
        }

        do {
            let harness = try activatedHarness()
            var record = try harness.peer.sealForMac(channel: .control, payload: control)
            record[record.index(before: record.endIndex)] ^= 0x01
            let tampered = FrameCodec.encode(channel: .control, payload: record)
            XCTAssertNil(harness.driver.receiveBytes(tampered))
            XCTAssertEqual(harness.driver.phaseForTesting(), .fatal)
        }

        do {
            let harness = try activatedHarness()
            let record = try harness.peer.sealForMac(channel: .control, payload: control)
            let frame = FrameCodec.encode(channel: .control, payload: record)
            let first = try XCTUnwrap(harness.driver.receiveBytes(frame))
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first[0].frame.payload, control)
            XCTAssertNil(harness.driver.receiveBytes(frame))
            XCTAssertEqual(harness.driver.phaseForTesting(), .fatal)
        }
    }

    func testConcurrentRealControlsPreserveSealAndWireCounterOrder() throws {
        let secret = Data(repeating: 0x7c, count: 32)
        let store = InMemoryPairSecretStore()
        XCTAssertEqual(store.storeIfAbsent(secret, for: "tablet-foss-test"), .inserted)
        let transport = CaptureTransport()
        let factory = FOSSPreviewSessionFactory(
            localIdentity: try PortableSessionIdentity("mac-foss-test"),
            secretStore: store
        )
        let session = factory.makeSession(transport: transport)
        let activated = try activateDriver(
            macPeerID: "mac-foss-test",
            tabletPeerID: "tablet-foss-test",
            secret: secret,
            store: store
        )
        session.rustSession = activated.driver

        let firstPrepared = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let earlyEnqueue = DispatchSemaphore(value: 0)
        let hookLock = NSLock()
        var preparedCount = 0
        session.outboundFramePreparedForTesting = { channel in
            guard channel == .control else { return }
            hookLock.lock()
            preparedCount += 1
            let current = preparedCount
            hookLock.unlock()
            if current == 1 {
                firstPrepared.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
        }
        transport.onSend = { _, count in
            if count == 1 { earlyEnqueue.signal() }
        }

        let queue = DispatchQueue(
            label: "superconnect.foss.control-interleaving",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        group.enter()
        queue.async {
            session.sendVideoConfig(width: 1920, height: 1080, refreshRate: 60)
            group.leave()
        }
        XCTAssertEqual(firstPrepared.wait(timeout: .now() + 1), .success)
        group.enter()
        queue.async {
            session.sendPing()
            group.leave()
        }
        let didEnqueueWhileFirstWasPaused =
            earlyEnqueue.wait(timeout: .now() + 0.25) == .success
        releaseFirst.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(
            didEnqueueWhileFirstWasPaused,
            "a later CONTROL must not enqueue while the first sealed record is paused"
        )

        let frames = transport.sent
        XCTAssertEqual(frames.count, 2)
        let records = try frames.map { try decodeOuter($0).payload }
        XCTAssertEqual(try records.map(recordCounter), [1, 2])
        for record in records {
            let opened = try activated.peer.openFromMac(channel: .control, record: record)
            XCTAssertNotNil(PortableControlEnvelopeCodec.decode(opened.payload))
        }
    }

    func testReadyClearsHandshakeArtifactsAndRecordsStayUsable() throws {
        var cleanup = [UInt64: Bool]()
        let harness = try activatedHarness { cleanup[$0] = $1 }
        XCTAssertTrue(harness.driver.sensitiveHandshakeStateIsClearForTesting())
        XCTAssertEqual(cleanup[1], true, "ephemeral enrollment private key must be wiped at Ready")
        XCTAssertFalse(cleanup.isEmpty)
        XCTAssertTrue(cleanup.values.allSatisfy { $0 })
        var persisted = try XCTUnwrap(
            harness.credentialStore.secret(for: "tablet-foss-test")
        )
        XCTAssertEqual(persisted, Data(repeating: 0x6b, count: 32))
        persisted.resetBytes(in: persisted.startIndex..<persisted.endIndex)

        let payload = Data([0, 0, 0, 1, 0x65, 0xa1, 0xb2, 0xc3])
        let frame = try XCTUnwrap(harness.driver.frameOutbound(
            channel: Channel.video.rawValue,
            flags: FrameFlags.keyframe.rawValue,
            payload: payload
        ))
        let outer = try decodeOuter(frame)
        let opened = try harness.peer.openFromMac(channel: .video, record: outer.payload)
        XCTAssertEqual(opened.payload, payload)
    }

    func testEncryptedTabletPenAndKeysReachProductionInputCallback() throws {
        let transport = CaptureTransport()
        let factory = FOSSPreviewSessionFactory(
            localIdentity: try PortableSessionIdentity("mac-foss-test"),
            secretStore: InMemoryPairSecretStore())
        let session = factory.makeSession(transport: transport)
        session.start()
        let harness = try activatedHarness()
        session.rustSession = harness.driver
        var received: [InputEvent] = []
        session.onInput = { if let event = InputCodec.decode($0) { received.append(event) } }
        let events = [
            InputEvent(type: 0, tool: 1, buttons: 1, x: 0.25, y: 0.75, pressure: 0.6, tiltX: 12),
            InputEvent(type: 4, flags: 6, keyCode: 2017),
            InputEvent(type: 5, flags: 6, keyCode: 2017),
        ]
        for event in events {
            let record = try harness.peer.sealForMac(channel: .input, payload: InputCodec.encode(event))
            transport.onReceive?(FrameCodec.encode(channel: .input, payload: record))
        }
        XCTAssertEqual(received, events)
    }

    func testFailureAndCloseClearHandshakeArtifacts() throws {
        for closeNormally in [false, true] {
            var cleanup = [UInt64: Bool]()
            let driver = try RustInitiatorSessionDriver(
                localPeerID: "mac-foss-cleanup",
                localRole: .source,
                trustedLocal: false,
                store: InMemoryPairSecretStore(),
                crypto: SessionAuthCryptographyProvider.active,
                timer: ManualTimer()
            )
            driver.artifactCleanupProbeForTesting = { cleanup[$0] = $1 }
            driver.openTransport = {}
            driver.stopTransport = {}
            driver.sendHello = { _ in }
            driver.start()
            driver.transportReady()
            if closeNormally {
                driver.transportClosed()
            } else {
                driver.receiveHelloAck(
                    peer: "tablet-foss-cleanup",
                    authVersion: nil,
                    recordVersion: nil,
                    challenge: nil,
                    enrollment: false,
                    peerEnrollmentKey: nil,
                    commit: {}
                )
            }
            XCTAssertTrue(driver.sensitiveHandshakeStateIsClearForTesting())
            XCTAssertEqual(driver.phaseForTesting(), closeNormally ? .closed : .fatal)
            XCTAssertEqual(cleanup[1], true)
            XCTAssertTrue(cleanup.values.allSatisfy { $0 })
        }
    }

    private func activatedHarness(
        cleanupProbe: ((UInt64, Bool) -> Void)? = nil
    ) throws -> ActivatedDriver {
        let secret = Data(repeating: 0x6b, count: 32)
        let store = InMemoryPairSecretStore()
        XCTAssertEqual(store.storeIfAbsent(secret, for: "tablet-foss-test"), .inserted)
        return try activateDriver(
            macPeerID: "mac-foss-test",
            tabletPeerID: "tablet-foss-test",
            secret: secret,
            store: store,
            cleanupProbe: cleanupProbe
        )
    }

    private func activateDriver(
        macPeerID: String,
        tabletPeerID: String,
        secret: Data,
        store: PairSecretStore,
        cleanupProbe: ((UInt64, Bool) -> Void)? = nil
    ) throws -> ActivatedDriver {
        let crypto = SessionAuthCryptographyProvider.active
        let tabletChallenge = Data(repeating: 0x31, count: 32)
        let driver = try RustInitiatorSessionDriver(
            localPeerID: macPeerID,
            localRole: .source,
            trustedLocal: false,
            store: store,
            crypto: crypto,
            timer: ManualTimer()
        )
        driver.artifactCleanupProbeForTesting = cleanupProbe
        var macChallenge: Data?
        var recordsActiveAtCapabilityCommit = false
        driver.openTransport = {}
        driver.stopTransport = {}
        driver.sendHello = { _ in }
        driver.sendAuth = { _, challenge in macChallenge = challenge }
        driver.start()
        driver.transportReady()
        driver.receiveHelloAck(
            peer: tabletPeerID,
            authVersion: 1,
            recordVersion: 1,
            challenge: tabletChallenge,
            enrollment: false,
            peerEnrollmentKey: nil,
            commit: {
                recordsActiveAtCapabilityCommit = driver.hasAuthenticatedRecords()
                driver.capabilityCommitCompleted(true)
            }
        )
        let challenge = try XCTUnwrap(macChallenge)
        let proof = try crypto.createProof(
            secret: secret,
            direction: .tabletToMac(
                macPeerID: macPeerID,
                tabletPeerID: tabletPeerID,
                macNonce: challenge
            )
        )
        driver.receiveAuthAck(proof: proof)
        XCTAssertTrue(driver.hasAuthenticatedRecords())
        let peer = try CanonicalRecordPeer(
            secret: secret,
            macPeerID: macPeerID,
            tabletPeerID: tabletPeerID,
            tabletChallenge: tabletChallenge,
            macChallenge: challenge
        )
        return ActivatedDriver(
            driver: driver,
            peer: peer,
            credentialStore: store,
            recordsActiveAtCapabilityCommit: recordsActiveAtCapabilityCommit
        )
    }

    private func decodeOuter(_ bytes: Data) throws -> OuterFrame {
        guard bytes.count >= FrameCodec.headerSize else { throw TestFailure.invalidFrame }
        let length = Int(bytes[2])
            | (Int(bytes[3]) << 8)
            | (Int(bytes[4]) << 16)
            | (Int(bytes[5]) << 24)
        guard length == bytes.count - FrameCodec.headerSize else {
            throw TestFailure.invalidFrame
        }
        return OuterFrame(
            channel: bytes[0],
            flags: bytes[1],
            payload: Data(bytes.dropFirst(FrameCodec.headerSize))
        )
    }

    private func recordCounter(_ record: Data) throws -> UInt64 {
        guard record.count >= Int(SC_RECORD_HEADER_BYTES),
              record.prefix(4) == Data("SCR1".utf8) else {
            throw TestFailure.invalidFrame
        }
        return record[16..<24].withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
    }
}
