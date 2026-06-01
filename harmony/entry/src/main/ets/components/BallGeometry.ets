/**
 * Single source of truth for the floating ball's size + margin, and the page-side seed/clamp math.
 *
 * Why this exists: SIZE(56) / MARGIN(12) were duplicated in Index.ets (onAreaChange seed+clamp) and
 * FloatingBall.ets (drag/snap), and a third copy drove the restore handle — a change in one place
 * silently disagreed with the others (no compile error). This is the same coupling class as the #53
 * keyboard bug: a value that must agree across a boundary with no owner. Now there is one owner.
 *
 * seed()/clamp() reproduce Index.ets's original onAreaChange arithmetic EXACTLY (behaviour-preserving);
 * FloatingBall keeps its own drag/snap formulas but reads SIZE/MARGIN from here.
 */
export interface BallPos {
  x: number;
  y: number;
}

export class BallGeometry {
  static readonly SIZE: number = 56;
  static readonly MARGIN: number = 12;

  /** Initial dock: right edge, vertically centered (was `w-56-12`, `h/2-28`). */
  static seed(w: number, h: number): BallPos {
    return { x: w - BallGeometry.SIZE - BallGeometry.MARGIN, y: h / 2 - BallGeometry.SIZE / 2 };
  }

  /** Keep the ball on-screen within the margin (was the Math.min(Math.max(...)) pair). */
  static clamp(x: number, y: number, w: number, h: number): BallPos {
    const maxX: number = w - BallGeometry.SIZE - BallGeometry.MARGIN;
    const maxY: number = h - BallGeometry.SIZE - BallGeometry.MARGIN;
    return {
      x: Math.min(Math.max(x, BallGeometry.MARGIN), maxX),
      y: Math.min(Math.max(y, BallGeometry.MARGIN), maxY),
    };
  }
}
