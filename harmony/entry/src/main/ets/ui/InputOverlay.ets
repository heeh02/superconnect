import { InputRouter } from '../input/InputRouter';

/**
 * Transparent full-bleed layer that captures touch + trackpad input and routes it to the
 * InputRouter. A self-contained input-capture module: the parent just mounts it (in fullscreen)
 * with the router and the paused flag — it knows nothing about display mode, the keyboard, or the
 * floating ball, so a change to any of those can't affect input capture (and vice-versa).
 *
 * `focusable(false)` so it never steals key focus from the ImeCatcher. When `disabled` (input
 * paused so the user can drive the tablet's own UI), hit-testing falls through (HitTestMode.None).
 */
@Component
export struct InputOverlay {
  /** Input routing module (pen / trackpad / finger FSMs). */
  router: InputRouter | null = null;
  /** Paused → let touches fall through to the tablet's own UI instead of capturing them. */
  @Prop disabled: boolean = false;

  build() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#00000000')
      .hitTestBehavior(this.disabled ? HitTestMode.None : HitTestMode.Block)
      .onTouch((e: TouchEvent) => { this.router?.onTouch(e); })
      .onMouse((e: MouseEvent) => { this.router?.onMouse(e); })       // trackpad cursor/click/drag
      .onAxisEvent((e: AxisEvent) => { this.router?.onAxis(e); })     // trackpad scroll/pinch
      .focusable(false)   // never steal key focus from the ImeCatcher
  }
}
