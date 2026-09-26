use super::ControlEnvelopeErrorV1;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ControlCapsUpdateV1 {
    pub codecs: u32,
    pub screen_width: u32,
    pub screen_height: u32,
    pub scale: Option<f64>,
    pub refresh_rate: Option<u32>,
    pub refresh_rate_max: Option<u32>,
    pub pen: Option<bool>,
    pub hdr_hlg: Option<bool>,
    pub hdr_pq: Option<bool>,
}

impl ControlCapsUpdateV1 {
    pub fn validate(self) -> Result<Self, ControlEnvelopeErrorV1> {
        if self.codecs == 0
            || self.codecs & !3 != 0
            || !(16..=8192).contains(&self.screen_width)
            || !(16..=8192).contains(&self.screen_height)
            || self
                .scale
                .is_some_and(|value| !value.is_finite() || !(0.5..=8.0).contains(&value))
            || self
                .refresh_rate
                .is_some_and(|value| value == 0 || value > 240)
            || self
                .refresh_rate_max
                .is_some_and(|value| value == 0 || value > 240)
        {
            return Err(ControlEnvelopeErrorV1::Malformed);
        }
        Ok(self)
    }
}
