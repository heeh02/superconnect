import { SendFn } from './Sender';
import { InputType, InputTool } from '../protocol/InputCodec';

/**
 * PenHandler — the M-Pencil input path: real pressure + tilt, high-rate history replay, isolated
 * from finger contacts by tracking the pen's contact id. Owns the pen state; the router queries
 * isPenDown() / msSincePen() to drive finger palm-rejection. Lifted verbatim from InputRouter — the
 * wire output is unchanged (every send goes through the injected SendFn seam).
 */
export class PenHandler {
  private send: SendFn;
  private surfaceWFn: () => number;
  private surfaceHFn: () => number;

  private penDown: boolean = false;   // pen currently on the glass (Down→Up)
  private penId: number = -1;         // the pen's contact id, to isolate it from fingers
  private lastPenMs: number = 0;      // timestamp of last pen activity (for palm grace)

  constructor(send: SendFn, surfaceW: () => number, surfaceH: () => number) {
    this.send = send;
    this.surfaceWFn = surfaceW;
    this.surfaceHFn = surfaceH;
  }

  /** Pen on the glass right now (router uses this for palm rejection). */
  isPenDown(): boolean { return this.penDown; }
  /** Milliseconds since the last pen activity (router's palm-grace window). */
  msSincePen(): number { return Date.now() - this.lastPenMs; }

  /** Handle a pen TouchEvent (sourceTool === Pen): update pen state + emit the pressure path. */
  onTouch(event: TouchEvent): void {
    this.lastPenMs = Date.now();
    if (event.type === TouchType.Down) {
      this.penDown = true;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.penDown = false;
    }
    this.sendPen(event);
  }

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
}
