import { GestureController, Emit } from './GestureController';
import { InputSender } from './Sender';
import { InputType, InputTool, InputEvent } from '../protocol/InputCodec';

// InputRouter — the entire tablet input subsystem, lifted out of the Index page monolith:
// pen (verified pressure path), the integrated trackpad (click-vs-drag gate, drag-lock,
// two-finger scroll + the latched pinch state machine), and finger gestures (via
// GestureController). The page just forwards onTouch/onMouse/onAxis here. All gesture FSMs
// and their timing constants moved AS WHOLE UNITS, and every send goes through the
// InputSender seam — so the wire bytes are identical to the previous inline implementation.
//
// Surface size + drawing-mode are read through accessors so the page keeps owning that
// view state (the overlay's onAreaChange and the floating ball still drive them).
export class InputRouter {
  private sender: InputSender;
  private surfaceWFn: () => number;
  private surfaceHFn: () => number;
  private drawingFn: () => boolean;
  private gc: GestureController;

  // ── pen ──
  private penDown: boolean = false;   // pen currently on the glass (Down→Up)
  private penId: number = -1;         // the pen's contact id, to isolate it from fingers
  private lastPenMs: number = 0;      // timestamp of last pen activity (for palm grace)
  private readonly PALM_GRACE_MS: number = 600;

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

  constructor(sender: InputSender, surfaceW: () => number, surfaceH: () => number, drawing: () => boolean) {
    this.sender = sender;
    this.surfaceWFn = surfaceW;
    this.surfaceHFn = surfaceH;
    this.drawingFn = drawing;
    // Finger gesture state machine. Its emitted (vp) events are normalized here and
    // framed onto the INPUT channel; scroll deltas pass through in vp (Mac scales).
    this.gc = new GestureController((m: Emit): void => {
      const nx: number = (m.type === InputType.Scroll) ? 0 : Math.min(1, Math.max(0, m.x / this.surfaceWFn()));
      const ny: number = (m.type === InputType.Scroll) ? 0 : Math.min(1, Math.max(0, m.y / this.surfaceHFn()));
      this.send(m.type, m.tool, m.buttons, nx, ny, 0, 0, 0, m.scrollX, m.scrollY);
    });
  }

  private send(type: number, tool: number, buttons: number, x: number, y: number,
               pressure: number, tiltX: number, tiltY: number,
               scrollX: number, scrollY: number): void {
    const ev: InputEvent = {
      type: type, tool: tool, buttons: buttons, flags: 0,
      timestampMs: Date.now(), x: x, y: y,
      pressure: pressure, tiltX: tiltX, tiltY: tiltY,
      scrollX: scrollX, scrollY: scrollY, keyCode: 0, reserved: 0,
    };
    this.sender.sendInput(ev);
  }

  // ── public entry points (the page's gesture callbacks delegate here) ──

  // Router: pen → verified pressure path; trackpad tool → cursor click/drag; finger → gestures.
  onTouch(event: TouchEvent): void {
    if (this.surfaceWFn() <= 0 || this.surfaceHFn() <= 0) { return; }
    if (event.sourceTool === SourceTool.Pen) {
      this.lastPenMs = Date.now();
      if (event.type === TouchType.Down) {
        this.penDown = true;
        this.gc.abortForPen();   // release any held finger button; reset finger FSM
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.penDown = false;
      }
      this.sendPen(event);
      return;
    }
    // Integrated trackpad → onTouch sourceTool=7. Its x/y are contact coords, NOT a screen
    // position, so DON'T feed them to the absolute GestureController. Recover the click/drag
    // here and act at the CURSOR (movement itself comes through onMouse rawDelta).
    if (this.isTrackpadTool(event.sourceTool)) { this.handleTrackpadTouch(event); return; }
    // Smart palm rejection that does NOT block intentional finger UI taps:
    //  • always drop fingers WHILE the pen is on the glass;
    //  • in drawing mode, also drop them for a short grace after the last pen activity;
    //  • once the pen has been idle past the grace, fingers act as a TRACKPAD again.
    const sincePen: number = Date.now() - this.lastPenMs;
    const drawing: boolean = this.drawingFn();
    const rejectFinger: boolean = drawing
      ? (this.penDown || sincePen < this.PALM_GRACE_MS)
      : this.penDown;
    if (rejectFinger) { return; }
    this.gc.setDrawing(drawing);   // drawing = pointer (no ink); desktop = direct drag
    switch (event.type) {
      case TouchType.Down:   this.gc.onDown(event); break;
      case TouchType.Move:   this.gc.onMove(event); break;
      case TouchType.Up:     this.gc.onUp(event, TouchType.Up); break;
      case TouchType.Cancel: this.gc.onUp(event, TouchType.Cancel); break;
      default: break;
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

  // ── pen ──
  private sendPen(event: TouchEvent): void {
    const tiltX: number = event.tiltX ?? 0;
    const tiltY: number = event.tiltY ?? 0;

    let type: number = InputType.TouchMove;
    let buttons: number = 1;
    if (event.type === TouchType.Down) {
      type = InputType.TouchDown; buttons = 1;
      if (event.changedTouches !== undefined && event.changedTouches.length > 0) {
        this.penId = event.changedTouches[0].id;   // lock onto the pen contact
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      type = InputType.TouchUp; buttons = 0;
    }

    const pen: TouchObject | undefined = this.findPen(event);
    if (pen === undefined) { return; }

    if (type === InputType.TouchMove) {
      const hist: HistoricalPoint[] = event.getHistoricalPoints();
      if (hist !== undefined) {
        for (const hp of hist) {
          const ho: TouchObject = hp.touchObject;
          if (this.penId >= 0 && ho.id !== this.penId) { continue; } // skip finger samples
          const hx: number = Math.min(1, Math.max(0, ho.x / this.surfaceWFn()));
          const hy: number = Math.min(1, Math.max(0, ho.y / this.surfaceHFn()));
          this.send(InputType.TouchMove, InputTool.Pen, buttons, hx, hy, ho.pressure ?? 0, tiltX, tiltY, 0, 0);
        }
      }
    }

    const nx: number = Math.min(1, Math.max(0, pen.x / this.surfaceWFn()));
    const ny: number = Math.min(1, Math.max(0, pen.y / this.surfaceHFn()));
    this.send(type, InputTool.Pen, buttons, nx, ny, pen.pressure ?? 0, tiltX, tiltY, 0, 0);

    if (type === InputType.TouchUp) { this.penId = -1; }
  }

  private findPen(event: TouchEvent): TouchObject | undefined {
    if (this.penId >= 0 && event.touches !== undefined) {
      for (const t of event.touches) { if (t.id === this.penId) { return t; } }
    }
    if (event.changedTouches !== undefined && event.changedTouches.length > 0) {
      return event.changedTouches[0];
    }
    if (event.touches !== undefined && event.touches.length > 0) { return event.touches[0]; }
    return undefined;
  }

  // ── trackpad ──
  private isTrackpadTool(t: number): boolean {
    return t === this.TRACKPAD_TOOL || t === 3 || t === 4;
  }

  private sendMouse(type: number, buttons: number, dx: number, dy: number): void {
    this.send(type, InputTool.Mouse, buttons, dx, dy, 0, 0, 0, 0, 0);
  }

  private handleTrackpadTouch(event: TouchEvent): void {
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
