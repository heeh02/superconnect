// Type declarations for the native module `libsuperconnect.so`.
// ArkTS: import sc from 'libsuperconnect.so'

/** Set the incoming video resolution (backing pixels) before frames arrive. */
export const setVideoSize: (width: number, height: number) => void;

/** Feed one Annex-B H.264/HEVC access unit (may include parameter sets on keyframes). */
export const pushVideo: (data: Uint8Array, isKeyframe: boolean) => void;

/** True if the device has a HARDWARE HEVC decoder. */
export const supportsHevc: () => boolean;

/** HW HEVC decoder 10-bit/HDR support, bitmask: bit0=Main10 (10-bit), bit1=Main10 HDR10 (PQ). */
export const hdrDecodeCaps: () => number;

/** Select the decoder codec ("h264" | "hevc") before frames arrive. */
export const setCodec: (codec: string) => void;

/** Enable HDR decode/presentation ("off" | "hlg" | "pq") before frames arrive. */
export const setHdr: (mode: string) => void;
