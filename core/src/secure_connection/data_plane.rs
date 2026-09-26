use crate::control_envelope::decode_control_envelope_v1;
use crate::control_envelope_types_generated::{
    SC_CONTROL_KIND_AUTH_ACK_V1, SC_CONTROL_KIND_AUTH_V1, SC_CONTROL_KIND_BYE_V1,
    SC_CONTROL_KIND_ERROR_V1, SC_CONTROL_KIND_HELLO_ACK_V1, SC_CONTROL_KIND_HELLO_V1,
    SC_CONTROL_KIND_PAIR_SECRET_V1,
};
use crate::session::SessionPhase;
use crate::wire::encode_frame;
use crate::wire::MAX_FRAME_PAYLOAD;
use zeroize::Zeroizing;

use super::record_layer::record_type;
use super::{ScSecureConnection, SecureConnectionError, SecureInboundFrame, SecureRecordPhase};

impl ScSecureConnection {
    pub fn sealed_frame_length(
        &self,
        channel: u8,
        plaintext_length: usize,
    ) -> Result<usize, SecureConnectionError> {
        if plaintext_length > MAX_FRAME_PAYLOAD {
            return Err(SecureConnectionError::FrameRejected);
        }
        if self.data_plane_closed() && self.plaintext_forbidden {
            return Err(SecureConnectionError::RecordsNotActive);
        }
        if channel != 0
            && !matches!(
                self.session.phase(),
                SessionPhase::Ready | SessionPhase::Streaming
            )
        {
            let error = if self.record_phase == SecureRecordPhase::Active {
                SecureConnectionError::RecordRejected
            } else {
                SecureConnectionError::RecordsNotActive
            };
            return Err(error);
        }
        if self.record_phase == SecureRecordPhase::Active {
            let _ = record_type(channel)?;
            let layer = self
                .records
                .as_ref()
                .ok_or(SecureConnectionError::RecordsNotActive)?;
            return layer
                .sealer
                .required_length(plaintext_length)
                .map_err(|_| SecureConnectionError::RecordRejected)?
                .checked_add(6)
                .ok_or(SecureConnectionError::FrameRejected);
        }
        if self.records_required()
            && (self.plaintext_forbidden
                || channel != 0
                || self.session.phase() == SessionPhase::CapabilityCommit)
        {
            return Err(SecureConnectionError::RecordsNotActive);
        }
        plaintext_length
            .checked_add(6)
            .ok_or(SecureConnectionError::FrameRejected)
    }

    pub fn seal_outbound(
        &mut self,
        channel: u8,
        flags: u8,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, SecureConnectionError> {
        if self.data_plane_closed() && (self.plaintext_forbidden || channel != 0) {
            return Err(SecureConnectionError::RecordsNotActive);
        }
        if channel != 0
            && !matches!(
                self.session.phase(),
                SessionPhase::Ready | SessionPhase::Streaming
            )
        {
            let error = if self.record_phase == SecureRecordPhase::Active {
                SecureConnectionError::RecordRejected
            } else {
                SecureConnectionError::RecordsNotActive
            };
            return Err(error);
        }
        if self.record_phase == SecureRecordPhase::Active {
            let record_type = record_type(channel)?;
            if self.records.is_none() {
                return Err(SecureConnectionError::RecordsNotActive);
            }
            let layer = self.records.as_mut().unwrap();
            let (_, record) = layer
                .sealer
                .seal(record_type, flags, plaintext)
                .map_err(|_| self.fail_data(SecureConnectionError::RecordRejected))?;
            let mut frame = vec![0; record.len() + 6];
            encode_frame(channel, 0, &record, &mut frame)
                .map_err(|_| self.fail_data(SecureConnectionError::FrameRejected))?;
            return Ok(frame);
        }
        if self.data_plane_closed() {
            let control = decode_control_envelope_v1(plaintext)
                .map_err(|_| SecureConnectionError::ControlRejected)?;
            if control.kind != SC_CONTROL_KIND_ERROR_V1 {
                return Err(SecureConnectionError::RecordsNotActive);
            }
        }
        if self.records_required() && self.record_phase != SecureRecordPhase::Active {
            if self.plaintext_forbidden
                || channel != 0
                || self.session.phase() == SessionPhase::CapabilityCommit
            {
                return Err(SecureConnectionError::RecordsNotActive);
            }
            let control = decode_control_envelope_v1(plaintext)
                .map_err(|_| SecureConnectionError::ControlRejected)?;
            let allowed = if self.data_plane_closed() {
                control.kind == SC_CONTROL_KIND_ERROR_V1
            } else {
                pre_record_plaintext_control(control.kind)
            };
            if !allowed {
                return Err(SecureConnectionError::RecordsNotActive);
            }
        }
        let mut frame = vec![0; plaintext.len() + 6];
        encode_frame(channel, flags, plaintext, &mut frame)
            .map_err(|_| SecureConnectionError::FrameRejected)?;
        Ok(frame)
    }

    pub fn push_inbound(
        &mut self,
        bytes: &[u8],
    ) -> Result<Vec<SecureInboundFrame>, SecureConnectionError> {
        if self.data_plane_closed() {
            return Err(self.fail_data(SecureConnectionError::PlaintextDowngrade));
        }
        self.decoder
            .push(bytes)
            .map_err(|_| self.fail_data(SecureConnectionError::FrameRejected))?;
        let mut output = Vec::new();
        if let Some(meta) = self
            .decoder
            .peek()
            .map_err(|_| self.fail_data(SecureConnectionError::FrameRejected))?
        {
            let payload = unsafe {
                core::slice::from_raw_parts(self.decoder.payload_ptr(meta), meta.payload_length)
            }
            .to_vec();
            self.decoder
                .consume(meta.generation)
                .map_err(|_| self.fail_data(SecureConnectionError::FrameRejected))?;
            let (flags, payload) = self.open_inbound(meta.channel, meta.flags, payload)?;
            let mut payload = Zeroizing::new(payload);
            let control = if meta.channel == 0 {
                let control = decode_control_envelope_v1(&payload)
                    .map_err(|_| self.fail_data(SecureConnectionError::ControlRejected))?;
                if self.records_required()
                    && self.record_phase != SecureRecordPhase::Active
                    && (self.record_phase == SecureRecordPhase::Disposed
                        || !pre_record_plaintext_control(control.kind))
                {
                    return Err(self.fail_data(SecureConnectionError::PlaintextDowngrade));
                }
                Some(control)
            } else {
                None
            };
            output.push(SecureInboundFrame {
                channel: meta.channel,
                flags,
                payload: core::mem::take(&mut *payload),
                control,
            });
        }
        Ok(output)
    }

    fn open_inbound(
        &mut self,
        channel: u8,
        outer_flags: u8,
        payload: Vec<u8>,
    ) -> Result<(u8, Vec<u8>), SecureConnectionError> {
        let mut payload = Zeroizing::new(payload);
        if self.record_phase == SecureRecordPhase::Active {
            if outer_flags != 0 {
                return Err(self.fail_data(SecureConnectionError::PlaintextDowngrade));
            }
            let expected = record_type(channel).map_err(|error| self.fail_data(error))?;
            if self.records.is_none() {
                return Err(self.fail_data(SecureConnectionError::RecordsNotActive));
            }
            let layer = self.records.as_mut().unwrap();
            let record_error = if payload.starts_with(b"SCR1") {
                SecureConnectionError::RecordRejected
            } else {
                SecureConnectionError::PlaintextDowngrade
            };
            let (metadata, plaintext) = layer
                .opener
                .open(&payload)
                .map_err(|_| self.fail_data(record_error))?;
            if metadata.record_type != expected {
                return Err(self.fail_data(SecureConnectionError::RecordRejected));
            }
            if channel != 0
                && !matches!(
                    self.session.phase(),
                    SessionPhase::Ready | SessionPhase::Streaming
                )
            {
                return Err(self.fail_data(SecureConnectionError::RecordRejected));
            }
            return Ok((metadata.flags, plaintext));
        }
        if channel != 0
            && !matches!(
                self.session.phase(),
                SessionPhase::Ready | SessionPhase::Streaming
            )
        {
            return Err(self.fail_data(SecureConnectionError::RecordsNotActive));
        }
        if self.records_required()
            && (self.plaintext_forbidden
                || channel != 0
                || self.session.phase() == SessionPhase::CapabilityCommit
                || matches!(
                    self.session.phase(),
                    SessionPhase::Ready | SessionPhase::Streaming
                ))
        {
            return Err(self.fail_data(SecureConnectionError::PlaintextDowngrade));
        }
        Ok((outer_flags, core::mem::take(&mut *payload)))
    }

    fn data_plane_closed(&self) -> bool {
        self.record_phase == SecureRecordPhase::Disposed
            || matches!(
                self.session.phase(),
                SessionPhase::Closing | SessionPhase::Closed | SessionPhase::Fatal
            )
    }
}

fn pre_record_plaintext_control(kind: u32) -> bool {
    matches!(
        kind,
        SC_CONTROL_KIND_HELLO_V1
            | SC_CONTROL_KIND_HELLO_ACK_V1
            | SC_CONTROL_KIND_AUTH_V1
            | SC_CONTROL_KIND_AUTH_ACK_V1
            | SC_CONTROL_KIND_PAIR_SECRET_V1
            | SC_CONTROL_KIND_BYE_V1
            | SC_CONTROL_KIND_ERROR_V1
    )
}
