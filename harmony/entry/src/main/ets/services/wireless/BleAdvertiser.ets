/**
 * BleAdvertiser — the tablet's BLE side of cross-subnet bootstrap (v0.2.2). It broadcasts a tiny
 * payload {ipv4(4B), port(2B BE), token(8B)} in the BLE ADVERTISEMENT (manufacturer data), with the
 * custom service UUID in the scan response so the Mac can filter. The Mac reads it straight from the
 * scan result — NO GATT connection. (macOS↔HarmonyOS GATT connect proved unreliable on-device: the
 * central sticks in .connecting; the advertisement, however, is received fine — so we broadcast.)
 *
 * BLE carries ONLY this bootstrap metadata — never video/input. The `token` is the proximity proof
 * the Wi-Fi pairing gate validates. Part of the isolated services/wireless/ module.
 * UUID + manufacturer id MUST match the Mac (BleDiscovery.swift).
 */
import ble from '@ohos.bluetooth.ble';
import hilog from '@ohos.hilog';

export const SC_BLE_SERVICE_UUID: string = '53430001-5343-4f4e-4e45-435400000001';
export const SC_BLE_MFR_ID: number = 0x05C0;   // private manufacturer id tagging our advert

export class BleAdvertiser {
  private advertising: boolean = false;

  /** (Re)advertise the bootstrap payload. Stops any prior advert first so ip/token changes apply. */
  advertise(payload: Uint8Array): void {
    this.stop();
    try {
      const setting: ble.AdvertiseSetting = { interval: 160, txPower: 0, connectable: false };
      const advData: ble.AdvertiseData = {
        serviceUuids: [],
        manufactureData: [{ manufactureId: SC_BLE_MFR_ID, manufactureValue: payload.buffer as ArrayBuffer }],
        serviceData: [],
        includeDeviceName: false,   // name is resolved by macOS anyway; keep the 31-byte advert small
      };
      // Service UUID in the SCAN RESPONSE (a separate 31B packet) so scanForPeripherals(withServices:)
      // matches without crowding the manufacturer-data advert.
      const advResponse: ble.AdvertiseData = {
        serviceUuids: [SC_BLE_SERVICE_UUID],
        manufactureData: [],
        serviceData: [],
      };
      ble.startAdvertising(setting, advData, advResponse);
      this.advertising = true;
      hilog.info(0x0, 'SCDIAG', 'BLE advertising (mfr payload %{public}d bytes)', payload.length);
    } catch (e) {
      hilog.warn(0x0, 'SCDIAG', 'BLE advertise failed %{public}s', JSON.stringify(e));
      this.stop();
    }
  }

  /** Stop advertising. Safe to call when not advertising. */
  stop(): void {
    if (this.advertising) {
      try { ble.stopAdvertising(); } catch (e) { hilog.warn(0x0, 'SCDIAG', 'BLE stop %{public}s', JSON.stringify(e)); }
      this.advertising = false;
    }
  }
}
