import Foundation
import SuperconnectCoreFFI

extension PortableSecureConnectionRuntime {
    public func sealFrame(channel: UInt8, flags: UInt8, plaintext: Data) throws -> Data {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        var needed = 0
        let query = plaintext.withUnsafeBytes { input in
            sc_secure_connection_seal_frame_v1(
                handle, channel, flags, input.bindMemory(to: UInt8.self).baseAddress,
                input.count, nil, 0, &needed)
        }
        guard query == SC_BUFFER_TOO_SMALL, needed >= 6 else { throw Self.failure(query) }
        var output = Data(count: needed)
        let status = plaintext.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                sc_secure_connection_seal_frame_v1(
                    handle, channel, flags, input.bindMemory(to: UInt8.self).baseAddress,
                    input.count, destination.bindMemory(to: UInt8.self).baseAddress,
                    destination.count, &needed)
            }
        }
        guard status == SC_OK, needed == output.count else { throw Self.failure(status) }
        return output
    }

    public func push(_ bytes: Data) throws -> [PortableSecureInboundFrame] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        let status = bytes.withUnsafeBytes { input in
            sc_secure_connection_push_v1(
                handle, input.bindMemory(to: UInt8.self).baseAddress, input.count)
        }
        guard status == SC_OK else { throw Self.failure(status) }
        return try takeOneInbound()
    }

    /// Ask Core to expose the next frame that was coalesced into a previous socket read. The
    /// explicit NULL/zero call is a state barrier: callers must route the prior frame and complete
    /// every typed effect before invoking this method. Core deliberately exposes at most one frame
    /// per call so a transition (auth/capability) cannot be crossed by a later record in one batch.
    public func pushBuffered() throws -> [PortableSecureInboundFrame] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        let status = sc_secure_connection_push_v1(handle, nil, 0)
        guard status == SC_OK else { throw Self.failure(status) }
        return try takeOneInbound()
    }

    private func takeOneInbound() throws -> [PortableSecureInboundFrame] {
        guard let handle else { throw PortableSecureConnectionError.coreUnavailable }
        var result = [PortableSecureInboundFrame]()
        var view = ScSecureInboundViewV1()
        view.struct_size = UInt32(MemoryLayout<ScSecureInboundViewV1>.size)
        view.api_version = UInt32(SC_API_VERSION_V1)
        let next = sc_secure_connection_next_inbound_v1(handle, &view)
        if next == SC_NO_FRAME { return result }
        guard next == SC_OK, view.generation != 0 else {
            throw PortableSecureConnectionError.malformedInbound
        }
        var consumed = false
        defer {
            if !consumed {
                precondition(
                    sc_secure_connection_consume_inbound_v1(handle, view.generation) == SC_OK)
            }
        }
        guard view.control_present <= 1,
              view.reserved0 == 0, view.reserved1 == 0, view.reserved2 == 0,
              view.payload_length == 0 || view.payload != nil else {
            throw PortableSecureConnectionError.malformedInbound
        }
        let payload = view.payload_length == 0
            ? Data()
            : Data(bytes: view.payload!, count: view.payload_length)
        let controlView = view
        precondition(
            sc_secure_connection_consume_inbound_v1(handle, view.generation) == SC_OK)
        consumed = true
        guard try snapshot().pendingInboundCount == 0 else {
            throw PortableSecureConnectionError.inboundBatchViolation
        }
        let control = try decodeControl(controlView)
        result.append(.init(
            frame: Frame(channel: view.channel, flags: view.flags, payload: payload),
            control: control))
        return result
    }
}

private extension PortableSecureConnectionRuntime {
    func decodeControl(_ view: ScSecureInboundViewV1) throws -> PortableControlEnvelope? {
        guard (view.channel == Channel.control.rawValue) == (view.control_present == 1) else {
            throw PortableSecureConnectionError.malformedInbound
        }
        guard view.control_present == 1 else { return nil }
        let value = view.control
        guard value.struct_size == UInt32(MemoryLayout<ScControlEnvelopeV1>.size),
              value.api_version == UInt32(SC_API_VERSION_V1),
              value.reserved0 == 0, value.reserved1 == 0 else {
            throw PortableSecureConnectionError.malformedInbound
        }
        return .init(
            kind: value.kind, presence: value.presence, generation: value.generation,
            operation: value.operation, value0: value.value0, value1: value.value1,
            detail: value.detail)
    }
}
