import { InputEvent } from '../protocol/InputCodec';

// InputSender — THE single decoupling seam between all input logic (pen / trackpad /
// keyboard / finger gestures) and the byte transport. Generalizes the emit callback that
// GestureController already uses. The ConnectionManager provides the concrete impl that
// frames events onto the INPUT / CONTROL channels, so no input handler ever touches the
// transport directly.
export interface InputSender {
  sendInput(ev: InputEvent): void;   // → Channel.INPUT
  sendText(text: string): void;      // → Channel.CONTROL { type: "text" }
}

// A pre-normalized input emit (the InputEvent payload fields, minus framing). Input handlers
// (pen / trackpad) call this instead of building InputEvents + touching the transport, so there is
// exactly ONE wire-seam owner — the router's send() — and the wire bytes stay identical.
export type SendFn = (type: number, tool: number, buttons: number, x: number, y: number,
                      pressure: number, tiltX: number, tiltY: number, scrollX: number, scrollY: number) => void;
