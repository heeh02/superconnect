/**
 * DeviceIdentity — the tablet's human-friendly name, shared by the wireless module (mDNS service
 * name) and the session handshake (hello_ack deviceName) so the Mac shows the real device, e.g.
 * "HUAWEI MatePad Pro", instead of a hardcoded label. No special permission needed for marketName.
 */
import deviceInfo from '@ohos.deviceInfo';
import hilog from '@ohos.hilog';

export function deviceDisplayName(): string {
  try {
    const market: string = deviceInfo.marketName;
    if (market.length > 0) { return market; }
    const model: string = deviceInfo.productModel;
    if (model.length > 0) { return model; }
  } catch (e) {
    hilog.warn(0x0, 'SCDIAG', 'deviceDisplayName failed %{public}s', JSON.stringify(e));
  }
  return 'Superconnect Pad';
}
