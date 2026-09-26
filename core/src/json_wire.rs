#[derive(Clone, Copy)]
pub(crate) enum Scalar<'a> {
    Text(&'a str),
    Number(&'a str),
    Object(&'a str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct JsonSyntaxError;

pub(crate) struct FlatObjectParser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> FlatObjectParser<'a> {
    pub(crate) fn new(text: &'a str) -> Self {
        Self {
            text,
            bytes: text.as_bytes(),
            offset: 0,
        }
    }

    pub(crate) fn parse(mut self) -> Result<Vec<(&'a str, Scalar<'a>)>, JsonSyntaxError> {
        if self.bytes.iter().any(|byte| !byte.is_ascii()) {
            return Err(JsonSyntaxError);
        }
        self.space();
        self.take(b'{')?;
        let mut result = Vec::with_capacity(16);
        self.space();
        if self.peek() == Some(b'}') {
            self.offset += 1;
        } else {
            loop {
                self.space();
                let key = self.string()?;
                self.space();
                self.take(b':')?;
                self.space();
                let value = match self.peek() {
                    Some(b'"') => Scalar::Text(self.string()?),
                    Some(b'{') => Scalar::Object(self.object()?),
                    _ => Scalar::Number(self.number()?),
                };
                result.push((key, value));
                self.space();
                match self.peek() {
                    Some(b',') => self.offset += 1,
                    Some(b'}') => {
                        self.offset += 1;
                        break;
                    }
                    _ => return Err(JsonSyntaxError),
                }
            }
        }
        self.space();
        if self.offset != self.bytes.len() {
            return Err(JsonSyntaxError);
        }
        Ok(result)
    }

    fn string(&mut self) -> Result<&'a str, JsonSyntaxError> {
        self.take(b'"')?;
        let start = self.offset;
        while let Some(byte) = self.peek() {
            if byte == b'"' {
                let result = &self.text[start..self.offset];
                self.offset += 1;
                return Ok(result);
            }
            if byte == b'\\' || byte < 0x20 || !byte.is_ascii() {
                return Err(JsonSyntaxError);
            }
            self.offset += 1;
        }
        Err(JsonSyntaxError)
    }

    fn object(&mut self) -> Result<&'a str, JsonSyntaxError> {
        let start = self.offset;
        let mut depth = 0_usize;
        let mut string = false;
        while let Some(byte) = self.peek() {
            self.offset += 1;
            if string {
                if byte == b'\\' || byte < 0x20 {
                    return Err(JsonSyntaxError);
                }
                if byte == b'"' {
                    string = false;
                }
                continue;
            }
            match byte {
                b'"' => string = true,
                b'{' => depth += 1,
                b'}' => {
                    depth = depth.checked_sub(1).ok_or(JsonSyntaxError)?;
                    if depth == 0 {
                        return Ok(&self.text[start..self.offset]);
                    }
                }
                _ => {}
            }
        }
        Err(JsonSyntaxError)
    }

    fn number(&mut self) -> Result<&'a str, JsonSyntaxError> {
        let start = self.offset;
        while self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            self.offset += 1;
        }
        if start == self.offset {
            return Err(JsonSyntaxError);
        }
        Ok(&self.text[start..self.offset])
    }

    fn take(&mut self, expected: u8) -> Result<(), JsonSyntaxError> {
        if self.peek() != Some(expected) {
            return Err(JsonSyntaxError);
        }
        self.offset += 1;
        Ok(())
    }
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.offset).copied()
    }
    fn space(&mut self) {
        while self
            .peek()
            .is_some_and(|byte| matches!(byte, b' ' | b'\n' | b'\r' | b'\t'))
        {
            self.offset += 1;
        }
    }
}
