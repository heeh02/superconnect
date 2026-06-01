import { KeyboardHandler } from '../input/KeyboardHandler';

/**
 * Self-contained keyboard-capture surface: a hidden 1×1 TextInput that owns the physical + soft
 * keyboard and forwards every event to the KeyboardHandler. It is the ONLY component that touches
 * keyboard focus.
 *
 * MODULARITY (why this exists): previously this TextInput lived inline inside Index's
 * `if (fullscreen())` branch, so a DISPLAY-mode change (#53 windowed launch) silently unmounted it
 * and killed the keyboard with zero keyboard-code edits. Here the catcher is mounted for the WHOLE
 * streaming session (the parent gates it on `streaming()`, not on fullscreen), so no display change
 * can unmount it. The `active` flag (= fullscreen / input is being forwarded) controls FOCUS only —
 * never mounting: active ⇒ grab focus (soft keyboard + onKeyPreIme fire); inactive ⇒ not focusable,
 * so windowed/preview shows no keyboard. It self-focuses on (re)mount and on becoming active, which
 * is what `defaultFocus(true)` failed to do for a late-mounted component.
 */
@Component
export struct ImeCatcher {
  /** The keyboard logic module; this component is only its UI host + focus owner. */
  kbd: KeyboardHandler | null = null;
  /** True while input is forwarded to the Mac (fullscreen). Drives focus, NOT mounting. */
  @Prop @Watch('onActiveChange') active: boolean = false;
  @State private text: string = '';
  private ctrl: TextInputController = new TextInputController();
  /** Published focus id so the parent can re-assert focus after closing a focus-stealing modal. */
  static readonly ID: string = 'imecatcher';

  /** Re-grab keyboard focus, deferred so it runs after the current view update (a closing modal /
   *  window-mode transition), else focus can bounce back to a just-removed control. */
  private grabFocus(): void {
    setTimeout((): void => { focusControl.requestFocus(ImeCatcher.ID); }, 50);
  }

  private onActiveChange(): void {
    if (this.active) { this.grabFocus(); }
    // inactive: focusable(false) below drops focus → the soft keyboard dismisses; nothing else to do.
  }

  build() {
    TextInput({ text: this.text, controller: this.ctrl })
      .id(ImeCatcher.ID)
      .focusable(this.active)            // only focusable while forwarding → windowed never pops the keyboard
      .opacity(0)
      .width(1)
      .height(1)
      .onAppear((): void => { if (this.active) { this.grabFocus(); } })   // self-focus on (re)mount
      .onKeyPreIme((e: KeyEvent): boolean => {
        return this.kbd?.onKeyPreIme(e) ?? false;       // physical keys → Mac
      })
      .onWillInsert((info: InsertValue): boolean => {
        return this.kbd?.onWillInsert(info) ?? false;
      })
      .onChange((value: string, preview?: PreviewText): void => {
        this.kbd?.onCommit(value, preview);             // 3rd-party IME commit → Mac
        this.text = '';
        this.ctrl.caretPosition(0);
      })
      .onWillDelete((info: DeleteValue): boolean => {
        return this.kbd?.onWillDelete(info) ?? false;   // soft backspace/del → Mac keystroke
      })
  }
}
