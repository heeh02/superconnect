//! Neutral session identity shared by reducers regardless of product edition.

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SessionGeneration(u64);

impl SessionGeneration {
    pub const INVALID: Self = Self(0);

    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn get(self) -> u64 {
        self.0
    }
}
