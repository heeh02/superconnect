use std::mem::size_of;

use crate::session::{
    BoundedPeerIdentity, OperationId, SessionEffect, SessionFatalReason, TimerToken,
};

use super::super::SC_API_VERSION_V1;
use super::decode::encode_identity;
use super::types::*;

fn effect_base(effect_type: u32) -> ScSessionEffectV1 {
    ScSessionEffectV1 {
        struct_size: size_of::<ScSessionEffectV1>() as u32,
        api_version: SC_API_VERSION_V1,
        effect_type,
        ..ScSessionEffectV1::default()
    }
}

fn with_operation_effect(effect_type: u32, operation: OperationId) -> ScSessionEffectV1 {
    ScSessionEffectV1 {
        presence: SC_SESSION_FIELD_OPERATION,
        operation: operation.get(),
        ..effect_base(effect_type)
    }
}

fn with_timer_effect(effect_type: u32, token: TimerToken) -> ScSessionEffectV1 {
    ScSessionEffectV1 {
        presence: SC_SESSION_FIELD_TIMER_TOKEN,
        timer_token: token.get(),
        ..effect_base(effect_type)
    }
}

fn with_peer_operation_effect(
    effect_type: u32,
    operation: OperationId,
    peer: BoundedPeerIdentity,
) -> ScSessionEffectV1 {
    ScSessionEffectV1 {
        presence: SC_SESSION_FIELD_OPERATION | SC_SESSION_FIELD_IDENTITY,
        operation: operation.get(),
        identity: encode_identity(peer),
        ..effect_base(effect_type)
    }
}

fn fatal_value(reason: SessionFatalReason) -> u32 {
    match reason {
        SessionFatalReason::AuthenticationRequired => SC_SESSION_FATAL_AUTHENTICATION_REQUIRED,
        SessionFatalReason::AuthenticationFailed => SC_SESSION_FATAL_AUTHENTICATION_FAILED,
        SessionFatalReason::UnexpectedReenrollment => SC_SESSION_FATAL_UNEXPECTED_REENROLLMENT,
        SessionFatalReason::CredentialUnavailable => SC_SESSION_FATAL_CREDENTIAL_UNAVAILABLE,
        SessionFatalReason::CapabilityCommitFailed => SC_SESSION_FATAL_CAPABILITY_COMMIT_FAILED,
        SessionFatalReason::AdmissionRejected => SC_SESSION_FATAL_ADMISSION_REJECTED,
        SessionFatalReason::HandshakeTimedOut => SC_SESSION_FATAL_HANDSHAKE_TIMED_OUT,
        SessionFatalReason::IdentifierSpaceExhausted => SC_SESSION_FATAL_IDENTIFIER_SPACE_EXHAUSTED,
        SessionFatalReason::TransportFailed => SC_SESSION_FATAL_TRANSPORT_FAILED,
        SessionFatalReason::FinalAckFailed => SC_SESSION_FATAL_FINAL_ACK_FAILED,
        SessionFatalReason::PairingRejected => SC_SESSION_FATAL_PAIRING_REJECTED,
        SessionFatalReason::ProtocolViolation => SC_SESSION_FATAL_PROTOCOL_VIOLATION,
    }
}

pub(crate) fn encode_effect(effect: SessionEffect) -> ScSessionEffectV1 {
    match effect {
        SessionEffect::OpenTransport { operation } => {
            with_operation_effect(SC_SESSION_EFFECT_OPEN_TRANSPORT, operation)
        }
        SessionEffect::ArmHandshakeTimer { token } => {
            with_timer_effect(SC_SESSION_EFFECT_ARM_HANDSHAKE_TIMER, token)
        }
        SessionEffect::CancelHandshakeTimer { token } => {
            with_timer_effect(SC_SESSION_EFFECT_CANCEL_HANDSHAKE_TIMER, token)
        }
        SessionEffect::SendHello {
            generation,
            identity,
            media_role,
            auth_version,
            local_enrollment_key,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_GENERATION
                | SC_SESSION_FIELD_IDENTITY
                | SC_SESSION_FIELD_AUTH_VERSION
                | SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY,
            generation: generation.get(),
            local_enrollment_key: local_enrollment_key.get(),
            auth_version,
            media_role: media_role as u8,
            identity: encode_identity(identity),
            ..effect_base(SC_SESSION_EFFECT_SEND_HELLO)
        },
        SessionEffect::LoadCredential { operation, peer } => {
            with_peer_operation_effect(SC_SESSION_EFFECT_LOAD_CREDENTIAL, operation, peer)
        }
        SessionEffect::OpenEnrollment {
            operation,
            peer,
            local_enrollment_key,
            peer_enrollment_key,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_IDENTITY
                | SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY
                | SC_SESSION_FIELD_PEER_ENROLLMENT_KEY,
            operation: operation.get(),
            local_enrollment_key: local_enrollment_key.get(),
            peer_enrollment_key: peer_enrollment_key.get(),
            identity: encode_identity(peer),
            ..effect_base(SC_SESSION_EFFECT_OPEN_ENROLLMENT)
        },
        SessionEffect::RequestEnrollmentApproval {
            operation,
            peer,
            peer_enrollment_key,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_IDENTITY
                | SC_SESSION_FIELD_PEER_ENROLLMENT_KEY,
            operation: operation.get(),
            peer_enrollment_key: peer_enrollment_key.get(),
            identity: encode_identity(peer),
            ..effect_base(SC_SESSION_EFFECT_REQUEST_ENROLLMENT_APPROVAL)
        },
        SessionEffect::PrepareEnrollment {
            operation,
            peer,
            local_enrollment_key,
            peer_enrollment_key,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_IDENTITY
                | SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY
                | SC_SESSION_FIELD_PEER_ENROLLMENT_KEY,
            operation: operation.get(),
            local_enrollment_key: local_enrollment_key.get(),
            peer_enrollment_key: peer_enrollment_key.get(),
            identity: encode_identity(peer),
            ..effect_base(SC_SESSION_EFFECT_PREPARE_ENROLLMENT)
        },
        SessionEffect::GenerateChallenge { operation } => {
            with_operation_effect(SC_SESSION_EFFECT_GENERATE_CHALLENGE, operation)
        }
        SessionEffect::SendHelloAck {
            generation,
            identity,
            media_role,
            auth_version,
            challenge,
            enrollment,
            local_enrollment_key,
        } => {
            let mut output = ScSessionEffectV1 {
                presence: SC_SESSION_FIELD_GENERATION | SC_SESSION_FIELD_IDENTITY,
                generation: generation.get(),
                media_role: media_role as u8,
                enrollment: u8::from(enrollment),
                identity: encode_identity(identity),
                ..effect_base(SC_SESSION_EFFECT_SEND_HELLO_ACK)
            };
            if let Some(auth_version) = auth_version {
                output.presence |= SC_SESSION_FIELD_AUTH_VERSION;
                output.auth_version = auth_version;
            }
            if let Some(challenge) = challenge {
                output.presence |= SC_SESSION_FIELD_CHALLENGE;
                output.challenge = challenge.get();
            }
            if let Some(local_enrollment_key) = local_enrollment_key {
                output.presence |= SC_SESSION_FIELD_LOCAL_ENROLLMENT_KEY;
                output.local_enrollment_key = local_enrollment_key.get();
            }
            output
        }
        SessionEffect::SendEnrollment { envelope } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_ENVELOPE,
            envelope: envelope.get(),
            ..effect_base(SC_SESSION_EFFECT_SEND_ENROLLMENT)
        },
        SessionEffect::CreateAuthProof {
            operation,
            credential,
            challenge,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_CREDENTIAL
                | SC_SESSION_FIELD_CHALLENGE,
            operation: operation.get(),
            credential: credential.get(),
            challenge: challenge.get(),
            ..effect_base(SC_SESSION_EFFECT_CREATE_AUTH_PROOF)
        },
        SessionEffect::VerifyPeerProof {
            operation,
            credential,
            challenge,
            proof,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_CREDENTIAL
                | SC_SESSION_FIELD_CHALLENGE
                | SC_SESSION_FIELD_PROOF,
            operation: operation.get(),
            credential: credential.get(),
            challenge: challenge.get(),
            proof: proof.get(),
            ..effect_base(SC_SESSION_EFFECT_VERIFY_PEER_PROOF)
        },
        SessionEffect::ClaimAdmission { operation, peer } => {
            with_peer_operation_effect(SC_SESSION_EFFECT_CLAIM_ADMISSION, operation, peer)
        }
        SessionEffect::CreateMutualProof {
            operation,
            credential,
            challenge,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_CREDENTIAL
                | SC_SESSION_FIELD_CHALLENGE,
            operation: operation.get(),
            credential: credential.get(),
            challenge: challenge.get(),
            ..effect_base(SC_SESSION_EFFECT_CREATE_MUTUAL_PROOF)
        },
        SessionEffect::SubmitFinalAuthAck { operation, proof } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION | SC_SESSION_FIELD_PROOF,
            operation: operation.get(),
            proof: proof.get(),
            ..effect_base(SC_SESSION_EFFECT_SUBMIT_FINAL_AUTH_ACK)
        },
        SessionEffect::SubmitFinalHelloAck {
            operation,
            generation,
            identity,
            media_role,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_GENERATION
                | SC_SESSION_FIELD_IDENTITY,
            generation: generation.get(),
            operation: operation.get(),
            media_role: media_role as u8,
            identity: encode_identity(identity),
            ..effect_base(SC_SESSION_EFFECT_SUBMIT_FINAL_HELLO_ACK)
        },
        SessionEffect::SendAuth { proof, challenge } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_PROOF | SC_SESSION_FIELD_CHALLENGE,
            challenge: challenge.get(),
            proof: proof.get(),
            ..effect_base(SC_SESSION_EFFECT_SEND_AUTH)
        },
        SessionEffect::VerifyMutualProof {
            operation,
            credential,
            challenge,
            proof,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_CREDENTIAL
                | SC_SESSION_FIELD_CHALLENGE
                | SC_SESSION_FIELD_PROOF,
            operation: operation.get(),
            credential: credential.get(),
            challenge: challenge.get(),
            proof: proof.get(),
            ..effect_base(SC_SESSION_EFFECT_VERIFY_MUTUAL_PROOF)
        },
        SessionEffect::WriteCredential {
            operation,
            peer,
            credential,
        } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_OPERATION
                | SC_SESSION_FIELD_IDENTITY
                | SC_SESSION_FIELD_CREDENTIAL,
            operation: operation.get(),
            credential: credential.get(),
            identity: encode_identity(peer),
            ..effect_base(SC_SESSION_EFFECT_WRITE_CREDENTIAL)
        },
        SessionEffect::CancelCredentialWrite { operation } => {
            with_operation_effect(SC_SESSION_EFFECT_CANCEL_CREDENTIAL_WRITE, operation)
        }
        SessionEffect::CommitCapabilities {
            operation,
            peer,
            media_role,
        } => ScSessionEffectV1 {
            media_role: media_role as u8,
            ..with_peer_operation_effect(SC_SESSION_EFFECT_COMMIT_CAPABILITIES, operation, peer)
        },
        SessionEffect::NotifyReady => effect_base(SC_SESSION_EFFECT_NOTIFY_READY),
        SessionEffect::NotifyStreaming => effect_base(SC_SESSION_EFFECT_NOTIFY_STREAMING),
        SessionEffect::CloseTransport => effect_base(SC_SESSION_EFFECT_CLOSE_TRANSPORT),
        SessionEffect::NotifyClosed => effect_base(SC_SESSION_EFFECT_NOTIFY_CLOSED),
        SessionEffect::ReleaseAdmission { claim } => ScSessionEffectV1 {
            presence: SC_SESSION_FIELD_ADMISSION_CLAIM,
            admission_claim: claim.get(),
            ..effect_base(SC_SESSION_EFFECT_RELEASE_ADMISSION)
        },
        SessionEffect::NotifyFatal(reason) => ScSessionEffectV1 {
            fatal_reason: fatal_value(reason),
            ..effect_base(SC_SESSION_EFFECT_NOTIFY_FATAL)
        },
    }
}
