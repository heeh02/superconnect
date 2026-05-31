// StreamInfo — quarantined technical telemetry of the active stream, mirroring Mac
// Models/SessionTelemetry.swift. Fed from the video_config control message; shown only in
// the advanced section of the control panel, never the main flow.
export interface StreamInfo {
  width: number;
  height: number;
  codec: string;   // "h264" | "hevc"
  hdr: string;     // "off" | "pq"
}
