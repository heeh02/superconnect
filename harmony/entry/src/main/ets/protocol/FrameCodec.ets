/**
 * Superconnect wire framing — ArkTS (HarmonyOS).
 * Mirrors mac/Sources/SuperconnectCore/FrameCodec.swift and
 * shared/cpp/frame_codec.{h,cpp}. Must match proto/vectors.json byte-for-byte.
 * See proto/protocol.md.
 */

export enum Channel {
  CONTROL = 0,
  VIDEO = 1,
  INPUT = 2,
  AUDIO = 3,
  STATS = 4,
}

export interface Frame {
  channel: number;
  flags: number;
  payload: Uint8Array;
}

export const FRAME_HEADER_SIZE: number = 6;
export const MAX_FRAME_PAYLOAD: number = 16 * 1024 * 1024; // 16 MiB

export function encodeFrame(channel: number, flags: number, payload: Uint8Array): Uint8Array {
  const out: Uint8Array = new Uint8Array(FRAME_HEADER_SIZE + payload.length);
  out[0] = channel & 0xff;
  out[1] = flags & 0xff;
  const len: number = payload.length;
  out[2] = len & 0xff;
  out[3] = (len >>> 8) & 0xff;
  out[4] = (len >>> 16) & 0xff;
  out[5] = (len >>> 24) & 0xff;
  out.set(payload, FRAME_HEADER_SIZE);
  return out;
}

/** Streaming decoder, tolerant of fragmentation/coalescing. */
export class FrameDecoder {
  private buffer: Uint8Array = new Uint8Array(0);

  push(data: Uint8Array): Frame[] {
    // Append to internal buffer.
    const merged: Uint8Array = new Uint8Array(this.buffer.length + data.length);
    merged.set(this.buffer, 0);
    merged.set(data, this.buffer.length);
    this.buffer = merged;

    const frames: Frame[] = [];
    let cursor: number = 0;
    while (this.buffer.length - cursor >= FRAME_HEADER_SIZE) {
      const base: number = cursor;
      const channel: number = this.buffer[base];
      const flags: number = this.buffer[base + 1];
      const len: number = (this.buffer[base + 2] |
        (this.buffer[base + 3] << 8) |
        (this.buffer[base + 4] << 16) |
        (this.buffer[base + 5] << 24)) >>> 0;
      if (len > MAX_FRAME_PAYLOAD) {
        throw new Error('frame payload exceeds MAX_FRAME_PAYLOAD');
      }
      const total: number = FRAME_HEADER_SIZE + len;
      if (this.buffer.length - base < total) {
        break; // wait for more bytes
      }
      const payload: Uint8Array = this.buffer.slice(base + FRAME_HEADER_SIZE, base + total);
      frames.push({ channel, flags, payload });
      cursor += total;
    }
    if (cursor > 0) {
      this.buffer = this.buffer.slice(cursor);
    }
    return frames;
  }
}
