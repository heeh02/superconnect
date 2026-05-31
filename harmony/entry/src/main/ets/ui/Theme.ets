/**
 * Theme — the single source of truth for Superconnect's visual language. Centralizing
 * tokens here is what keeps the design unified and easy to retune. Adaptive surface/text
 * colors still use system resources at the call site (auto light/dark); this holds the
 * brand accent, status colors, geometry, and type scale.
 */
export class Theme {
  // Brand accent — a clean, cool tone that pairs with the silver/constellation icon.
  static readonly accent: string = '#4E7CF6';
  static readonly accentDim: string = '#1A4E7CF6';

  // Status
  static readonly ok: string = '#30D158';       // connected / streaming (green)
  static readonly waiting: string = '#FF9F0A';  // waiting (amber)
  static readonly busy: string = '#0A84FF';     // connecting (blue)

  // Floating ball
  static readonly ballDraw: string = '#E64E7CF6';
  static readonly ballIdle: string = '#99202832';

  // Geometry
  static readonly radius: number = 16;
  static readonly radiusLg: number = 22;
  static readonly gap: number = 12;
  static readonly pad: number = 16;

  // Type scale (vp)
  static readonly title: number = 30;
  static readonly heading: number = 20;
  static readonly body: number = 15;
  static readonly small: number = 13;
  static readonly caption: number = 12;
}
