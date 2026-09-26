use crate::capability::{MediaRole, ProjectionIntent, TransportKind};

pub const SESSION_INTENT_FIELD_COUNT: usize = 6;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum LocalRole {
    Source = 1,
    Sink = 2,
    Relay = 3,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SourceTopology {
    Extend = 1,
    Mirror = 2,
    Primary = 3,
    Application = 4,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SinkPresentation {
    Windowed = 1,
    Fullscreen = 2,
    PictureInPicture = 3,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum InputPolicy {
    ViewOnly = 1,
    RemoteControl = 2,
    RequestControl = 3,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum TransportPreference {
    Reliable = 1,
    LowestLatency = 2,
    Automatic = 3,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Topology {
    Direct = 1,
    LocalMultiPeer = 2,
    Relayed = 3,
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum IntentAxis {
    LocalRole = 1,
    SourceTopology = 2,
    SinkPresentation = 3,
    InputPolicy = 4,
    TransportPreference = 5,
    Topology = 6,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum IntentCapability {
    LocalRole(LocalRole),
    SourceTopology(SourceTopology),
    SinkPresentation(SinkPresentation),
    InputPolicy(InputPolicy),
    TransportPreference(TransportPreference),
    Topology(Topology),
}

impl IntentCapability {
    pub const fn axis(self) -> IntentAxis {
        match self {
            Self::LocalRole(_) => IntentAxis::LocalRole,
            Self::SourceTopology(_) => IntentAxis::SourceTopology,
            Self::SinkPresentation(_) => IntentAxis::SinkPresentation,
            Self::InputPolicy(_) => IntentAxis::InputPolicy,
            Self::TransportPreference(_) => IntentAxis::TransportPreference,
            Self::Topology(_) => IntentAxis::Topology,
        }
    }

    pub(super) const fn bit(self) -> u64 {
        let index = match self {
            Self::LocalRole(value) => value as u8 - 1,
            Self::SourceTopology(value) => 8 + value as u8 - 1,
            Self::SinkPresentation(value) => 16 + value as u8 - 1,
            Self::InputPolicy(value) => 24 + value as u8 - 1,
            Self::TransportPreference(value) => 32 + value as u8 - 1,
            Self::Topology(value) => 40 + value as u8 - 1,
        };
        1_u64 << index
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntentParseError {
    UnknownValue { axis: IntentAxis, value: u8 },
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SessionIntentDraft {
    local_role: LocalRole,
    source_topology: SourceTopology,
    sink_presentation: SinkPresentation,
    input_policy: InputPolicy,
    transport_preference: TransportPreference,
    topology: Topology,
}

impl SessionIntentDraft {
    pub const fn new(
        local_role: LocalRole,
        source_topology: SourceTopology,
        sink_presentation: SinkPresentation,
        input_policy: InputPolicy,
        transport_preference: TransportPreference,
        topology: Topology,
    ) -> Self {
        Self {
            local_role,
            source_topology,
            sink_presentation,
            input_policy,
            transport_preference,
            topology,
        }
    }

    /// Frozen compatibility intent for the pre-negotiation source flow.
    pub const fn legacy_v1() -> Self {
        Self::new(
            LocalRole::Source,
            SourceTopology::Extend,
            SinkPresentation::Windowed,
            InputPolicy::RemoteControl,
            TransportPreference::Reliable,
            Topology::Direct,
        )
    }

    /// Parse six numeric domain values. This is not a wire codec; callers own any framing/versioning.
    pub fn parse(raw: [u8; SESSION_INTENT_FIELD_COUNT]) -> Result<Self, IntentParseError> {
        Ok(Self::new(
            parse_local_role(raw[0])?,
            parse_source_topology(raw[1])?,
            parse_sink_presentation(raw[2])?,
            parse_input_policy(raw[3])?,
            parse_transport_preference(raw[4])?,
            parse_topology(raw[5])?,
        ))
    }

    pub const fn local_role(self) -> LocalRole {
        self.local_role
    }

    pub const fn source_topology(self) -> SourceTopology {
        self.source_topology
    }

    pub const fn sink_presentation(self) -> SinkPresentation {
        self.sink_presentation
    }

    pub const fn input_policy(self) -> InputPolicy {
        self.input_policy
    }

    pub const fn transport_preference(self) -> TransportPreference {
        self.transport_preference
    }

    pub const fn topology(self) -> Topology {
        self.topology
    }

    pub(super) const fn capabilities(self) -> [IntentCapability; SESSION_INTENT_FIELD_COUNT] {
        [
            IntentCapability::LocalRole(self.local_role),
            IntentCapability::SourceTopology(self.source_topology),
            IntentCapability::SinkPresentation(self.sink_presentation),
            IntentCapability::InputPolicy(self.input_policy),
            IntentCapability::TransportPreference(self.transport_preference),
            IntentCapability::Topology(self.topology),
        ]
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ResolvedIntent {
    local_role: LocalRole,
    source_topology: SourceTopology,
    sink_presentation: SinkPresentation,
    input_policy: InputPolicy,
    transport_preference: TransportPreference,
    topology: Topology,
}

impl ResolvedIntent {
    pub(crate) const fn from_draft(draft: SessionIntentDraft) -> Self {
        Self {
            local_role: draft.local_role,
            source_topology: draft.source_topology,
            sink_presentation: draft.sink_presentation,
            input_policy: draft.input_policy,
            transport_preference: draft.transport_preference,
            topology: draft.topology,
        }
    }

    pub(crate) const fn from_draft_with_transport(
        draft: SessionIntentDraft,
        transport_preference: TransportPreference,
    ) -> Self {
        Self {
            local_role: draft.local_role,
            source_topology: draft.source_topology,
            sink_presentation: draft.sink_presentation,
            input_policy: draft.input_policy,
            transport_preference,
            topology: draft.topology,
        }
    }

    pub const fn as_draft(self) -> SessionIntentDraft {
        SessionIntentDraft::new(
            self.local_role,
            self.source_topology,
            self.sink_presentation,
            self.input_policy,
            self.transport_preference,
            self.topology,
        )
    }

    pub const fn local_role(self) -> LocalRole {
        self.local_role
    }

    pub const fn source_topology(self) -> SourceTopology {
        self.source_topology
    }

    pub const fn sink_presentation(self) -> SinkPresentation {
        self.sink_presentation
    }

    pub const fn input_policy(self) -> InputPolicy {
        self.input_policy
    }

    pub const fn transport_preference(self) -> TransportPreference {
        self.transport_preference
    }

    pub const fn topology(self) -> Topology {
        self.topology
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LegacyIntentBridgeError {
    UnsupportedLocalRole(LocalRole),
    UnsupportedSourceTopology(SourceTopology),
    UnsupportedTransportPreference(TransportPreference),
}

impl From<MediaRole> for LocalRole {
    fn from(value: MediaRole) -> Self {
        match value {
            MediaRole::Host => Self::Source,
            MediaRole::Receiver => Self::Sink,
        }
    }
}

impl TryFrom<LocalRole> for MediaRole {
    type Error = LegacyIntentBridgeError;

    fn try_from(value: LocalRole) -> Result<Self, Self::Error> {
        match value {
            LocalRole::Source => Ok(Self::Host),
            LocalRole::Sink => Ok(Self::Receiver),
            LocalRole::Relay => Err(LegacyIntentBridgeError::UnsupportedLocalRole(value)),
        }
    }
}

impl From<ProjectionIntent> for SourceTopology {
    fn from(value: ProjectionIntent) -> Self {
        match value {
            ProjectionIntent::Extend => Self::Extend,
            ProjectionIntent::Mirror => Self::Mirror,
            ProjectionIntent::Primary => Self::Primary,
        }
    }
}

impl TryFrom<SourceTopology> for ProjectionIntent {
    type Error = LegacyIntentBridgeError;

    fn try_from(value: SourceTopology) -> Result<Self, Self::Error> {
        match value {
            SourceTopology::Extend => Ok(Self::Extend),
            SourceTopology::Mirror => Ok(Self::Mirror),
            SourceTopology::Primary => Ok(Self::Primary),
            SourceTopology::Application => {
                Err(LegacyIntentBridgeError::UnsupportedSourceTopology(value))
            }
        }
    }
}

impl From<TransportKind> for TransportPreference {
    fn from(value: TransportKind) -> Self {
        match value {
            TransportKind::Tcp => Self::Reliable,
        }
    }
}

impl TryFrom<TransportPreference> for TransportKind {
    type Error = LegacyIntentBridgeError;

    fn try_from(value: TransportPreference) -> Result<Self, Self::Error> {
        match value {
            TransportPreference::Reliable => Ok(Self::Tcp),
            TransportPreference::LowestLatency | TransportPreference::Automatic => Err(
                LegacyIntentBridgeError::UnsupportedTransportPreference(value),
            ),
        }
    }
}

fn parse_local_role(value: u8) -> Result<LocalRole, IntentParseError> {
    match value {
        1 => Ok(LocalRole::Source),
        2 => Ok(LocalRole::Sink),
        3 => Ok(LocalRole::Relay),
        _ => Err(IntentParseError::UnknownValue {
            axis: IntentAxis::LocalRole,
            value,
        }),
    }
}

fn parse_source_topology(value: u8) -> Result<SourceTopology, IntentParseError> {
    match value {
        1 => Ok(SourceTopology::Extend),
        2 => Ok(SourceTopology::Mirror),
        3 => Ok(SourceTopology::Primary),
        4 => Ok(SourceTopology::Application),
        _ => Err(IntentParseError::UnknownValue {
            axis: IntentAxis::SourceTopology,
            value,
        }),
    }
}

fn parse_sink_presentation(value: u8) -> Result<SinkPresentation, IntentParseError> {
    match value {
        1 => Ok(SinkPresentation::Windowed),
        2 => Ok(SinkPresentation::Fullscreen),
        3 => Ok(SinkPresentation::PictureInPicture),
        _ => Err(IntentParseError::UnknownValue {
            axis: IntentAxis::SinkPresentation,
            value,
        }),
    }
}

fn parse_input_policy(value: u8) -> Result<InputPolicy, IntentParseError> {
    match value {
        1 => Ok(InputPolicy::ViewOnly),
        2 => Ok(InputPolicy::RemoteControl),
        3 => Ok(InputPolicy::RequestControl),
        _ => Err(IntentParseError::UnknownValue {
            axis: IntentAxis::InputPolicy,
            value,
        }),
    }
}

fn parse_transport_preference(value: u8) -> Result<TransportPreference, IntentParseError> {
    match value {
        1 => Ok(TransportPreference::Reliable),
        2 => Ok(TransportPreference::LowestLatency),
        3 => Ok(TransportPreference::Automatic),
        _ => Err(IntentParseError::UnknownValue {
            axis: IntentAxis::TransportPreference,
            value,
        }),
    }
}

fn parse_topology(value: u8) -> Result<Topology, IntentParseError> {
    match value {
        1 => Ok(Topology::Direct),
        2 => Ok(Topology::LocalMultiPeer),
        3 => Ok(Topology::Relayed),
        _ => Err(IntentParseError::UnknownValue {
            axis: IntentAxis::Topology,
            value,
        }),
    }
}
