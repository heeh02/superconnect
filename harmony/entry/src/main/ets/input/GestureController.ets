/**
 * GestureController — tablet-side FINGER gesture state machine (Phase 3).
 *
 * Owns ALL finger disambiguation so the Mac can stay a near-stateless executor.
 * Pen is handled by Index BEFORE calling this class (sourceTool===Pen short-circuits
 * to the verified pen path); this state machine is finger-only.
 *
 * State table it implements (the floating ball flips `drawing`):
 *   Desktop (drawing=false):
 *     1 finger      = LEFT: move cursor + click (tap) + drag (windows/selection)
 *     2-finger tap  = RIGHT click (buttons.secondary)
 *     2-finger drag = SCROLL
 *   Drawing (drawing=true):
 *     1 finger      = DISCARDED (palm rejection — only the pen draws)
 *     2-finger tap  = RIGHT click
 *     2-finger drag = SCROLL
 *
 * Disambiguation = DEFER-THEN-COMMIT: on the first finger Down we emit NO button
 * (only a no-button Hover so the cursor tracks); a real left press is withheld for
 * TWO_WIN_MS so a second finger can promote the gesture to a 2-finger one with zero
 * stray left clicks. A fast move (> MOVE_GATE) commits early so drags stay snappy.
 * Once committed to a 1- or 2-finger class, partial lifts never re-promote/demote.
 */
import { InputType, InputTool } from '../protocol/InputCodec';

interface Pt { x: number; y: number; }

/** A semantic event the controller emits; Index normalizes x/y and frames it. */
export interface Emit {
  type: number;
  tool: number;
  buttons: number;
  x: number;        // vp (Index normalizes to [0,1])
  y: number;        // vp
  scrollX: number;  // vp centroid delta (Mac scales to wheel pixels)
  scrollY: number;  // vp centroid delta
}

enum GState { Idle, Pending, OneFinger, TwoPending, Scrolling, Pinching, Swallow }

export class GestureController {
  private readonly MOVE_GATE: number = 8;       // 1-finger move that commits a drag
  private readonly TAP_SLOP: number = 8;        // max travel for a 1-finger tap-click
  private readonly TAP_MAX_MS: number = 250;    // max duration for a 1-finger tap-click
  private readonly SCROLL_START: number = 6;    // centroid travel that latches scroll
  private readonly PINCH_START: number = 8;     // spread travel that latches pinch-zoom
  private readonly PINCH_BIAS: number = 1.3;    // winning accumulator must beat the other by 30%
  private readonly TWO_TAP_SLOP: number = 12;   // max centroid travel for a 2-finger tap
  private readonly TWO_TAP_MAX_MS: number = 300;// max duration for a 2-finger right-click
  private readonly PRIMARY: number = 0x01;
  private readonly SECONDARY: number = 0x02;

  private st: GState = GState.Idle;
  private drawing: boolean = false;
  private ids: number[] = [];
  private down: Pt = { x: 0, y: 0 };
  private last: Pt = { x: 0, y: 0 };
  private buffered: Pt[] = [];
  private downMs: number = 0;
  private maxTravel: number = 0;
  private movedOnce: boolean = false;
  private twoStart: Pt = { x: 0, y: 0 };
  private twoLast: Pt = { x: 0, y: 0 };
  private twoTravel: number = 0;
  private spreadLast: number = 0;     // inter-finger distance last move
  private spreadTravel: number = 0;   // accumulated |spread change| since 2-finger start
  private timer: number = -1;
  private readonly emit: (e: Emit) => void;

  constructor(emit: (e: Emit) => void) { this.emit = emit; }

  setDrawing(d: boolean): void { this.drawing = d; }

  private now(): number { return Date.now(); }

  private dist(a: Pt, b: Pt): number {
    const dx: number = a.x - b.x;
    const dy: number = a.y - b.y;
    return Math.sqrt(dx * dx + dy * dy);
  }

  private clearT(): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
  }

  private reset(): void {
    this.clearT();
    this.st = GState.Idle;
    this.ids = [];
    this.buffered = [];
    this.maxTravel = 0;
    this.movedOnce = false;
    this.twoTravel = 0;
    this.spreadTravel = 0;
    this.downMs = 0;
  }

  private fire(type: number, buttons: number, p: Pt): void {
    this.emit({ type: type, tool: InputTool.Finger, buttons: buttons,
                x: p.x, y: p.y, scrollX: 0, scrollY: 0 });
  }

  private fireScroll(dx: number, dy: number): void {
    this.emit({ type: InputType.Scroll, tool: InputTool.Finger, buttons: 0,
                x: 0, y: 0, scrollX: dx, scrollY: dy });
  }

  /** Zoom (magnify gesture): scrollY = per-frame magnification delta (ratio; + = zoom in),
   *  x/y = centroid (cursor anchor), buttons = phase (1=began, 0=changed, 2=ended). */
  private fireZoom(delta: number, c: Pt, phase: number): void {
    this.emit({ type: InputType.Zoom, tool: InputTool.Finger, buttons: phase,
                x: c.x, y: c.y, scrollX: 0, scrollY: delta });
  }

  /** The two tracked finger contacts still present. */
  private twoPts(ts: TouchObject[]): TouchObject[] {
    const out: TouchObject[] = [];
    for (const t of ts) { if (this.ids.indexOf(t.id) >= 0) { out.push(t); } }
    return out;
  }

  /** Inter-finger distance; falls back to last value if a finger is momentarily absent. */
  private spread(ts: TouchObject[]): number {
    const p: TouchObject[] = this.twoPts(ts);
    if (p.length < 2) { return this.spreadLast; }
    return this.dist({ x: p[0].x, y: p[0].y }, { x: p[1].x, y: p[1].y });
  }

  private find(ts: TouchObject[], id: number): TouchObject | undefined {
    for (const t of ts) { if (t.id === id) { return t; } }
    return undefined;
  }

  /** Centroid of the tracked ids that are still present; falls back to last centroid. */
  private centroid(ts: TouchObject[]): Pt {
    let sx: number = 0;
    let sy: number = 0;
    let n: number = 0;
    for (const t of ts) {
      if (this.ids.indexOf(t.id) >= 0) { sx += t.x; sy += t.y; n += 1; }
    }
    return n > 0 ? { x: sx / n, y: sy / n } : this.twoLast;
  }

  /** Fingers still on the glass AFTER this event, robust to either ArkUI semantics
   *  for whether event.touches still lists a finger that this event lifted. */
  private stillDown(ev: TouchEvent): TouchObject[] {
    const ch: TouchObject[] = ev.changedTouches;
    const out: TouchObject[] = [];
    for (const t of ev.touches) {
      let lifted: boolean = false;
      for (const c of ch) { if (c.id === t.id) { lifted = true; break; } }
      if (!lifted) { out.push(t); }
    }
    return out;
  }

  onDown(ev: TouchEvent): void {
    const live: TouchObject[] = ev.touches;
    const ch: TouchObject[] = ev.changedTouches;

    // Two (or more) fingers reported within a single Down callback.
    if (this.st === GState.Idle && live.length >= 2) {
      this.ids = [];
      for (const t of live) { this.ids.push(t.id); }
      this.enterTwo(live);
      return;
    }

    // First finger lands.
    if (this.st === GState.Idle && live.length === 1) {
      const t: TouchObject | undefined = ch.length > 0 ? ch[0] : undefined;
      if (t === undefined) { return; }
      this.ids = [t.id];
      this.down = { x: t.x, y: t.y };
      this.last = this.down;
      this.buffered = [this.down];
      this.downMs = this.now();
      this.maxTravel = 0;
      this.movedOnce = false;
      this.st = GState.Pending;
      this.fire(InputType.Hover, 0, this.down);   // warp cursor, no button yet
      // We never press on a timer: a stationary finger that lifts becomes a CLICK
      // (in onUp), and a finger that MOVES past MOVE_GATE commits a left-drag. Pressing
      // on dwell turned slow taps into long-presses, so the press is deferred until
      // there is real intent (move = drag, lift = click). A 2nd finger still promotes
      // to a 2-finger gesture via onDown, and since nothing was pressed there is no
      // stray click.
      return;
    }

    // Second finger arrives during the pending window → 2-finger gesture.
    // (No button was pressed in Pending — only Hover — so nothing to release.)
    if (this.st === GState.Pending) {
      const t: TouchObject | undefined = ch.length > 0 ? ch[0] : undefined;
      if (t === undefined || this.ids.indexOf(t.id) >= 0) { return; }
      this.clearT();
      this.ids.push(t.id);
      this.enterTwo(live);
      return;
    }

    // Extra finger during a committed one-finger drag → remember id, keep dragging.
    if (this.st === GState.OneFinger) {
      const t: TouchObject | undefined = ch.length > 0 ? ch[0] : undefined;
      if (t !== undefined && this.ids.indexOf(t.id) < 0) { this.ids.push(t.id); }
      return;
    }
  }

  private enterTwo(live: TouchObject[]): void {
    const c: Pt = this.centroid(live);
    this.twoStart = c;
    this.twoLast = c;
    this.twoTravel = 0;
    this.spreadLast = this.spread(live);   // seed inter-finger distance
    this.spreadTravel = 0;
    this.downMs = this.now();   // 2-finger start; covers simultaneous AND promoted landings
    this.st = GState.TwoPending;
  }

  private commitOne(): void {
    this.clearT();
    if (this.drawing) { return; }   // pointer mode never presses — the pen owns ink
    this.st = GState.OneFinger;
    this.movedOnce = true;
    this.fire(InputType.TouchDown, this.PRIMARY, this.down);
    for (const p of this.buffered) { this.fire(InputType.TouchMove, this.PRIMARY, p); }
  }

  onMove(ev: TouchEvent): void {
    const live: TouchObject[] = ev.touches;

    if (this.st === GState.Pending) {
      const t: TouchObject | undefined = this.find(live, this.ids[0]);
      if (t === undefined) { return; }
      const cur: Pt = { x: t.x, y: t.y };
      this.buffered.push(cur);
      this.maxTravel = Math.max(this.maxTravel, this.dist(cur, this.down));
      this.last = cur;
      if (!this.drawing && this.maxTravel > this.MOVE_GATE) {
        this.commitOne();   // direct mode: start a left-drag; replays buffered as TouchMove
      } else {
        this.fire(InputType.Hover, 0, cur);   // pointer/deferred: cursor follows, no ink
      }
      return;
    }

    if (this.st === GState.OneFinger) {
      const t: TouchObject | undefined = this.find(live, this.ids[0]);
      if (t === undefined) { return; }
      const hist: HistoricalPoint[] = ev.getHistoricalPoints();
      if (hist !== undefined) {
        for (const hp of hist) {
          const ho: TouchObject = hp.touchObject;
          if (ho.id === this.ids[0]) {   // ONLY the tracked finger; ignore resting contacts
            this.fire(InputType.TouchMove, this.PRIMARY, { x: ho.x, y: ho.y });
          }
        }
      }
      this.last = { x: t.x, y: t.y };
      this.fire(InputType.TouchMove, this.PRIMARY, this.last);
      return;
    }

    if (this.st === GState.TwoPending || this.st === GState.Scrolling || this.st === GState.Pinching) {
      const c: Pt = this.centroid(live);
      const curSpread: number = this.spread(live);
      const dSpread: number = curSpread - this.spreadLast;
      this.twoTravel += this.dist(c, this.twoLast);
      this.spreadTravel += Math.abs(dSpread);
      // First accumulator to dominate (by PINCH_BIAS) wins, then sticky for the gesture.
      if (this.st === GState.TwoPending) {
        if (this.spreadTravel > this.PINCH_START && this.spreadTravel > this.twoTravel * this.PINCH_BIAS) {
          this.st = GState.Pinching;
          this.fireZoom(0, c, 1);   // magnify BEGAN
        } else if (this.twoTravel > this.SCROLL_START && this.twoTravel >= this.spreadTravel * this.PINCH_BIAS) {
          this.st = GState.Scrolling;
        }
      }
      if (this.st === GState.Scrolling) {
        this.fireScroll(c.x - this.twoLast.x, c.y - this.twoLast.y);
      } else if (this.st === GState.Pinching) {
        const ratio: number = this.spreadLast > 0 ? (curSpread / this.spreadLast - 1.0) : 0;
        this.fireZoom(ratio, c, 0);   // magnify CHANGED (per-frame fractional delta)
      }
      this.twoLast = c;
      this.spreadLast = curSpread;
      return;
    }
  }

  /** etype lets Cancel suppress the synthetic tap-click so a button never sticks. */
  onUp(ev: TouchEvent, etype: TouchType): void {
    const remaining: TouchObject[] = this.stillDown(ev);
    const dt: number = this.now() - this.downMs;

    if (this.st === GState.Pending) {
      this.clearT();
      if (etype !== TouchType.Cancel) {
        const upPt: Pt = this.buffered.length > 0 ? this.buffered[this.buffered.length - 1] : this.down;
        this.maxTravel = Math.max(this.maxTravel, this.dist(upPt, this.down));
        const tap: boolean = this.maxTravel < this.TAP_SLOP && dt < this.TAP_MAX_MS;
        if (tap) {
          this.fire(InputType.TouchDown, this.PRIMARY, this.down);  // tap → left click (UI buttons)
          this.fire(InputType.TouchUp, 0, this.down);
        } else if (!this.drawing) {
          this.fire(InputType.TouchDown, this.PRIMARY, this.down);  // direct-mode slow drift → click
          this.fire(InputType.TouchUp, 0, upPt);
        }
        // pointer mode (drawing) + non-tap = finger just moved the cursor → no ink, no click
      }
      this.reset();
      return;
    }

    if (this.st === GState.OneFinger) {
      // End the drag only when the PRIMARY finger lifts; other fingers are benign.
      if (this.find(remaining, this.ids[0]) !== undefined) { return; }
      this.fire(InputType.TouchUp, 0, this.last);
      this.reset();
      return;
    }

    if (this.st === GState.TwoPending) {
      if (etype !== TouchType.Cancel && dt < this.TWO_TAP_MAX_MS && this.twoTravel < this.TWO_TAP_SLOP) {
        this.fire(InputType.TouchDown, this.SECONDARY, this.twoStart); // 2-finger tap → right click
        this.fire(InputType.TouchUp, 0, this.twoStart);
      }
      if (remaining.length === 0) { this.reset(); } else { this.st = GState.Swallow; }
      return;
    }

    if (this.st === GState.Scrolling) {
      if (remaining.length === 0) { this.reset(); } else { this.st = GState.Swallow; }
      return;
    }

    if (this.st === GState.Pinching) {
      this.fireZoom(0, this.twoLast, 2);   // magnify ENDED
      if (remaining.length === 0) { this.reset(); } else { this.st = GState.Swallow; }
      return;
    }

    if (this.st === GState.Swallow) {
      if (remaining.length === 0) { this.reset(); }
      return;
    }

    this.reset();
  }

  /** Pen took over mid finger-gesture (Index calls this when sourceTool===Pen). */
  abortForPen(): void {
    if (this.st === GState.OneFinger || this.movedOnce) {
      this.fire(InputType.TouchUp, 0, this.last);   // release any held left button
    }
    this.reset();
  }
}
