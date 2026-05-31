/**
 * Superconnect INPUT event codec — ArkTS (HarmonyOS).
 * Encodes the fixed 44-byte little-endian record (proto/protocol.md §5).
 * Must match mac InputCodec.swift (golden vector proto/vectors.json `inputVectors`).
 */

export enum InputType {
  TouchDown = 0,
  TouchMove = 1,
  TouchUp = 2,
  Hover = 3,
  KeyDown = 4,
  KeyUp = 5,
  Scroll = 6,
  Zoom = 7,
}

export enum InputTool {
  Finger = 0,
  Pen = 1,
  Eraser = 2,
  Mouse = 3,
}

export interface InputEvent {
  type: number;
  tool: number;
  buttons: number;
  flags: number;
  timestampMs: number;
  x: number;        // normalized [0,1]
  y: number;        // normalized [0,1]
  pressure: number; // [0,1]
  tiltX: number;    // stylus tilt, degrees [-90,90]
  tiltY: number;
  scrollX: number;
  scrollY: number;
  keyCode: number;
  reserved: number;
}

export const INPUT_RECORD_SIZE: number = 44;

export function encodeInput(e: InputEvent): Uint8Array {
  const buf: ArrayBuffer = new ArrayBuffer(INPUT_RECORD_SIZE);
  const dv: DataView = new DataView(buf);
  let o: number = 0;
  dv.setUint8(o, e.type & 0xff); o += 1;
  dv.setUint8(o, e.tool & 0xff); o += 1;
  dv.setUint8(o, e.buttons & 0xff); o += 1;
  dv.setUint8(o, e.flags & 0xff); o += 1;
  // u64 LE timestamp via two u32 halves (avoids BigInt in ArkTS).
  const lo: number = e.timestampMs >>> 0;
  const hi: number = Math.floor(e.timestampMs / 0x100000000) >>> 0;
  dv.setUint32(o, lo, true); o += 4;
  dv.setUint32(o, hi, true); o += 4;
  dv.setFloat32(o, e.x, true); o += 4;
  dv.setFloat32(o, e.y, true); o += 4;
  dv.setFloat32(o, e.pressure, true); o += 4;
  dv.setFloat32(o, e.tiltX, true); o += 4;
  dv.setFloat32(o, e.tiltY, true); o += 4;
  dv.setFloat32(o, e.scrollX, true); o += 4;
  dv.setFloat32(o, e.scrollY, true); o += 4;
  dv.setUint16(o, e.keyCode & 0xffff, true); o += 2;
  dv.setUint16(o, e.reserved & 0xffff, true); o += 2;
  return new Uint8Array(buf);
}
