import { SendFn } from './Sender';
import { InputType, InputTool } from '../protocol/InputCodec';

/**
 * TrackpadHandler — the integrated trackpad, kept as ONE machine because its latches span the input
 * streams: the click-vs-drag gate (onMouse), the drag-lock / double-tap-grab (onTouch sourceTool=7),
 * and scroll + the latched pinch state machine (onAxis). lastAxisMs (axis → freeze cursor),
 * dragLock/tpHeld, and the pinch arming all stay internal here so they can't drift apart. Lifted
 * verbatim from InputRouter; every send goes through the injected SendFn seam (wire bytes unchanged).
 */
export class TrackpadHandler {
  private send: SendFn;

  // ── trackpad click-vs-drag (onMouse) ──
  private mouseBtn: number = 0;
  private mousePending: number = 0;
  private mouseDX: number = 0;
  private mouseDY: number = 0;
  private mousePressMs: number = 0;
  private readonly MOUSE_DRAG_GATE: number = 14;
  private readonly TAP_MAX_MS: number = 250;

  // ── trackpad-as-touch + drag-lock ──
  private tpHeld: boolean = false;
  private tpDownMs: number = 0;
  private tpFingers: number = 0;
  private dragLock: boolean = false;
  private lastTapMs: number = 0;
  private readonly DOUBLE_TAP_MS: number = 400;
  private readonly TRACKPAD_TOOL: number = 7;
  private lastAxisMs: number = 0;
  private readonly AXIS_GRACE_MS: number = 140;

  // ── pinch state machine (latched; began/ended exactly once) ──
  private pinchActive: boolean = false;
  private pinchArmed: boolean = false;
  private pinchScaleLast: number = 1;
  private pinchAccum: number = 0;
  private scrollAccum: number = 0;
  private pinchLastMs: number = 0;
  private readonly PINCH_START: number = 0.02;
  private readonly PINCH_DEADZONE: number = 0.004;
  private readonly PINCH_BIAS: number = 1.3;
  private readonly PINCH_CLAMP: number = 0.25;
  private readonly PINCH_WATCHDOG_MS: number = 250;
  private readonly PINCH_INVERT: boolean = false;

  constructor(send: SendFn) {
    this.send = send;
  }

  /** True for the integrated-trackpad tool types — the router uses this to route onTouch here. */
  isTrackpadTool(t: number): boolean {
    return t === this.TRACKPAD_TOOL || t === 3 || t === 4;
  }

  /** Trackpad contact (sourceTool=7): recover click / drag-lock at the CURSOR. */
  onTouch(event: TouchEvent): void {
    switch (event.type) {
      case TouchType.Down:
        if (!this.tpHeld) {
          this.tpHeld = true; this.tpDownMs = Date.now(); this.tpFingers = event.touches.length;
        } else {
          this.tpFingers = Math.max(this.tpFingers, event.touches.length);  // 2nd finger → right-click
        }
        break;
      case TouchType.Up:
      case TouchType.Cancel: {
        if (!this.tpHeld) { break; }
        this.tpHeld = false;
        const now: number = Date.now();
        const dt: number = now - this.tpDownMs;
        const fingers: number = this.tpFingers;
        this.tpFingers = 0;
        if (event.type !== TouchType.Up || dt >= this.TAP_MAX_MS) { break; }   // only a quick tap acts
        if (this.dragLock) {                                  // tap while drag-locked → DROP
          this.sendMouse(InputType.TouchUp, 0, 0, 0);
          this.dragLock = false; this.lastTapMs = 0;
        } else if (fingers < 2 && (now - this.lastTapMs) < this.DOUBLE_TAP_MS) {  // double-tap → GRAB
          this.sendMouse(InputType.TouchDown, 0x01, 0, 0);    // press held at the cursor
          this.dragLock = true; this.lastTapMs = 0;
        } else {                                              // single tap → click
          const btn: number = fingers >= 2 ? 0x02 : 0x01;     // 2-finger = right-click
          this.sendMouse(InputType.TouchDown, btn, 0, 0);     // click AT THE CURSOR
          this.sendMouse(InputType.TouchUp, 0, 0, 0);
          this.lastTapMs = fingers >= 2 ? 0 : now;            // only single-finger taps arm double-tap
        }
        break;
      }
      default: break;   // Move: ignore — onMouse rawDelta moves the cursor / drives the drag
    }
  }

  onMouse(e: MouseEvent): void {
    const dx: number = e.rawDeltaX ?? 0;
    const dy: number = e.rawDeltaY ?? 0;
    const isRight: boolean = (e.button === MouseButton.Right);
    switch (e.action) {
      case MouseAction.Press:
        this.mousePending = isRight ? 0x02 : 0x01;   // defer; don't press on the Mac yet
        this.mouseDX = 0; this.mouseDY = 0; this.mousePressMs = Date.now();
        break;
      case MouseAction.Release: {
        if (this.mouseBtn !== 0) {                    // was dragging → release
          this.sendMouse(InputType.TouchUp, 0, 0, 0);
          this.mouseBtn = 0;
        } else if (this.mousePending !== 0) {         // click if small net move OR quick
          const net: number = Math.sqrt(this.mouseDX * this.mouseDX + this.mouseDY * this.mouseDY);
          const dt: number = Date.now() - this.mousePressMs;
          if (net < this.MOUSE_DRAG_GATE || dt < this.TAP_MAX_MS) {
            this.sendMouse(InputType.TouchDown, this.mousePending, 0, 0);
            this.sendMouse(InputType.TouchUp, 0, 0, 0);
          }
        }
        this.mousePending = 0;
        break;
      }
      case MouseAction.Move:
        if (this.mouseBtn !== 0) {                     // already dragging
          this.sendMouse(InputType.TouchMove, this.mouseBtn, dx, dy);
        } else if (this.mousePending !== 0) {          // press held — FREEZE the cursor while
          this.mouseDX += dx; this.mouseDY += dy;       // deciding click-vs-drag, so the click lands
          const net: number = Math.sqrt(this.mouseDX * this.mouseDX + this.mouseDY * this.mouseDY);
          if (net > this.MOUSE_DRAG_GATE) {             // exactly where you pressed (jitter no longer drifts)
            this.mouseBtn = this.mousePending; this.mousePending = 0;
            this.sendMouse(InputType.TouchDown, this.mouseBtn, 0, 0);   // commit drag at the frozen point
          }
          // else: send NOTHING — cursor stays put during the press
        } else {
          this.trackpadMove(dx, dy);                                    // free move, or drag if a press is held
        }
        break;
      case MouseAction.Hover:
        this.trackpadMove(dx, dy);
        break;
      default: break;   // ENTER_WINDOW / LEAVE_WINDOW / CANCEL ignored
    }
  }

  onAxis(e: AxisEvent): void {
    this.lastAxisMs = Date.now();                 // scroll/pinch active → trackpadMove holds the cursor still
    const a: number = e.action;                 // NONE0 BEGIN1 UPDATE2 END3 CANCEL4
    const hasPinch: boolean = e.hasAxis(AxisType.PINCH_AXIS);
    const now: number = Date.now();

    if (a === AxisAction.END || a === AxisAction.CANCEL) { this.endPinch(); return; }
    if (this.pinchActive && !hasPinch && (now - this.pinchLastMs) > this.PINCH_WATCHDOG_MS) { this.endPinch(); }

    if (hasPinch) {
      const s: number = e.getPinchAxisScaleValue();
      if (a === AxisAction.BEGIN) {
        if (this.pinchActive) { this.sendZoom(2, 0); }   // self-heal an orphaned gesture
        this.pinchArmed = true; this.pinchActive = false;
        this.pinchAccum = 0; this.scrollAccum = 0;
        this.pinchScaleLast = (s > 0 ? s : 1);
        this.pinchLastMs = now;
        return;                                          // defer "began" until pinch dominates
      }
      if ((this.pinchArmed || this.pinchActive) && s > 0) {
        let ratio: number = s / this.pinchScaleLast - 1.0;   // robust: cumulative OR per-event
        this.pinchScaleLast = s;
        if (this.PINCH_INVERT) { ratio = -ratio; }
        this.pinchLastMs = now;
        if (this.pinchArmed && !this.pinchActive) {
          this.pinchAccum += Math.abs(ratio);
          if (this.pinchAccum > this.PINCH_START && this.pinchAccum > this.scrollAccum * this.PINCH_BIAS) {
            this.pinchActive = true; this.pinchArmed = false;
            this.sendZoom(1, 0);                             // single "began"
          } else { return; }
        }
        if (this.pinchActive) {
          if (Math.abs(ratio) < this.PINCH_DEADZONE) { return; }  // jitter; scaleLast already advanced
          ratio = Math.max(-this.PINCH_CLAMP, Math.min(this.PINCH_CLAMP, ratio));
          this.sendZoom(0, ratio);                              // single "changed"
        }
        return;
      }
    }
    if (!this.pinchActive) {                                     // SCROLL only when not zooming
      const sx: number = e.getHorizontalAxisValue();
      const sy: number = e.getVerticalAxisValue();
      if (sx !== 0 || sy !== 0) {
        this.scrollAccum += Math.abs(sx) + Math.abs(sy);
        this.send(InputType.Scroll, InputTool.Mouse, 0, 0, 0, 0, 0, 0, sx, sy);
      }
    }
  }

  private sendMouse(type: number, buttons: number, dx: number, dy: number): void {
    this.send(type, InputTool.Mouse, buttons, dx, dy, 0, 0, 0, 0, 0);
  }

  private trackpadMove(dx: number, dy: number): void {
    if ((Date.now() - this.lastAxisMs) < this.AXIS_GRACE_MS) { return; }  // scroll/pinch → cursor stays put
    if (this.dragLock) { this.sendMouse(InputType.TouchMove, 0x01, dx, dy); return; }  // drag in progress
    if (this.tpHeld) { return; }                            // mid-press → freeze (keeps the click precise)
    this.sendMouse(InputType.Hover, 0, dx, dy);             // free cursor move
  }

  private sendZoom(phase: number, ratio: number): void {   // x=y=0 → Mac zooms at the cursor
    this.send(InputType.Zoom, InputTool.Mouse, phase, 0, 0, 0, 0, 0, 0, ratio);
  }

  private endPinch(): void {
    if (this.pinchActive) { this.sendZoom(2, 0); }   // exactly one "ended"
    this.pinchActive = false; this.pinchArmed = false;
    this.pinchAccum = 0; this.scrollAccum = 0;
  }
}
