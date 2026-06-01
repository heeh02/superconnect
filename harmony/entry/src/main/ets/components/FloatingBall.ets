/**
 * FloatingBall — in-app draggable control that toggles drawing mode (Phase 3).
 *
 * It is the LAST child of the root Stack with a high zIndex, so ArkUI front-to-back
 * hit testing delivers touches that land ON the 56vp circle to the ball's own
 * gestures, while touches outside it fall through to the canvas overlay below.
 * No SYSTEM_FLOAT_WINDOW permission is needed — the app owns the whole screen.
 *
 * Tap = toggle drawing mode. Drag = reposition, then dock to the nearest edge.
 * Tap-vs-drag is explicit via GestureGroup(Exclusive, Tap, Pan) — a stationary
 * press resolves to Tap, a moved press to Pan. PanGesture offset is cumulative
 * from the gesture start, so we anchor on startX/startY in onActionStart.
 */
import { Theme } from '../ui/Theme';
import { BallGeometry } from './BallGeometry';

@Component
export struct FloatingBall {
  @Link drawing: boolean;
  @Link ballX: number;     // owned by Index so the dock position survives re-render
  @Link ballY: number;
  @Prop screenW: number = 0; // vp
  @Prop screenH: number = 0; // vp
  onMenu?: () => void;       // long-press → open the control panel
  @State private dragging: boolean = false;
  private startX: number = 0;
  private startY: number = 0;

  private clampY(v: number): number {
    return Math.min(this.screenH - BallGeometry.SIZE - BallGeometry.MARGIN, Math.max(BallGeometry.MARGIN, v));
  }

  private snap(): void {
    const mid: number = this.screenW / 2;
    const tx: number = (this.ballX + BallGeometry.SIZE / 2) < mid
      ? BallGeometry.MARGIN : (this.screenW - BallGeometry.SIZE - BallGeometry.MARGIN);
    const ty: number = this.clampY(this.ballY);
    animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
      this.ballX = tx;
      this.ballY = ty;
    });
  }

  build() {
    Stack() {
      Circle()
        .width(BallGeometry.SIZE).height(BallGeometry.SIZE)
        .fill(this.drawing ? Theme.ballDraw : Theme.ballIdle)
      Text(this.drawing ? '✎' : '↖')
        .fontSize(24).fontColor('#FFFFFFFF')
    }
    .width(BallGeometry.SIZE).height(BallGeometry.SIZE)
    .opacity(this.dragging ? 0.95 : 0.6)
    .shadow({ radius: 8, color: '#40000000', offsetX: 0, offsetY: 2 })
    .position({ x: this.ballX, y: this.ballY })
    .zIndex(10)
    .focusable(false)   // gesture-only; never steal keyboard focus from the hidden IME catcher (#kbd-focus)
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        LongPressGesture({ repeat: false, duration: 450 })
          .onAction((_e: GestureEvent): void => { if (this.onMenu !== undefined) { this.onMenu(); } }),
        TapGesture({ count: 1 })
          .onAction((_e: GestureEvent): void => { this.drawing = !this.drawing; }),
        PanGesture({ distance: 6 })
          .onActionStart((_e: GestureEvent): void => {
            this.dragging = true;
            this.startX = this.ballX;
            this.startY = this.ballY;
          })
          .onActionUpdate((e: GestureEvent): void => {
            this.ballX = Math.min(this.screenW - BallGeometry.SIZE, Math.max(0, this.startX + e.offsetX));
            this.ballY = Math.min(this.screenH - BallGeometry.SIZE, Math.max(0, this.startY + e.offsetY));
          })
          .onActionEnd((_e: GestureEvent): void => {
            this.dragging = false;
            this.snap();
          })
      )
    )
  }
}
