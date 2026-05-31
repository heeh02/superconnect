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
