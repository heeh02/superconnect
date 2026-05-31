// Role — the direction of a live link, mirroring Mac Models/Role.swift.
// The tablet is a Receiver today; Host is the symmetric-future seam.
export enum Role {
  Receiver,   // be cast to (decode + display + capture local input) — REAL on the tablet today
  Host,       // cast this device's screen out — future (HostConnection.ets stub)
}

// What a peer CAN do (bitmask), mirroring Mac RoleCapabilities. The tablet publishes
// CanReceive today; CanHost is added when tablet-as-host lands.
export enum RoleCapability {
  CanHost = 1,
  CanReceive = 2,
}
