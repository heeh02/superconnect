/**
 * BleAdvertiser — the tablet's BLE PERIPHERAL side of cross-subnet bootstrap (v0.2.2). It runs a GATT
 * server exposing ONE custom 128-bit service with ONE readable characteristic that returns a compact
 * JSON bootstrap blob {n:deviceName, ip, p:port, tok:token, pid:peerId}, and advertises the service
 * UUID over BLE. A Mac (CoreBluetooth central) scans by service UUID, connects, reads the blob, then
 * connects over Wi-Fi as usual — so this works even when the Mac and tablet are on different subnets
 * (mDNS can't cross them). BLE carries ONLY bootstrap metadata + the pairing token — never video/input.
 *
 * Security model: the characteristic is UNENCRYPTED (no SMP bonding — keeps macOS↔HarmonyOS sane); the
 * `tok` is the proximity proof validated by the Wi-Fi pairing gate (WirelessService). Part of the
 * isolated services/wireless/ module — a BT bug here can't touch the wired or video path.
 *
 * UUIDs MUST match the Mac (BleDiscovery.swift).
 */
import ble from '@ohos.bluetooth.ble';
import hilog from '@ohos.hilog';

export const SC_BLE_SERVICE_UUID: string = '53430001-5343-4f4e-4e45-435400000001';
export const SC_BLE_CHAR_UUID: string = '53430002-5343-4f4e-4e45-435400000001';

export class BleAdvertiser {
  private server: ble.GattServer | null = null;
  private advertising: boolean = false;
  // Returns the CURRENT bootstrap bytes on demand, so a read always reflects the live ip/port/token.
  private blobProvider: () => Uint8Array = (): Uint8Array => new Uint8Array(0);
  private readonly onRead: (req: ble.CharacteristicReadRequest) => void = (req: ble.CharacteristicReadRequest): void => {
    if (this.server === null) { return; }
    const full: Uint8Array = this.blobProvider();
    const off: number = req.offset ?? 0;
    const slice: Uint8Array = off > 0 && off < full.length ? full.subarray(off) : full;
    try {
      this.server.sendResponse({
        deviceId: req.deviceId,
        transId: req.transId,
        status: 0,
        offset: off,
        value: slice.buffer as ArrayBuffer,
      });
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'BLE sendResponse failed %{public}s', JSON.stringify(e));
    }
  };

  /** Start advertising + serving the bootstrap blob. Idempotent-ish: stops any prior server first. */
  start(blobProvider: () => Uint8Array): void {
    this.stop();
    this.blobProvider = blobProvider;
    try {
      const server: ble.GattServer = ble.createGattServer();
      const initial: Uint8Array = blobProvider();
      const characteristic: ble.BLECharacteristic = {
        serviceUuid: SC_BLE_SERVICE_UUID,
        characteristicUuid: SC_BLE_CHAR_UUID,
        characteristicValue: initial.buffer as ArrayBuffer,
        descriptors: [],
        properties: { read: true, notify: true, write: false, writeNoResponse: false, indicate: false },
        permissions: { read: true },   // UNENCRYPTED read → no OS pairing/bonding
      };
      const service: ble.GattService = {
        serviceUuid: SC_BLE_SERVICE_UUID,
        isPrimary: true,
        characteristics: [characteristic],
      };
      server.addService(service);
      server.on('characteristicRead', this.onRead);
      this.server = server;

      const setting: ble.AdvertiseSetting = { interval: 160, txPower: 0, connectable: true };
      const advData: ble.AdvertiseData = {
        serviceUuids: [SC_BLE_SERVICE_UUID],   // only the service UUID fits alongside discovery
        manufactureData: [],
        serviceData: [],
        includeDeviceName: false,              // names go in the GATT blob, not the advert (size)
      };
      ble.startAdvertising(setting, advData);
      this.advertising = true;
      hilog.info(0x0, 'SCDIAG', 'BLE advertising %{public}s', SC_BLE_SERVICE_UUID);
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'BLE start failed (BT off / no perm?) %{public}s', JSON.stringify(e));
      this.stop();
    }
  }

  /** Stop advertising + tear down the GATT server. Safe to call when not advertising. */
  stop(): void {
    if (this.advertising) {
      try { ble.stopAdvertising(); } catch (e) { hilog.warn(0x0, 'SCDIAG', 'BLE stopAdvertising %{public}s', JSON.stringify(e)); }
      this.advertising = false;
    }
    if (this.server !== null) {
      const s: ble.GattServer = this.server;
      this.server = null;
      try { s.off('characteristicRead', this.onRead); } catch (e) { /* best-effort */ }
      try { s.close(); } catch (e) { hilog.warn(0x0, 'SCDIAG', 'BLE server close %{public}s', JSON.stringify(e)); }
    }
  }
}
