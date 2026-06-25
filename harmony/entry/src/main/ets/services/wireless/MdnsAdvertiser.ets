/**
 * MdnsAdvertiser — advertises the receiver on the LAN over mDNS/Bonjour (`_superconnect._tcp`) so a
 * Mac on the same Wi‑Fi auto-discovers this tablet. Driven by WirelessService: advertise ONLY after
 * the socket is listening on 0.0.0.0 (per "Pad 端只有在监听成功后才广播自己"), remove on toggle-off.
 * Part of the isolated services/wireless/ module.
 */
import mdns from '@ohos.net.mdns';
import hilog from '@ohos.hilog';
import { common } from '@kit.AbilityKit';

const SERVICE_TYPE: string = '_superconnect._tcp';

export class MdnsAdvertiser {
  private ctx: common.UIAbilityContext;
  private advertised: mdns.LocalServiceInfo | null = null;

  constructor(ctx: common.UIAbilityContext) { this.ctx = ctx; }

  /** Publish the service (removing any prior one first, so re-advertise is clean). `peerId` is published
   *  as a TXT attribute `pid` so the Mac can collapse the SAME tablet seen at two LAN IPs / over BLE vs
   *  mDNS into one card (the BLE advert carries the same identity's first 8 bytes). UUID is ASCII, so
   *  charCodeAt gives the UTF-8 bytes directly. */
  advertise(serviceName: string, port: number, peerId: string): void {
    this.unadvertise();
    const pidBytes: number[] = [];
    for (let i = 0; i < peerId.length; i++) { pidBytes.push(peerId.charCodeAt(i) & 0xff); }
    const info: mdns.LocalServiceInfo = {
      serviceType: SERVICE_TYPE,
      serviceName: serviceName,
      port: port,
      serviceAttribute: [{ key: 'pid', value: pidBytes }],
    };
    this.advertised = info;
    mdns.addLocalService(this.ctx, info).then((): void => {
      hilog.info(0x0, 'SCDIAG', 'mDNS advertised %{public}s :%{public}d', serviceName, port);
    }).catch((e: Object): void => {
      hilog.warn(0x0, 'SCDIAG', 'mDNS advertise failed %{public}s', JSON.stringify(e));
    });
  }

  /** Stop advertising (best-effort). Safe to call when not advertising. */
  unadvertise(): void {
    const info: mdns.LocalServiceInfo | null = this.advertised;
    if (info === null) { return; }
    this.advertised = null;
    mdns.removeLocalService(this.ctx, info).then((): void => {
      hilog.info(0x0, 'SCDIAG', 'mDNS removed');
    }).catch((e: Object): void => {
      hilog.warn(0x0, 'SCDIAG', 'mDNS remove failed %{public}s', JSON.stringify(e));
    });
  }
}
