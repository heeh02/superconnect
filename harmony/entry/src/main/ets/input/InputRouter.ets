import { GestureController, Emit } from './GestureController';
import { InputSender, SendFn } from './Sender';
import { InputType, InputTool, InputEvent } from '../protocol/InputCodec';
import { PenHandler } from './PenHandler';
import { TrackpadHandler } from './TrackpadHandler';

// InputRouter — thin dispatcher for the tablet input subsystem. It owns the wire seam (send →
// InputSender) and routes the three event streams to cohesive, self-contained handlers:
//   • pen        → PenHandler        (verified pressure path)
//   • trackpad   → TrackpadHandler   (click/drag gate + drag-lock + scroll/pinch, one machine)
//   • finger     → GestureController (the finger gesture FSM)
// The router itself only dispatches + does finger palm-rejection (querying PenHandler's state).
// Each handler's FSM latches are internal to it, so a change to one can't affect the others; every
// send goes through the InputSender seam, so the wire bytes are identical to the inline version.
//
// Surface size + drawing-mode are read through accessors so the page keeps owning that view state.
export class InputRouter {
  private sender: InputSender;
  private surfaceWFn: () => number;
  private surfaceHFn: () => number;
  private drawingFn: () => boolean;
  private gc: GestureController;
  private pen: PenHandler;
  private trackpad: TrackpadHandler;
  private readonly PALM_GRACE_MS: number = 600;   // drop fingers this long after pen activity (drawing mode)

  constructor(sender: InputSender, surfaceW: () => number, surfaceH: () => number, drawing: () => boolean) {
    this.sender = sender;
    this.surfaceWFn = surfaceW;
    this.surfaceHFn = surfaceH;
    this.drawingFn = drawing;
    // One wire-seam owner: handlers emit through this closure, which frames onto the INPUT channel.
    const send: SendFn = (type: number, tool: number, buttons: number, x: number, y: number,
                          pressure: number, tiltX: number, tiltY: number, scrollX: number, scrollY: number): void => {
      this.send(type, tool, buttons, x, y, pressure, tiltX, tiltY, scrollX, scrollY);
    };
    this.pen = new PenHandler(send, surfaceW, surfaceH);
    this.trackpad = new TrackpadHandler(send);
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
      scrollX: scrollX, scrollY: scrollY, keyCode: 0, pointerId: 0,
    };
    this.sender.sendInput(ev);
  }

  // ── public entry points (the page's gesture callbacks delegate here) ──

  // Router: pen → verified pressure path; trackpad tool → cursor click/drag; finger → gestures.
  onTouch(event: TouchEvent): void {
    if (this.surfaceWFn() <= 0 || this.surfaceHFn() <= 0) { return; }
    if (event.sourceTool === SourceTool.Pen) {
      if (event.type === TouchType.Down) { this.gc.abortForPen(); }   // pen took over → release/reset finger FSM
      this.pen.onTouch(event);
      return;
    }
    // Integrated trackpad → onTouch sourceTool=7. Its x/y are contact coords, NOT a screen
    // position, so DON'T feed them to the absolute GestureController. The TrackpadHandler recovers
    // the click/drag and acts at the CURSOR (movement itself comes through onMouse rawDelta).
    if (this.trackpad.isTrackpadTool(event.sourceTool)) { this.trackpad.onTouch(event); return; }
    // Smart palm rejection that does NOT block intentional finger UI taps:
    //  • always drop fingers WHILE the pen is on the glass;
    //  • in drawing mode, also drop them for a short grace after the last pen activity;
    //  • once the pen has been idle past the grace, fingers act as a TRACKPAD again.
    const sincePen: number = this.pen.msSincePen();
    const drawing: boolean = this.drawingFn();
    const rejectFinger: boolean = drawing
      ? (this.pen.isPenDown() || sincePen < this.PALM_GRACE_MS)
      : this.pen.isPenDown();
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

  onMouse(e: MouseEvent): void { this.trackpad.onMouse(e); }

  onAxis(e: AxisEvent): void { this.trackpad.onAxis(e); }
}
