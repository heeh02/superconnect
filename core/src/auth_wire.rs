use crate::json_wire::{FlatObjectParser, Scalar};
use core::fmt;
use zeroize::{Zeroize, Zeroizing};

pub const AUTH_WIRE_MAX_BYTES_V1: usize = 256;

#[derive(Clone, PartialEq, Eq)]
pub enum AuthWireMessageV1 {
    Auth {
        proof: [u8; 32],
        challenge: [u8; 32],
    },
    AuthAck {
        proof: [u8; 32],
    },
    PairSecret {
        sealed_secret: [u8; 48],
        pairing_salt: [u8; 16],
        aead_nonce: [u8; 12],
    },
}

impl fmt::Debug for AuthWireMessageV1 {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Auth { .. } => "AuthWireMessageV1::Auth(<redacted>)",
            Self::AuthAck { .. } => "AuthWireMessageV1::AuthAck(<redacted>)",
            Self::PairSecret { .. } => "AuthWireMessageV1::PairSecret(<redacted>)",
        })
    }
}

impl Zeroize for AuthWireMessageV1 {
    fn zeroize(&mut self) {
        match self {
            Self::Auth { proof, challenge } => {
                proof.zeroize();
                challenge.zeroize();
            }
            Self::AuthAck { proof } => proof.zeroize(),
            Self::PairSecret {
                sealed_secret,
                pairing_salt,
                aead_nonce,
            } => {
                sealed_secret.zeroize();
                pairing_salt.zeroize();
                aead_nonce.zeroize();
            }
        }
    }
}

impl Drop for AuthWireMessageV1 {
    fn drop(&mut self) {
        self.zeroize();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AuthWireErrorV1;

const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encode_base64(input: &[u8]) -> Zeroizing<String> {
    let mut output = Zeroizing::new(String::with_capacity(input.len().div_ceil(3) * 4));
    for chunk in input.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied().unwrap_or(0);
        let c = chunk.get(2).copied().unwrap_or(0);
        output.push(char::from(TABLE[usize::from(a >> 2)]));
        output.push(char::from(TABLE[usize::from(((a & 3) << 4) | (b >> 4))]));
        output.push(if chunk.len() > 1 {
            char::from(TABLE[usize::from(((b & 15) << 2) | (c >> 6))])
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            char::from(TABLE[usize::from(c & 63)])
        } else {
            '='
        });
    }
    output
}

fn sextet(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

fn decode_base64<const N: usize>(text: &str) -> Option<Zeroizing<[u8; N]>> {
    if text.len() != N.div_ceil(3) * 4 {
        return None;
    }
    let mut output = Zeroizing::new([0_u8; N]);
    let mut written = 0;
    let (chunks, remainder) = text.as_bytes().as_chunks::<4>();
    if !remainder.is_empty() {
        return None;
    }
    for chunk in chunks {
        let a = sextet(chunk[0])?;
        let b = sextet(chunk[1])?;
        if written < N {
            output[written] = (a << 2) | (b >> 4);
            written += 1;
        }
        if written < N {
            let c = sextet(chunk[2])?;
            output[written] = (b << 4) | (c >> 2);
            written += 1;
            if written < N {
                let d = sextet(chunk[3])?;
                output[written] = (c << 6) | d;
                written += 1;
            }
        }
    }
    let canonical = encode_base64(output.as_ref());
    (written == N && canonical.as_str() == text).then_some(output)
}

pub fn encode_auth_wire_v1(
    message: AuthWireMessageV1,
) -> Result<Zeroizing<String>, AuthWireErrorV1> {
    let mut output = Zeroizing::new(String::with_capacity(AUTH_WIRE_MAX_BYTES_V1));
    match &message {
        AuthWireMessageV1::Auth { proof, challenge } => {
            let proof = encode_base64(proof);
            let challenge = encode_base64(challenge);
            output.push_str("{\"type\":\"auth\",\"proof\":\"");
            output.push_str(proof.as_str());
            output.push_str("\",\"macNonce\":\"");
            output.push_str(challenge.as_str());
            output.push_str("\"}");
        }
        AuthWireMessageV1::AuthAck { proof } => {
            let proof = encode_base64(proof);
            output.push_str("{\"type\":\"auth_ack\",\"proof\":\"");
            output.push_str(proof.as_str());
            output.push_str("\"}");
        }
        AuthWireMessageV1::PairSecret {
            sealed_secret,
            pairing_salt,
            aead_nonce,
        } => {
            let sealed_secret = encode_base64(sealed_secret);
            let pairing_salt = encode_base64(pairing_salt);
            let aead_nonce = encode_base64(aead_nonce);
            output.push_str("{\"type\":\"pair_secret\",\"encSecret\":\"");
            output.push_str(sealed_secret.as_str());
            output.push_str("\",\"salt\":\"");
            output.push_str(pairing_salt.as_str());
            output.push_str("\",\"aeadNonce\":\"");
            output.push_str(aead_nonce.as_str());
            output.push_str("\"}");
        }
    }
    Ok(output)
}

pub fn decode_auth_wire_v1(input: &[u8]) -> Result<AuthWireMessageV1, AuthWireErrorV1> {
    if input.len() > AUTH_WIRE_MAX_BYTES_V1 {
        return Err(AuthWireErrorV1);
    }
    let text = core::str::from_utf8(input).map_err(|_| AuthWireErrorV1)?;
    let fields = FlatObjectParser::new(text)
        .parse()
        .map_err(|_| AuthWireErrorV1)?;
    let mut kind = None;
    let mut proof = None;
    let mut challenge = None;
    let mut sealed = None;
    let mut salt = None;
    let mut nonce = None;
    for (key, value) in fields {
        let Scalar::Text(value) = value else {
            return Err(AuthWireErrorV1);
        };
        let slot = match key {
            "type" => &mut kind,
            "proof" => &mut proof,
            "macNonce" => &mut challenge,
            "encSecret" => &mut sealed,
            "salt" => &mut salt,
            "aeadNonce" => &mut nonce,
            _ => return Err(AuthWireErrorV1),
        };
        if slot.replace(value).is_some() {
            return Err(AuthWireErrorV1);
        }
    }
    match kind.ok_or(AuthWireErrorV1)? {
        "auth" if sealed.is_none() && salt.is_none() && nonce.is_none() => {
            let proof = decode_base64(proof.ok_or(AuthWireErrorV1)?).ok_or(AuthWireErrorV1)?;
            let challenge =
                decode_base64(challenge.ok_or(AuthWireErrorV1)?).ok_or(AuthWireErrorV1)?;
            Ok(AuthWireMessageV1::Auth {
                proof: *proof,
                challenge: *challenge,
            })
        }
        "auth_ack"
            if challenge.is_none() && sealed.is_none() && salt.is_none() && nonce.is_none() =>
        {
            let proof = decode_base64(proof.ok_or(AuthWireErrorV1)?).ok_or(AuthWireErrorV1)?;
            Ok(AuthWireMessageV1::AuthAck { proof: *proof })
        }
        "pair_secret" if proof.is_none() && challenge.is_none() => {
            let sealed_secret =
                decode_base64(sealed.ok_or(AuthWireErrorV1)?).ok_or(AuthWireErrorV1)?;
            let pairing_salt =
                decode_base64(salt.ok_or(AuthWireErrorV1)?).ok_or(AuthWireErrorV1)?;
            let aead_nonce = decode_base64(nonce.ok_or(AuthWireErrorV1)?).ok_or(AuthWireErrorV1)?;
            Ok(AuthWireMessageV1::PairSecret {
                sealed_secret: *sealed_secret,
                pairing_salt: *pairing_salt,
                aead_nonce: *aead_nonce,
            })
        }
        _ => Err(AuthWireErrorV1),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_zeroize_clears_each_sensitive_variant_and_debug_is_redacted() {
        let mut auth = AuthWireMessageV1::Auth {
            proof: [0x51; 32],
            challenge: [0x52; 32],
        };
        assert_eq!(format!("{auth:?}"), "AuthWireMessageV1::Auth(<redacted>)");
        auth.zeroize();
        assert_eq!(
            auth,
            AuthWireMessageV1::Auth {
                proof: [0; 32],
                challenge: [0; 32]
            }
        );

        let mut pair = AuthWireMessageV1::PairSecret {
            sealed_secret: [0x61; 48],
            pairing_salt: [0x62; 16],
            aead_nonce: [0x63; 12],
        };
        pair.zeroize();
        assert_eq!(
            pair,
            AuthWireMessageV1::PairSecret {
                sealed_secret: [0; 48],
                pairing_salt: [0; 16],
                aead_nonce: [0; 12]
            }
        );
    }

    #[test]
    fn partial_multi_field_decode_failures_remain_fail_closed() {
        let valid_proof = "ERERERERERERERERERERERERERERERERERERERERERE=";
        let valid_sealed = "IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIi";
        let valid_salt = "MzMzMzMzMzMzMzMzMzMzMw==";
        let invalid = "not-canonical";
        let auth =
            format!("{{\"type\":\"auth\",\"proof\":\"{valid_proof}\",\"macNonce\":\"{invalid}\"}}");
        assert_eq!(decode_auth_wire_v1(auth.as_bytes()), Err(AuthWireErrorV1));
        let pair = format!(
            "{{\"type\":\"pair_secret\",\"encSecret\":\"{valid_sealed}\",\"salt\":\"{valid_salt}\",\"aeadNonce\":\"{invalid}\"}}"
        );
        assert_eq!(decode_auth_wire_v1(pair.as_bytes()), Err(AuthWireErrorV1));
    }
}
