import Foundation
import SuperconnectCoreFFI

public enum PortableSessionHelloKind: Sendable { case hello, helloAck }

public struct PortableSessionHelloCaps: Equatable, Sendable {
    public var codecs: UInt32 = UInt32(SC_SESSION_HELLO_CODEC_H264_V1)
    public var maxWidth: UInt32?
    public var maxHeight: UInt32?
    public var screenWidth: UInt32?
    public var screenHeight: UInt32?
    public var scale: Double?
    public var refreshRate: UInt32?
    public var refreshRateMax: UInt32?
    public var hidpi: Bool?
    public var pen: Bool?
    public var hdrHLG: Bool?
    public var hdrPQ: Bool?

    public init() {}
}

public struct PortableSessionHelloMessage: Equatable, Sendable {
    public var kind: PortableSessionHelloKind
    public var legacyRole: String
    public var protocolVersion: UInt16 = 2
    public var authVersion: UInt16?
    public var recordVersion: UInt16?
    public var capabilityVersion: UInt16?
    public var capabilityIntentVersion: UInt16?
    public var frameMetaVersion: UInt16?
    public var mediaRecoveryVersion: UInt16?
    public var udpVideoVersion: UInt16?
    public var udpVideoPort: UInt16?
    public var peerID: String
    public var platform: String?
    public var deviceName: String?
    public var appVersion: String?
    public var pairingToken: String?
    public var supportedRoles = Set<MediaRole>()
    public var desiredRole: MediaRole?
    public var acceptedRole: MediaRole?
    public var projection: ProjectionMode?
    public var caps: PortableSessionHelloCaps?
    public var enrollmentKey: Data?
    public var challenge: Data?
    public var needsPairing: Bool?

    public init(kind: PortableSessionHelloKind, legacyRole: String, peerID: String) {
        self.kind = kind
        self.legacyRole = legacyRole
        self.peerID = peerID
    }

    public var foundationObject: [String: Any] {
        var value: [String: Any] = [
            "type": kind == .hello ? "hello" : "hello_ack",
            "role": legacyRole,
            "protocolVersion": Int(protocolVersion),
            "peerId": peerID,
        ]
        func put(_ key: String, _ item: Any?) { if let item { value[key] = item } }
        put("authVersion", authVersion.map { Int($0) }); put("recordVersion", recordVersion.map { Int($0) })
        put("capabilityNegotiationVersion", capabilityVersion.map { Int($0) })
        put("capabilityIntentNegotiationVersion", capabilityIntentVersion.map { Int($0) })
        put("frameMetaVersion", frameMetaVersion.map { Int($0) }); put("mediaRecoveryVersion", mediaRecoveryVersion.map { Int($0) })
        put("udpVideoVersion", udpVideoVersion.map { Int($0) }); put("udpVideoPort", udpVideoPort.map { Int($0) })
        put("platform", platform); put("deviceName", deviceName); put("appVersion", appVersion); put("pairingToken", pairingToken)
        if !supportedRoles.isEmpty { value["supportedRoles"] = supportedRoles.map(\.legacyWireValue).sorted() }
        put("desiredRole", desiredRole?.legacyWireValue); put("acceptedRole", acceptedRole?.legacyWireValue)
        put("projectionMode", projection?.rawValue)
        if let caps { value["caps"] = caps.foundationObject }
        put("ephPub", enrollmentKey?.base64EncodedString()); put("nonce", challenge?.base64EncodedString())
        put("needsPairing", needsPairing)
        return value
    }
}

private extension PortableSessionHelloCaps {
    var foundationObject: [String: Any] {
        var value: [String: Any] = ["codecs": [
            codecs & UInt32(SC_SESSION_HELLO_CODEC_H264_V1) != 0 ? "h264" : nil,
            codecs & UInt32(SC_SESSION_HELLO_CODEC_HEVC_V1) != 0 ? "hevc" : nil,
        ].compactMap { $0 }]
        func put(_ key: String, _ item: Any?) { if let item { value[key] = item } }
        put("maxWidth", maxWidth.map { Int($0) }); put("maxHeight", maxHeight.map { Int($0) })
        put("screenWidth", screenWidth.map { Int($0) }); put("screenHeight", screenHeight.map { Int($0) })
        put("scale", scale); put("refreshRate", refreshRate.map { Int($0) }); put("refreshRateMax", refreshRateMax.map { Int($0) })
        put("hidpi", hidpi); put("pen", pen)
        if hdrHLG != nil || hdrPQ != nil { value["hdr"] = ["hlg": hdrHLG ?? false, "pq": hdrPQ ?? false] }
        return value
    }
}

public enum PortableSessionHelloWireCodec {
    public static func encode(_ message: PortableSessionHelloMessage) throws -> Data {
        var value = ScSessionHelloWireV1()
        value.struct_size = UInt32(MemoryLayout<ScSessionHelloWireV1>.size)
        value.api_version = UInt32(SC_API_VERSION_V1)
        value.kind = UInt32(message.kind == .hello ? SC_SESSION_HELLO_KIND_HELLO_V1 : SC_SESSION_HELLO_KIND_HELLO_ACK_V1)
        value.protocol_version = message.protocolVersion
        value.auth_version = message.authVersion ?? 0; value.record_version = message.recordVersion ?? 0
        value.capability_version = message.capabilityVersion ?? 0; value.capability_intent_version = message.capabilityIntentVersion ?? 0
        value.frame_meta_version = message.frameMetaVersion ?? 0; value.media_recovery_version = message.mediaRecoveryVersion ?? 0
        value.udp_video_version = message.udpVideoVersion ?? 0; value.udp_video_port = message.udpVideoPort ?? 0
        value.supported_roles = roleBits(message.supportedRoles); value.desired_role = role(message.desiredRole)
        value.accepted_role = role(message.acceptedRole); value.projection = projection(message.projection)
        try setText(message.legacyRole, in: &value.legacy_role); try setText(message.peerID, in: &value.peer_id)
        try setText(message.platform, in: &value.platform); try setText(message.deviceName, in: &value.device_name)
        try setText(message.appVersion, in: &value.app_version); try setText(message.pairingToken, in: &value.pairing_token)
        if let caps = message.caps { value.presence |= UInt64(SC_SESSION_HELLO_FIELD_CAPS_V1); set(caps, in: &value) }
        if let key = message.enrollmentKey { value.presence |= UInt64(SC_SESSION_HELLO_FIELD_ENROLLMENT_KEY_V1); try copy(key, count: 65, into: &value.enrollment_key) }
        if let challenge = message.challenge { value.presence |= UInt64(SC_SESSION_HELLO_FIELD_CHALLENGE_V1); try copy(challenge, count: 32, into: &value.challenge) }
        if let pairing = message.needsPairing { value.presence |= UInt64(SC_SESSION_HELLO_FIELD_NEEDS_PAIRING_V1); value.needs_pairing = pairing ? 1 : 0 }
        var needed = 0
        guard sc_session_hello_wire_encode_v1(&value, nil, 0, &needed) == SC_BUFFER_TOO_SMALL, needed > 0 else { throw PortableSessionHelloWireError.invalid }
        var output = Data(count: needed); let capacity = needed
        let status = output.withUnsafeMutableBytes { bytes in sc_session_hello_wire_encode_v1(&value, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &needed) }
        guard status == SC_OK, needed == capacity else { throw PortableSessionHelloWireError.invalid }
        return output
    }

    public static func decode(_ input: Data) throws -> PortableSessionHelloMessage {
        var value = ScSessionHelloWireV1(); value.struct_size = UInt32(MemoryLayout<ScSessionHelloWireV1>.size); value.api_version = UInt32(SC_API_VERSION_V1)
        let status = input.withUnsafeBytes { bytes in sc_session_hello_wire_decode_v1(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &value) }
        guard status == SC_OK, let legacy = text(value.legacy_role), let peer = text(value.peer_id) else { throw PortableSessionHelloWireError.invalid }
        let kind: PortableSessionHelloKind = value.kind == UInt32(SC_SESSION_HELLO_KIND_HELLO_V1) ? .hello : .helloAck
        var output = PortableSessionHelloMessage(kind: kind, legacyRole: legacy, peerID: peer)
        output.protocolVersion = value.protocol_version; output.authVersion = optional(value.auth_version); output.recordVersion = optional(value.record_version)
        output.capabilityVersion = optional(value.capability_version); output.capabilityIntentVersion = optional(value.capability_intent_version)
        output.frameMetaVersion = optional(value.frame_meta_version); output.mediaRecoveryVersion = optional(value.media_recovery_version)
        output.udpVideoVersion = optional(value.udp_video_version); output.udpVideoPort = optional(value.udp_video_port)
        output.platform = text(value.platform); output.deviceName = text(value.device_name); output.appVersion = text(value.app_version); output.pairingToken = text(value.pairing_token)
        output.supportedRoles = roles(value.supported_roles); output.desiredRole = role(value.desired_role); output.acceptedRole = role(value.accepted_role)
        output.projection = projection(value.projection)
        if value.presence & UInt64(SC_SESSION_HELLO_FIELD_CAPS_V1) != 0 { output.caps = caps(value) }
        if value.presence & UInt64(SC_SESSION_HELLO_FIELD_ENROLLMENT_KEY_V1) != 0 { output.enrollmentKey = data(value.enrollment_key) }
        if value.presence & UInt64(SC_SESSION_HELLO_FIELD_CHALLENGE_V1) != 0 { output.challenge = data(value.challenge) }
        if value.presence & UInt64(SC_SESSION_HELLO_FIELD_NEEDS_PAIRING_V1) != 0 { output.needsPairing = value.needs_pairing == 1 }
        return output
    }

    private static func optional(_ value: UInt16) -> UInt16? { value == 0 ? nil : value }
    private static func role(_ value: MediaRole?) -> UInt32 { value == .source ? UInt32(SC_SESSION_HELLO_ROLE_SOURCE_V1) : value == .sink ? UInt32(SC_SESSION_HELLO_ROLE_RECEIVER_V1) : 0 }
    private static func role(_ value: UInt32) -> MediaRole? { value == UInt32(SC_SESSION_HELLO_ROLE_SOURCE_V1) ? .source : value == UInt32(SC_SESSION_HELLO_ROLE_RECEIVER_V1) ? .sink : nil }
    private static func roleBits(_ roles: Set<MediaRole>) -> UInt32 { roles.reduce(0) { $0 | role($1) } }
    private static func roles(_ bits: UInt32) -> Set<MediaRole> { Set([bits & 1 != 0 ? .source : nil, bits & 2 != 0 ? .sink : nil].compactMap { $0 }) }
    private static func projection(_ value: ProjectionMode?) -> UInt32 { switch value { case .extend: UInt32(SC_SESSION_HELLO_PROJECTION_EXTEND_V1); case .mirror: UInt32(SC_SESSION_HELLO_PROJECTION_MIRROR_V1); case .primary: UInt32(SC_SESSION_HELLO_PROJECTION_PRIMARY_V1); case nil: 0 } }
    private static func projection(_ value: UInt32) -> ProjectionMode? { switch Int(value) { case SC_SESSION_HELLO_PROJECTION_EXTEND_V1: .extend; case SC_SESSION_HELLO_PROJECTION_MIRROR_V1: .mirror; case SC_SESSION_HELLO_PROJECTION_PRIMARY_V1: .primary; default: nil } }

    private static func set(_ caps: PortableSessionHelloCaps, in value: inout ScSessionHelloWireV1) {
        value.codecs = caps.codecs
        func number(_ bit: Int, _ input: UInt32?, _ output: WritableKeyPath<ScSessionHelloWireV1, UInt32>) { if let input { value.caps_presence |= UInt32(bit); value[keyPath: output] = input } }
        number(SC_SESSION_HELLO_CAP_MAX_WIDTH_V1, caps.maxWidth, \.max_width); number(SC_SESSION_HELLO_CAP_MAX_HEIGHT_V1, caps.maxHeight, \.max_height)
        number(SC_SESSION_HELLO_CAP_SCREEN_WIDTH_V1, caps.screenWidth, \.screen_width); number(SC_SESSION_HELLO_CAP_SCREEN_HEIGHT_V1, caps.screenHeight, \.screen_height)
        number(SC_SESSION_HELLO_CAP_REFRESH_RATE_V1, caps.refreshRate, \.refresh_rate); number(SC_SESSION_HELLO_CAP_REFRESH_RATE_MAX_V1, caps.refreshRateMax, \.refresh_rate_max)
        if let scale = caps.scale { value.caps_presence |= UInt32(SC_SESSION_HELLO_CAP_SCALE_V1); value.scale = scale }
        func flag(_ bit: Int, _ valueBit: Int, _ input: Bool?) { if let input { value.caps_presence |= UInt32(bit); if input { value.caps_values |= UInt32(valueBit) } } }
        flag(SC_SESSION_HELLO_CAP_HIDPI_V1, SC_SESSION_HELLO_CAP_VALUE_HIDPI_V1, caps.hidpi); flag(SC_SESSION_HELLO_CAP_PEN_V1, SC_SESSION_HELLO_CAP_VALUE_PEN_V1, caps.pen)
        flag(SC_SESSION_HELLO_CAP_HDR_HLG_V1, SC_SESSION_HELLO_CAP_VALUE_HDR_HLG_V1, caps.hdrHLG); flag(SC_SESSION_HELLO_CAP_HDR_PQ_V1, SC_SESSION_HELLO_CAP_VALUE_HDR_PQ_V1, caps.hdrPQ)
    }

    private static func caps(_ value: ScSessionHelloWireV1) -> PortableSessionHelloCaps {
        var output = PortableSessionHelloCaps(); output.codecs = value.codecs
        func number(_ bit: Int, _ input: UInt32) -> UInt32? { value.caps_presence & UInt32(bit) != 0 ? input : nil }
        output.maxWidth = number(SC_SESSION_HELLO_CAP_MAX_WIDTH_V1, value.max_width); output.maxHeight = number(SC_SESSION_HELLO_CAP_MAX_HEIGHT_V1, value.max_height)
        output.screenWidth = number(SC_SESSION_HELLO_CAP_SCREEN_WIDTH_V1, value.screen_width); output.screenHeight = number(SC_SESSION_HELLO_CAP_SCREEN_HEIGHT_V1, value.screen_height)
        output.refreshRate = number(SC_SESSION_HELLO_CAP_REFRESH_RATE_V1, value.refresh_rate); output.refreshRateMax = number(SC_SESSION_HELLO_CAP_REFRESH_RATE_MAX_V1, value.refresh_rate_max)
        output.scale = value.caps_presence & UInt32(SC_SESSION_HELLO_CAP_SCALE_V1) != 0 ? value.scale : nil
        func flag(_ bit: Int, _ valueBit: Int) -> Bool? { value.caps_presence & UInt32(bit) != 0 ? value.caps_values & UInt32(valueBit) != 0 : nil }
        output.hidpi = flag(SC_SESSION_HELLO_CAP_HIDPI_V1, SC_SESSION_HELLO_CAP_VALUE_HIDPI_V1); output.pen = flag(SC_SESSION_HELLO_CAP_PEN_V1, SC_SESSION_HELLO_CAP_VALUE_PEN_V1)
        output.hdrHLG = flag(SC_SESSION_HELLO_CAP_HDR_HLG_V1, SC_SESSION_HELLO_CAP_VALUE_HDR_HLG_V1); output.hdrPQ = flag(SC_SESSION_HELLO_CAP_HDR_PQ_V1, SC_SESSION_HELLO_CAP_VALUE_HDR_PQ_V1)
        return output
    }

    private static func setText(_ string: String?, in value: inout ScSessionHelloTextV1) throws { guard let string else { return }; let bytes = Data(string.utf8); guard bytes.count <= 128 else { throw PortableSessionHelloWireError.invalid }; value.length = UInt32(bytes.count); _ = withUnsafeMutableBytes(of: &value.bytes) { bytes.copyBytes(to: $0) } }
    private static func text(_ value: ScSessionHelloTextV1) -> String? { guard value.length > 0, value.length <= 128 else { return nil }; var bytes = value.bytes; return withUnsafeBytes(of: &bytes) { String(data: Data($0.prefix(Int(value.length))), encoding: .utf8) } }
    private static func copy<T>(_ data: Data, count: Int, into value: inout T) throws { guard data.count == count else { throw PortableSessionHelloWireError.invalid }; _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0) } }
    private static func data<T>(_ value: T) -> Data { var value = value; return withUnsafeBytes(of: &value) { Data($0) } }
}

public enum PortableSessionHelloWireError: Error { case invalid }
