import { InputSender } from './Sender';
import { InputType, InputTool, InputEvent } from '../protocol/InputCodec';
import { KeyCode } from '@kit.InputKit';

// Physical keyboard + soft-keyboard (IME) → Mac, mirroring the keyboard concern that was
// inline in Index.ets. Every physical key is forwarded RAW (keycode + modifier flags) so the
// MAC's own input method composes (typing/delete/shortcuts unified); Caps switches the Mac
// input source (Control+Space); soft-keyboard insert/delete become committed text / a
// Backspace keystroke. All sends go through the InputSender seam.
export class KeyboardHandler {
  private sender: InputSender;
  private metaHeld: boolean = false;   // ⊙ (Meta/Super) held → maps to macOS Option

  constructor(sender: InputSender) { this.sender = sender; }

  private modFlags(e: KeyEvent): number {
    let f: number = 0;
    if (e.getModifierKeyState !== undefined) {
      if (e.getModifierKeyState(['shift'])) { f |= 0x01; }
      if (e.getModifierKeyState(['ctrl'])) { f |= 0x02; }
      if (e.getModifierKeyState(['alt'])) { f |= 0x04; }
    }
    if (this.metaHeld) { f |= 0x08; }
    return f;
  }

  private sendKey(type: number, keyCode: number, flags: number): void {
    const ev: InputEvent = {
      type: type, tool: InputTool.Finger, buttons: 0, flags: flags,
      timestampMs: Date.now(), x: 0, y: 0, pressure: 0, tiltX: 0, tiltY: 0,
      scrollX: 0, scrollY: 0, keyCode: keyCode & 0xffff, reserved: 0,
    };
    this.sender.sendInput(ev);
  }

  /** onKeyPreIme delegate — returns true when consumed (so the tablet IME never composes). */
  onKeyPreIme(e: KeyEvent): boolean {
    if (e.keySource !== KeySource.Keyboard) { return false; }
    if (e.keyCode === KeyCode.KEYCODE_CAPS_LOCK) {
      if (e.type === KeyType.Down) {
        this.sendKey(InputType.KeyDown, KeyCode.KEYCODE_SPACE, 0x02); // Space + Control
        this.sendKey(InputType.KeyUp, KeyCode.KEYCODE_SPACE, 0x02);
      }
      return true;
    }
    if (e.keyCode === KeyCode.KEYCODE_META_LEFT || e.keyCode === KeyCode.KEYCODE_META_RIGHT) {
      this.metaHeld = (e.type === KeyType.Down);
    }
    const t: number = (e.type === KeyType.Down) ? InputType.KeyDown : InputType.KeyUp;
    this.sendKey(t, e.keyCode & 0xffff, this.modFlags(e));
    return true;
  }

  /** Soft-keyboard insert → committed text (return false: don't insert into the field). */
  onWillInsert(info: InsertValue): boolean {
    this.sender.sendText(info.insertValue);
    return false;
  }

  /** 3rd-party IME commit via onChange (skip while still composing a preview). */
  onCommit(value: string, preview?: PreviewText): void {
    if (preview !== undefined && preview.value.length > 0) { return; }
    if (value.length > 0) { this.sender.sendText(value); }
  }

  /** Soft-keyboard backspace/forward-delete → Mac keystroke (return false: keep field empty). */
  onWillDelete(info: DeleteValue): boolean {
    const code: number = (info.direction === TextDeleteDirection.FORWARD)
      ? KeyCode.KEYCODE_FORWARD_DEL : KeyCode.KEYCODE_DEL;
    this.sendKey(InputType.KeyDown, code, 0);
    this.sendKey(InputType.KeyUp, code, 0);
    return false;
  }
}
