use zeroize::Zeroize;

pub const FRAME_HEADER_SIZE: usize = 6;
pub const MAX_FRAME_PAYLOAD: usize = 16 * 1024 * 1024;
pub const DEFAULT_MAX_BUFFERED_BYTES: usize = FRAME_HEADER_SIZE + MAX_FRAME_PAYLOAD;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameError {
    BufferTooSmall,
    TooLarge,
    StaleView,
    Poisoned,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FrameMeta {
    pub channel: u8,
    pub flags: u8,
    pub payload_offset: usize,
    pub payload_length: usize,
    pub total_length: usize,
    pub generation: u64,
}

pub struct FrameDecoder {
    buffer: Vec<u8>,
    read_offset: usize,
    generation: u64,
    peeked: Option<FrameMeta>,
    max_buffered_bytes: usize,
    poisoned: bool,
}

impl FrameDecoder {
    pub fn new(max_buffered_bytes: usize) -> Self {
        let max_buffered_bytes = max_buffered_bytes.min(DEFAULT_MAX_BUFFERED_BYTES);
        Self {
            buffer: Vec::with_capacity(max_buffered_bytes.min(4 * 1024)),
            read_offset: 0,
            generation: 1,
            peeked: None,
            max_buffered_bytes,
            poisoned: false,
        }
    }

    pub fn push(&mut self, incoming: &[u8]) -> Result<(), FrameError> {
        if self.poisoned {
            return Err(FrameError::Poisoned);
        }
        if incoming.len() > self.max_buffered_bytes {
            self.poison();
            return Err(FrameError::TooLarge);
        }
        if self.peeked.is_some() {
            return Err(FrameError::StaleView);
        }
        let unread_length = self.buffer.len() - self.read_offset;
        let Some(new_length) = unread_length.checked_add(incoming.len()) else {
            self.poison();
            return Err(FrameError::TooLarge);
        };
        if new_length > self.max_buffered_bytes {
            self.poison();
            return Err(FrameError::TooLarge);
        }
        if self.read_offset == self.buffer.len() {
            self.buffer.clear();
            self.read_offset = 0;
        } else if self.read_offset != 0
            && self
                .buffer
                .len()
                .checked_add(incoming.len())
                .is_none_or(|physical_length| physical_length > self.max_buffered_bytes)
        {
            self.buffer.copy_within(self.read_offset.., 0);
            self.buffer[unread_length..].zeroize();
            self.buffer.truncate(unread_length);
            self.read_offset = 0;
        }
        self.ensure_capacity(self.buffer.len() + incoming.len());
        self.buffer.extend_from_slice(incoming);
        Ok(())
    }

    pub fn peek(&mut self) -> Result<Option<FrameMeta>, FrameError> {
        if self.poisoned {
            return Err(FrameError::Poisoned);
        }
        if let Some(meta) = self.peeked {
            return Ok(Some(meta));
        }
        if self.buffer.len() - self.read_offset < FRAME_HEADER_SIZE {
            return Ok(None);
        }
        let header_start = self.read_offset;
        let header_end = header_start + FRAME_HEADER_SIZE;
        let payload_length = u32::from_le_bytes(
            self.buffer[header_start + 2..header_end]
                .try_into()
                .expect("fixed frame header slice"),
        ) as usize;
        if payload_length > MAX_FRAME_PAYLOAD {
            self.poison();
            return Err(FrameError::TooLarge);
        }
        let total_length = FRAME_HEADER_SIZE + payload_length;
        if self.buffer.len() - self.read_offset < total_length {
            return Ok(None);
        }
        let meta = FrameMeta {
            channel: self.buffer[header_start],
            flags: self.buffer[header_start + 1],
            payload_offset: header_end,
            payload_length,
            total_length,
            generation: self.generation,
        };
        self.peeked = Some(meta);
        Ok(Some(meta))
    }

    pub fn payload_ptr(&self, meta: FrameMeta) -> *const u8 {
        self.buffer.as_ptr().wrapping_add(meta.payload_offset)
    }

    pub fn consume(&mut self, generation: u64) -> Result<(), FrameError> {
        if self.poisoned {
            return Err(FrameError::Poisoned);
        }
        let Some(meta) = self.peeked else {
            return Err(FrameError::StaleView);
        };
        if meta.generation != generation {
            return Err(FrameError::StaleView);
        }
        let consumed_end = self.read_offset + meta.total_length;
        self.buffer[self.read_offset..consumed_end].zeroize();
        self.read_offset = consumed_end;
        self.peeked = None;
        if self.read_offset == self.buffer.len() {
            self.buffer.clear();
            self.read_offset = 0;
        }
        self.bump_generation();
        Ok(())
    }

    pub fn reset(&mut self) {
        self.wipe_buffer();
        self.read_offset = 0;
        self.peeked = None;
        self.poisoned = false;
        self.bump_generation();
    }

    pub(crate) fn poison(&mut self) {
        self.wipe_buffer();
        self.read_offset = 0;
        self.peeked = None;
        self.poisoned = true;
        self.bump_generation();
    }

    pub(crate) fn is_poisoned(&self) -> bool {
        self.poisoned
    }

    fn bump_generation(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        if self.generation == 0 {
            self.generation = 1;
        }
    }

    /** Grow without letting Vec::realloc leave an unwiped copy in released allocator storage. */
    fn ensure_capacity(&mut self, required: usize) {
        if required <= self.buffer.capacity() {
            return;
        }
        let mut replacement = Vec::with_capacity(required);
        replacement.extend_from_slice(&self.buffer);
        self.buffer.as_mut_slice().zeroize();
        self.buffer = replacement;
    }

    fn wipe_buffer(&mut self) {
        self.buffer.as_mut_slice().zeroize();
        self.buffer.clear();
    }
}

impl Drop for FrameDecoder {
    fn drop(&mut self) {
        self.buffer.as_mut_slice().zeroize();
    }
}

pub fn encode_frame_header(
    channel: u8,
    flags: u8,
    payload_length: usize,
    output: &mut [u8],
) -> Result<usize, FrameError> {
    if payload_length > MAX_FRAME_PAYLOAD || payload_length > u32::MAX as usize {
        return Err(FrameError::TooLarge);
    }
    if output.len() < FRAME_HEADER_SIZE {
        return Err(FrameError::BufferTooSmall);
    }
    output[0] = channel;
    output[1] = flags;
    output[2..6].copy_from_slice(&(payload_length as u32).to_le_bytes());
    Ok(FRAME_HEADER_SIZE)
}

pub fn encode_frame(
    channel: u8,
    flags: u8,
    payload: &[u8],
    output: &mut [u8],
) -> Result<usize, FrameError> {
    if payload.len() > MAX_FRAME_PAYLOAD || payload.len() > u32::MAX as usize {
        return Err(FrameError::TooLarge);
    }
    let total = FRAME_HEADER_SIZE + payload.len();
    if output.len() < total {
        return Err(FrameError::BufferTooSmall);
    }
    encode_frame_header(channel, flags, payload.len(), output)?;
    output[6..total].copy_from_slice(payload);
    Ok(total)
}
