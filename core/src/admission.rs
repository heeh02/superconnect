//! Platform-neutral admission state machine.
//!
//! The reducer owns only value state. Platform drivers execute returned effects and
//! must route timer callbacks back with the exact `(owner, token)` pair they armed.

use std::collections::BTreeMap;

/// Absolute safety limit for pending owners in one admission state machine.
pub const MAX_PENDING_LIMIT: usize = 64;
pub const AUTHENTICATION_TIMEOUT_MS: u64 = 10_000;
pub const PAIRING_TIMEOUT_MS: u64 = 75_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct OwnerId(u64);

impl OwnerId {
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn get(self) -> u64 {
        self.0
    }
}

impl From<u64> for OwnerId {
    fn from(value: u64) -> Self {
        Self::new(value)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TimerToken(u64);

impl TimerToken {
    pub const INVALID: Self = Self(0);

    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn get(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimerKind {
    Authentication,
    Pairing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdmissionEvent {
    Accepted { owner: OwnerId },
    PairingPrompt { owner: OwnerId },
    Authenticated { owner: OwnerId },
    TimedOut { owner: OwnerId, token: TimerToken },
    Closed { owner: OwnerId },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdmissionEffect {
    ArmTimer {
        owner: OwnerId,
        token: TimerToken,
        kind: TimerKind,
        timeout_ms: u64,
    },
    CancelTimer {
        owner: OwnerId,
        token: TimerToken,
    },
    Claim {
        owner: OwnerId,
    },
    RejectBusy {
        owner: OwnerId,
    },
    RejectCapacity {
        owner: OwnerId,
    },
    Close {
        owner: OwnerId,
    },
    PendingReleased {
        owner: OwnerId,
    },
    ActiveReleased {
        owner: OwnerId,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdmissionConfigError {
    ZeroCapacity,
    CapacityTooLarge { requested: usize, maximum: usize },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct PendingOwner {
    timer_token: TimerToken,
    timer_kind: TimerKind,
}

/// Deterministic `State + Event -> State + Vec<Effect>` admission reducer.
///
/// No platform pointer, clock, timer, thread, or async runtime is retained here.
#[derive(Debug, PartialEq, Eq)]
pub struct ScAdmission {
    active: Option<OwnerId>,
    pending: BTreeMap<OwnerId, PendingOwner>,
    max_pending: usize,
    next_timer_token: u64,
}

impl ScAdmission {
    pub fn new(max_pending: usize) -> Result<Self, AdmissionConfigError> {
        if max_pending == 0 {
            return Err(AdmissionConfigError::ZeroCapacity);
        }
        if max_pending > MAX_PENDING_LIMIT {
            return Err(AdmissionConfigError::CapacityTooLarge {
                requested: max_pending,
                maximum: MAX_PENDING_LIMIT,
            });
        }
        Ok(Self {
            active: None,
            pending: BTreeMap::new(),
            max_pending,
            next_timer_token: 1,
        })
    }

    pub fn apply(&mut self, event: AdmissionEvent) -> Vec<AdmissionEffect> {
        let effects = match event {
            AdmissionEvent::Accepted { owner } => self.accept(owner),
            AdmissionEvent::PairingPrompt { owner } => self.pairing_prompt(owner),
            AdmissionEvent::Authenticated { owner } => self.authenticate(owner),
            AdmissionEvent::TimedOut { owner, token } => self.time_out(owner, token),
            AdmissionEvent::Closed { owner } => self.close(owner),
        };
        debug_assert!(self.invariants_hold());
        effects
    }

    pub const fn active_owner(&self) -> Option<OwnerId> {
        self.active
    }

    pub fn pending_owners(&self) -> Vec<OwnerId> {
        self.pending.keys().copied().collect()
    }

    pub fn pending_timer_tokens(&self) -> impl Iterator<Item = TimerToken> + '_ {
        self.pending.values().map(|pending| pending.timer_token)
    }

    pub fn timer_token(&self, owner: OwnerId) -> Option<TimerToken> {
        self.pending.get(&owner).map(|pending| pending.timer_token)
    }

    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    pub const fn max_pending(&self) -> usize {
        self.max_pending
    }

    pub(crate) fn stage_apply(&self, event: AdmissionEvent) -> (Self, Vec<AdmissionEffect>) {
        let mut staged = Self {
            active: self.active,
            pending: self.pending.clone(),
            max_pending: self.max_pending,
            next_timer_token: self.next_timer_token,
        };
        let effects = staged.apply(event);
        (staged, effects)
    }

    fn accept(&mut self, owner: OwnerId) -> Vec<AdmissionEffect> {
        if self.active == Some(owner) || self.pending.contains_key(&owner) {
            return Vec::new();
        }
        if self.active.is_some() {
            return vec![AdmissionEffect::RejectBusy { owner }];
        }
        if self.pending.len() >= self.max_pending {
            return vec![AdmissionEffect::RejectCapacity { owner }];
        }

        let token = self.allocate_timer_token();
        self.pending.insert(
            owner,
            PendingOwner {
                timer_token: token,
                timer_kind: TimerKind::Authentication,
            },
        );
        vec![AdmissionEffect::ArmTimer {
            owner,
            token,
            kind: TimerKind::Authentication,
            timeout_ms: AUTHENTICATION_TIMEOUT_MS,
        }]
    }

    fn pairing_prompt(&mut self, owner: OwnerId) -> Vec<AdmissionEffect> {
        let Some((previous_token, timer_kind)) = self
            .pending
            .get(&owner)
            .map(|pending| (pending.timer_token, pending.timer_kind))
        else {
            return Vec::new();
        };
        if timer_kind == TimerKind::Pairing {
            return Vec::new();
        }
        let token = self.allocate_timer_token();
        if let Some(pending) = self.pending.get_mut(&owner) {
            pending.timer_token = token;
            pending.timer_kind = TimerKind::Pairing;
        }
        vec![
            AdmissionEffect::CancelTimer {
                owner,
                token: previous_token,
            },
            AdmissionEffect::ArmTimer {
                owner,
                token,
                kind: TimerKind::Pairing,
                timeout_ms: PAIRING_TIMEOUT_MS,
            },
        ]
    }

    fn authenticate(&mut self, owner: OwnerId) -> Vec<AdmissionEffect> {
        let Some(pending) = self.pending.remove(&owner) else {
            return Vec::new();
        };
        let mut effects = vec![AdmissionEffect::CancelTimer {
            owner,
            token: pending.timer_token,
        }];
        if self.active.is_none() {
            self.active = Some(owner);
            effects.push(AdmissionEffect::Claim { owner });
        } else {
            effects.push(AdmissionEffect::RejectBusy { owner });
        }
        effects
    }

    fn time_out(&mut self, owner: OwnerId, token: TimerToken) -> Vec<AdmissionEffect> {
        if self.timer_token(owner) != Some(token) {
            return Vec::new();
        }
        self.pending.remove(&owner);
        vec![
            AdmissionEffect::Close { owner },
            AdmissionEffect::PendingReleased { owner },
        ]
    }

    fn close(&mut self, owner: OwnerId) -> Vec<AdmissionEffect> {
        if self.active == Some(owner) {
            self.active = None;
            return vec![AdmissionEffect::ActiveReleased { owner }];
        }
        let Some(pending) = self.pending.remove(&owner) else {
            return Vec::new();
        };
        vec![
            AdmissionEffect::CancelTimer {
                owner,
                token: pending.timer_token,
            },
            AdmissionEffect::PendingReleased { owner },
        ]
    }

    fn allocate_timer_token(&mut self) -> TimerToken {
        let token = TimerToken(self.next_timer_token);
        self.next_timer_token = self.next_timer_token.wrapping_add(1);
        if self.next_timer_token == TimerToken::INVALID.0 {
            self.next_timer_token = 1;
        }
        token
    }

    fn invariants_hold(&self) -> bool {
        self.pending.len() <= self.max_pending
            && self.max_pending <= MAX_PENDING_LIMIT
            && self
                .active
                .is_none_or(|owner| !self.pending.contains_key(&owner))
            && self
                .pending
                .values()
                .all(|pending| pending.timer_token != TimerToken::INVALID)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timer_token_wrap_never_panics_or_emits_invalid() {
        let mut admission = ScAdmission::new(2).unwrap();
        admission.next_timer_token = u64::MAX;

        let first = admission.apply(AdmissionEvent::Accepted {
            owner: OwnerId::new(1),
        });
        let second = admission.apply(AdmissionEvent::Accepted {
            owner: OwnerId::new(2),
        });

        assert!(matches!(
            first.as_slice(),
            [AdmissionEffect::ArmTimer {
                token: TimerToken(u64::MAX),
                ..
            }]
        ));
        assert!(matches!(
            second.as_slice(),
            [AdmissionEffect::ArmTimer {
                token: TimerToken(1),
                ..
            }]
        ));
    }
}
