import { encodeFrame, Channel } from '../protocol/FrameCodec';
import { encodeInput, InputEvent } from '../protocol/InputCodec';
import { InputSender } from './Sender';
import util from '@ohos.util';

interface KbTextMsg {
  type: string;
  text: string;
}

// Concrete InputSender: frames a built InputEvent onto the INPUT channel, and committed
// (IME) text onto the CONTROL channel as {"type":"text",...} — byte-identical to the
// original inline sends in Index.ets. Constructed with the transport's frame-send closure
// so input handlers never touch the transport directly.
export class FrameInputSender implements InputSender {
  private send: (bytes: Uint8Array) => void;
  private encoder: util.TextEncoder = new util.TextEncoder();

  constructor(send: (bytes: Uint8Array) => void) {
    this.send = send;
  }

  sendInput(ev: InputEvent): void {
    this.send(encodeFrame(Channel.INPUT, 0, encodeInput(ev)));
  }

  sendText(text: string): void {
    if (text.length === 0) { return; }
    const msg: KbTextMsg = { type: 'text', text: text };
    const payload: Uint8Array = this.encoder.encodeInto(JSON.stringify(msg));
    this.send(encodeFrame(Channel.CONTROL, 0, payload));
  }
}
