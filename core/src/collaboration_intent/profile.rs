use crate::capability::{CapabilityId, CapabilitySet, MediaRole, ProjectionIntent, TransportKind};

use super::{
    InputPolicy, IntentAxis, IntentCapability, LocalRole, SinkPresentation, SourceTopology,
    Topology, TransportPreference,
};

const ALL_AXES: [IntentAxis; 6] = [
    IntentAxis::LocalRole,
    IntentAxis::SourceTopology,
    IntentAxis::SinkPresentation,
    IntentAxis::InputPolicy,
    IntentAxis::TransportPreference,
    IntentAxis::Topology,
];

const KNOWN_INTENT_BITS: u64 = axis_mask(IntentAxis::LocalRole)
    | axis_mask(IntentAxis::SourceTopology)
    | axis_mask(IntentAxis::SinkPresentation)
    | axis_mask(IntentAxis::InputPolicy)
    | axis_mask(IntentAxis::TransportPreference)
    | axis_mask(IntentAxis::Topology);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentCapabilityBitsError {
    UnknownBits { bits: u64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LegacyCapabilityBridgeError {
    UnknownBits { bits: u64 },
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct IntentCapabilitySet(u64);

impl IntentCapabilitySet {
    pub const EMPTY: Self = Self(0);

    pub const fn try_from_bits(bits: u64) -> Result<Self, IntentCapabilityBitsError> {
        let unknown = bits & !KNOWN_INTENT_BITS;
        if unknown == 0 {
            Ok(Self(bits))
        } else {
            Err(IntentCapabilityBitsError::UnknownBits { bits: unknown })
        }
    }

    pub const fn bits(self) -> u64 {
        self.0
    }

    pub const fn contains(self, capability: IntentCapability) -> bool {
        self.0 & capability.bit() != 0
    }

    pub const fn with(self, capability: IntentCapability) -> Self {
        Self(self.0 | capability.bit())
    }

    pub const fn without(self, capability: IntentCapability) -> Self {
        Self(self.0 & !capability.bit())
    }

    pub const fn without_axis(self, axis: IntentAxis) -> Self {
        Self(self.0 & !axis_mask(axis))
    }

    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub const fn supports_axis(self, axis: IntentAxis) -> bool {
        self.0 & axis_mask(axis) != 0
    }

    /// Return only the bits belonging to one fixed-width intent axis.
    ///
    /// Pure wire adapters use this to keep axis fields disjoint without copying the private mask
    /// layout into every codec. It does not reinterpret or authorize capabilities.
    pub const fn bits_for_axis(self, axis: IntentAxis) -> u64 {
        self.0 & axis_mask(axis)
    }

    /// Bridge the existing v1 capability facts and require callers to provide the three axes that v1
    /// never represented. Unknown v1 bits fail closed instead of being promoted into an intent.
    pub fn from_capability_v1(
        capabilities: CapabilitySet,
        sink_presentation: SinkPresentation,
        input_policy: InputPolicy,
        topology: Topology,
    ) -> Result<Self, LegacyCapabilityBridgeError> {
        let unknown = capabilities.bits() & !capabilities.known_bits();
        if unknown != 0 {
            return Err(LegacyCapabilityBridgeError::UnknownBits { bits: unknown });
        }

        let mut result = Self::EMPTY
            .with(IntentCapability::SinkPresentation(sink_presentation))
            .with(IntentCapability::InputPolicy(input_policy))
            .with(IntentCapability::Topology(topology));
        if capabilities.contains(CapabilityId::MediaHost) {
            result = result.with(IntentCapability::LocalRole(LocalRole::from(
                MediaRole::Host,
            )));
        }
        if capabilities.contains(CapabilityId::MediaReceiver) {
            result = result.with(IntentCapability::LocalRole(LocalRole::from(
                MediaRole::Receiver,
            )));
        }
        for (capability, projection) in [
            (CapabilityId::ProjectionExtend, ProjectionIntent::Extend),
            (CapabilityId::ProjectionMirror, ProjectionIntent::Mirror),
            (CapabilityId::ProjectionPrimary, ProjectionIntent::Primary),
        ] {
            if capabilities.contains(capability) {
                result = result.with(IntentCapability::SourceTopology(SourceTopology::from(
                    projection,
                )));
            }
        }
        if capabilities.contains(CapabilityId::TransportTcp) {
            result = result.with(IntentCapability::TransportPreference(
                TransportPreference::from(TransportKind::Tcp),
            ));
        }
        Ok(result)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProfileError {
    MissingAxis(IntentAxis),
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ProductCapabilityProfile(IntentCapabilitySet);

impl ProductCapabilityProfile {
    pub fn new(capabilities: IntentCapabilitySet) -> Result<Self, ProfileError> {
        validate_profile(capabilities)?;
        Ok(Self(capabilities))
    }

    /// Frozen compatibility profile matching [`super::SessionIntentDraft::legacy_v1`].
    pub const fn legacy_v1() -> Self {
        Self(legacy_v1_capabilities(LocalRole::Source))
    }

    pub const fn capabilities(self) -> IntentCapabilitySet {
        self.0
    }

    pub const fn supports(self, capability: IntentCapability) -> bool {
        self.0.contains(capability)
    }
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PeerCapabilityProfile(IntentCapabilitySet);

impl PeerCapabilityProfile {
    /// Role capabilities describe the peer's own role. The resolver requires the complementary role
    /// for source/sink sessions; all other axes describe supported session behavior directly.
    pub fn new(capabilities: IntentCapabilitySet) -> Result<Self, ProfileError> {
        validate_profile(capabilities)?;
        Ok(Self(capabilities))
    }

    pub const fn legacy_v1() -> Self {
        Self(legacy_v1_capabilities(LocalRole::Sink))
    }

    pub const fn capabilities(self) -> IntentCapabilitySet {
        self.0
    }

    pub const fn supports(self, capability: IntentCapability) -> bool {
        self.0.contains(capability)
    }
}

fn validate_profile(capabilities: IntentCapabilitySet) -> Result<(), ProfileError> {
    for axis in ALL_AXES {
        if !capabilities.supports_axis(axis) {
            return Err(ProfileError::MissingAxis(axis));
        }
    }
    Ok(())
}

const fn legacy_v1_capabilities(role: LocalRole) -> IntentCapabilitySet {
    IntentCapabilitySet::EMPTY
        .with(IntentCapability::LocalRole(role))
        .with(IntentCapability::SourceTopology(SourceTopology::Extend))
        .with(IntentCapability::SinkPresentation(
            SinkPresentation::Windowed,
        ))
        .with(IntentCapability::InputPolicy(InputPolicy::RemoteControl))
        .with(IntentCapability::TransportPreference(
            TransportPreference::Reliable,
        ))
        .with(IntentCapability::Topology(Topology::Direct))
}

const fn axis_mask(axis: IntentAxis) -> u64 {
    match axis {
        IntentAxis::LocalRole => 0x0000_0000_0000_0007,
        IntentAxis::SourceTopology => 0x0000_0000_0000_0f00,
        IntentAxis::SinkPresentation => 0x0000_0000_0007_0000,
        IntentAxis::InputPolicy => 0x0000_0000_0700_0000,
        IntentAxis::TransportPreference => 0x0000_0007_0000_0000,
        IntentAxis::Topology => 0x0000_0700_0000_0000,
    }
}
