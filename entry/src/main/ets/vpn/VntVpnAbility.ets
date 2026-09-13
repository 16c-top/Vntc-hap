import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { common, Want, wantAgent } from '@kit.AbilityKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import vntNapi from 'libvnt_napi.so';
import { VPN_STATUS_EVENT } from './VpnConst';

const DOMAIN: number = 0x0056;
const TAG: string = 'VntVpnAbility';
const BUNDLE_NAME: string = 'top.16c.vntc';
const DEFAULT_MTU: number = 1400;
const HEARTBEAT_MS: number = 2000;
const NOTIFY_ID: number = 100;
const NOTIFY_REFRESH_MS: number = 10000;

interface VpnParams {
  server: string;
  token: string;
  password: string;
  deviceId: string;
  name: string;
  virtualIp: string;
  mtu: number;
  useChannel: number;
  stunServers: string;
  nameServers: string;
  ports: string;
  cipherModel: number;
  compressor: number;
  serverEncrypt: number;
  finger: number;
  enableTraffic: number;
}

export default class VntVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  private heartbeatId: number = -1;
  private eventText: string = '';
  private lastError: string = '';
  private tunVirtualIp: string = '';
  private params: VpnParams | undefined = undefined;
  private routesApplied: boolean = false;
  private rebuilding: boolean = false;
  private suppressStatus: boolean = false;
  private startAt: number = 0;
  private lastNotify: number = 0;
  private launchAgent: object | undefined = undefined;

  onCreate(want: Want): void {
    this.setupVpn(want);
  }

  onDestroy(): void {
    if (this.heartbeatId >= 0) {
      clearInterval(this.heartbeatId);
      this.heartbeatId = -1;
    }
    vntNapi.setEventListener(null);
    vntNapi.stop();
    this.suppressStatus = false;
    this.eventText = '连接已断开';
    this.publishStatus();
    this.cancelKeepAliveNotification();
    this.teardown();
  }

  private async setupVpn(want: Want): Promise<void> {
    try {
      const params: VpnParams = this.readParams(want);
      this.params = params;

      vntNapi.setEventListener((event: number, json: string): void => {
        this.onVntEvent(event, json);
      });

      hilog.info(DOMAIN, TAG, 'phase 1: start vnt without tun to learn gateway');
      let ok: boolean = vntNapi.start(-1, params.token, params.deviceId, params.name,
        params.server, params.password, params.virtualIp, params.mtu, params.useChannel,
        params.stunServers, params.nameServers, params.ports, params.cipherModel,
        params.compressor, params.serverEncrypt, params.finger, params.enableTraffic);
      if (!ok) {
        hilog.warn(DOMAIN, TAG, 'start without tun failed: %{public}s, fallback to placeholder tun',
          vntNapi.lastError());
        const tunIp: string = params.virtualIp;
        const conn: vpnExtension.VpnConnection =
          vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
        this.vpnConnection = conn;
        const cfg: vpnExtension.VpnConfig = {
          addresses: [{
            address: { address: tunIp, family: 1 },
            prefixLength: 24
          }],
          mtu: params.mtu,
          isIPv4Accepted: true,
          dnsAddresses: ['223.5.5.5', '114.114.114.114'],
          blockedApplications: [BUNDLE_NAME]
        };
        const tunFd: number = await conn.create(cfg);
        hilog.info(DOMAIN, TAG, 'tun fd: %{public}d', tunFd);
        ok = vntNapi.start(tunFd, params.token, params.deviceId, params.name,
          params.server, params.password, tunIp, params.mtu, params.useChannel,
          params.stunServers, params.nameServers, params.ports, params.cipherModel,
          params.compressor, params.serverEncrypt, params.finger, params.enableTraffic);
      }
      if (!ok) {
        this.lastError = vntNapi.lastError();
        hilog.error(DOMAIN, TAG, 'vnt start failed: %{public}s', this.lastError);
        vntNapi.setEventListener(null);
        this.suppressStatus = false;
        this.eventText = 'vnt 启动失败';
        this.publishStatus();
        this.teardown();
        return;
      }
      hilog.info(DOMAIN, TAG, 'vnt started');
      this.suppressStatus = true;
      this.startAt = Date.now();
      this.updateKeepAliveNotification(true);

      this.heartbeatId = setInterval((): void => {
        this.publishStatus();
        this.updateKeepAliveNotification(false);
      }, HEARTBEAT_MS);
      this.publishStatus();
    } catch (e) {
      const msg: string = JSON.stringify(e) ?? '';
      hilog.error(DOMAIN, TAG, 'setup vpn error: %{public}s', msg);
      this.lastError = msg;
      this.eventText = '连接创建失败';
      this.publishStatus();
      this.teardown();
    }
  }

  private onVntEvent(event: number, json: string): void {
    hilog.info(DOMAIN, TAG, 'vnt event: %{public}d, json: %{public}s', event, json);
    if (event === 0) {
      this.eventText = '连接成功';
      this.lastError = '';
    } else if (event === 1) {
      this.eventText = '注册成功，已获取虚拟 IP';
      this.lastError = '';
    } else if (event === 2) {
      this.eventText = this.describeTunInfo(json);
      if (!this.routesApplied) {
        this.applyRoutes(json);
      }
    } else if (event === 3) {
      this.eventText = this.describePeers(json);
    } else if (event === 4) {
      if (this.rebuilding) {
        return;
      }
      const errText: string = this.describeError(json);
      this.eventText = '发生错误，请查看下方错误信息';
      this.lastError = errText;
    } else if (event === 5) {
      if (this.rebuilding) {
        return;
      }
      this.eventText = '内核已停止';
    }
    this.publishStatus();
  }

  private describeError(json: string): string {
    let code: string = '';
    let msg: string = '';
    try {
      const err: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const codeVal: Object | undefined = err['code'];
      if (typeof codeVal === 'string') {
        code = codeVal;
      }
      const msgVal: Object | undefined = err['msg'];
      if (typeof msgVal === 'string') {
        msg = msgVal;
      }
    } catch (e) {
      return json !== '' ? json : '未知错误';
    }
    const friendly: string = this.errorText(code);
    return msg !== '' ? `${friendly}（${msg}）` : friendly;
  }

  private errorText(code: string): string {
    if (code === 'TokenError') {
      return 'Token 错误：服务端拒绝了当前令牌，请检查令牌与服务端是否一致';
    }
    if (code === 'Disconnect') {
      return '服务端断开连接，将自动尝试重新连接';
    }
    if (code === 'AddressExhausted') {
      return '虚拟 IP 地址池已耗尽，没有可用 IP 分配';
    }
    if (code === 'IpAlreadyExists') {
      return '虚拟 IP 已被其他设备占用，请更换 IP 或留空自动分配';
    }
    if (code === 'InvalidIp') {
      return '请求的虚拟 IP 无效，请检查格式';
    }
    if (code === 'LocalIpExists') {
      return '本机 IP 冲突';
    }
    if (code === 'FailedToCrateDevice') {
      return '虚拟网卡创建失败';
    }
    if (code === 'Warn') {
      return '警告：部分功能异常，不阻塞运行';
    }
    if (code === 'Unknown') {
      return '未知错误';
    }
    return code !== '' ? code : '未知错误';
  }

  private parseTunInfo(json: string): Record<string, Object> {
    const info: Record<string, Object> = {};
    try {
      const parsed: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const vipVal: Object | undefined = parsed['virtual_ip'];
      if (typeof vipVal === 'string') {
        info['virtual_ip'] = vipVal;
      }
      const maskVal: Object | undefined = parsed['netmask'];
      if (typeof maskVal === 'string') {
        info['netmask'] = maskVal;
      }
      const gwVal: Object | undefined = parsed['gateway'];
      if (typeof gwVal === 'string') {
        info['gateway'] = gwVal;
      }
      const mtuVal: Object | undefined = parsed['mtu'];
      if (typeof mtuVal === 'number') {
        info['mtu'] = mtuVal;
      }
    } catch (e) {
      // ignore
    }
    return info;
  }

  private applyRoutes(json: string): void {
    const info: Record<string, Object> = this.parseTunInfo(json);
    const vipVal: Object | undefined = info['virtual_ip'];
    const maskVal: Object | undefined = info['netmask'];
    const gwVal: Object | undefined = info['gateway'];
    if (typeof vipVal !== 'string' || vipVal === '' ||
      typeof maskVal !== 'string' || maskVal === '' ||
      typeof gwVal !== 'string' || gwVal === '') {
      return;
    }
    const prefix: number = this.netmaskToPrefix(maskVal);
    const network: string = this.subnetOf(gwVal, maskVal);
    if (prefix <= 0 || network === '') {
      return;
    }
    this.routesApplied = true;
    this.rebuildVpn(vipVal, prefix, network, gwVal);
  }

  private async rebuildVpn(vip: string, prefix: number, network: string, gateway: string): Promise<void> {
    const params: VpnParams | undefined = this.params;
    if (params === undefined || this.rebuilding) {
      return;
    }
    this.rebuilding = true;
    hilog.info(DOMAIN, TAG, 'rebuild vpn with vip=%{public}s prefix=%{public}d net=%{public}s gw=%{public}s',
      vip, prefix, network, gateway);
    vntNapi.stop();
    const old: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (old !== undefined) {
      try {
        await old.destroy();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'old vpn destroy failed: %{public}s', JSON.stringify(e) ?? '');
      }
      this.vpnConnection = undefined;
    }
    try {
      const conn: vpnExtension.VpnConnection =
        vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
      this.vpnConnection = conn;
      const cfg: vpnExtension.VpnConfig = {
        addresses: [{
          address: { address: vip, family: 1 },
          prefixLength: prefix
        }],
        routes: [{
          interface: 'vpn-tun',
          destination: { address: { address: network, family: 1 }, prefixLength: prefix },
          gateway: { address: gateway, family: 1 },
          hasGateway: true,
          isDefaultRoute: false
        }],
        mtu: params.mtu,
        isIPv4Accepted: true,
        dnsAddresses: ['223.5.5.5', '114.114.114.114'],
        blockedApplications: [BUNDLE_NAME]
      };
      const tunFd: number = await conn.create(cfg);
      const ok: boolean = vntNapi.start(tunFd, params.token, params.deviceId, params.name,
        params.server, params.password, vip, params.mtu, params.useChannel,
        params.stunServers, params.nameServers, params.ports, params.cipherModel,
        params.compressor, params.serverEncrypt, params.finger, params.enableTraffic);
      if (!ok) {
        this.lastError = vntNapi.lastError();
        this.eventText = '连接重建失败';
        hilog.error(DOMAIN, TAG, 'vnt restart failed: %{public}s', this.lastError);
      }
    } catch (e) {
      this.eventText = '连接重建失败';
      hilog.error(DOMAIN, TAG, 'rebuild vpn error: %{public}s', JSON.stringify(e) ?? '');
    }
    this.rebuilding = false;
    this.suppressStatus = false;
    this.publishStatus();
  }

  private netmaskToPrefix(netmask: string): number {
    const parts: Array<string> = netmask.split('.');
    if (parts.length !== 4) {
      return -1;
    }
    const valid: Array<number> = [0, 128, 192, 224, 240, 248, 252, 254, 255];
    let prefix: number = 0;
    for (let i = 0; i < 4; i++) {
      const n: number = Number(parts[i]);
      let bits: number = -1;
      for (let j = 0; j < valid.length; j++) {
        if (valid[j] === n) {
          bits = j;
          break;
        }
      }
      if (bits < 0) {
        return -1;
      }
      prefix += bits;
    }
    return prefix;
  }

  private subnetOf(gateway: string, netmask: string): string {
    const g: Array<string> = gateway.split('.');
    const m: Array<string> = netmask.split('.');
    if (g.length !== 4 || m.length !== 4) {
      return '';
    }
    const out: Array<string> = [];
    for (let i = 0; i < 4; i++) {
      const gi: number = Number(g[i]);
      const mi: number = Number(m[i]);
      if (gi < 0 || gi > 255 || mi < 0 || mi > 255) {
        return '';
      }
      out.push(`${(gi & mi) & 0xFF}`);
    }
    return out.join('.');
  }

  private describeTunInfo(json: string): string {
    let vip: string = '';
    let netmask: string = '';
    let gateway: string = '';
    let mtu: number = 0;
    try {
      const info: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const vipVal: Object | undefined = info['virtual_ip'];
      if (typeof vipVal === 'string') {
        vip = vipVal;
      }
      const maskVal: Object | undefined = info['netmask'];
      if (typeof maskVal === 'string') {
        netmask = maskVal;
      }
      const gwVal: Object | undefined = info['gateway'];
      if (typeof gwVal === 'string') {
        gateway = gwVal;
      }
      const mtuVal: Object | undefined = info['mtu'];
      if (typeof mtuVal === 'number') {
        mtu = mtuVal;
      }
    } catch (e) {
      return '虚拟网卡信息就绪';
    }
    if (vip !== '') {
      this.tunVirtualIp = vip;
    }
    let text: string = vip !== '' ? `虚拟网卡就绪，虚拟 IP ${vip}` : '虚拟网卡就绪';
    if (netmask !== '') {
      text = `${text}，掩码 ${netmask}`;
    }
    if (gateway !== '') {
      text = `${text}，网关 ${gateway}`;
    }
    if (mtu > 0) {
      text = `${text}，MTU ${mtu}`;
    }
    return text;
  }

  private describePeers(json: string): string {
    let total: number = 0;
    let onlineCount: number = 0;
    try {
      const peers: Array<Record<string, Object>> = JSON.parse(json) as Array<Record<string, Object>>;
      total = peers.length;
      for (let i = 0; i < peers.length; i++) {
        if (peers[i]['online'] === true) {
          onlineCount++;
        }
      }
    } catch (e) {
      return '设备列表更新';
    }
    return `设备列表更新：共 ${total} 台，在线 ${onlineCount} 台`;
  }

  private publishStatus(): void {
    if (this.rebuilding || this.suppressStatus) {
      return;
    }
    let payload: Record<string, Object> = {};
    try {
      payload = JSON.parse(vntNapi.status()) as Record<string, Object>;
    } catch (e) {
      payload = {};
    }
    const statusVip: Object | undefined = payload['virtual_ip'];
    if ((typeof statusVip !== 'string' || statusVip === '') && this.tunVirtualIp !== '') {
      payload['virtual_ip'] = this.tunVirtualIp;
    }
    try {
      const devices: Array<Record<string, Object>> =
        JSON.parse(vntNapi.deviceList()) as Array<Record<string, Object>>;
      payload['devices'] = devices;
    } catch (e) {
      const empty: Array<Record<string, Object>> = [];
      payload['devices'] = empty;
    }
    payload['event_text'] = this.eventText;
    payload['error'] = this.lastError;
    payload['start_at'] = this.startAt;
    const pubData: commonEventManager.CommonEventPublishData = { data: JSON.stringify(payload) };
    commonEventManager.publish(VPN_STATUS_EVENT, pubData, (err: BusinessError): void => {
      if (err) {
        hilog.error(DOMAIN, TAG, 'publish status failed: %{public}s', err.message ?? '');
      }
    });
  }

  private formatElapsed(ms: number): string {
    const totalSec: number = Math.floor(ms / 1000);
    const h: number = Math.floor(totalSec / 3600);
    const m: number = Math.floor((totalSec % 3600) / 60);
    const s: number = totalSec % 60;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    if (h > 0) {
      const hh: string = h < 10 ? `0${h}` : `${h}`;
      return `${hh}:${mm}:${ss}`;
    }
    return `${mm}:${ss}`;
  }

  private updateKeepAliveNotification(force: boolean): void {
    if (this.startAt === 0) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastNotify < NOTIFY_REFRESH_MS) {
      return;
    }
    this.lastNotify = now;
    if (this.launchAgent === undefined) {
      const wantObj: Want = {
        deviceId: '',
        bundleName: BUNDLE_NAME,
        abilityName: 'EntryAbility',
        action: 'action.system.home'
      };
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [wantObj],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      wantAgent.getWantAgent(agentInfo).then((agent: object): void => {
        this.launchAgent = agent;
        this.doPublishNotification();
      }).catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'getWantAgent failed: %{public}s', err.message ?? '');
        this.doPublishNotification();
      });
      return;
    }
    this.doPublishNotification();
  }

  private doPublishNotification(): void {
    if (this.startAt === 0) {
      return;
    }
    const elapsed: string = this.formatElapsed(Date.now() - this.startAt);
    const request: notificationManager.NotificationRequest = {
      id: NOTIFY_ID,
      wantAgent: this.launchAgent,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'Vntc 正在运行',
          text: `VPN 组网已保持 ${elapsed}`,
          additionalText: '虚拟网络服务运行中'
        }
      }
    };
    notificationManager.publish(request).catch((err: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'publish notification failed: %{public}s', err.message ?? '');
    });
  }

  private cancelKeepAliveNotification(): void {
    this.startAt = 0;
    notificationManager.cancel(NOTIFY_ID).catch((err: BusinessError): void => {
      hilog.error(DOMAIN, TAG, 'cancel notification failed: %{public}s', err.message ?? '');
    });
  }

  private teardown(): void {
    if (this.vpnConnection !== undefined) {
      this.vpnConnection.destroy().then((): void => {
        hilog.info(DOMAIN, TAG, 'vpn destroyed');
      }).catch((err: BusinessError): void => {
        hilog.error(DOMAIN, TAG, 'vpn destroy failed: %{public}s', JSON.stringify(err) ?? '');
      });
      this.vpnConnection = undefined;
    }
  }

  private readParams(want: Want): VpnParams {
    let params: Record<string, Object> = {};
    if (want.parameters !== undefined) {
      params = want.parameters;
    }
    const mtuVal: Object | undefined = params['mtu'];
    const ucVal: Object | undefined = params['useChannel'];
    const ciVal: Object | undefined = params['cipherModel'];
    const coVal: Object | undefined = params['compressor'];
    const seVal: Object | undefined = params['serverEncrypt'];
    const fiVal: Object | undefined = params['finger'];
    const trVal: Object | undefined = params['enableTraffic'];
    const vntParams: VpnParams = {
      server: this.paramStr(params, 'server'),
      token: this.paramStr(params, 'token'),
      password: this.paramStr(params, 'password'),
      deviceId: this.paramStr(params, 'deviceId'),
      name: this.paramStr(params, 'name'),
      virtualIp: this.paramStr(params, 'virtualIp'),
      mtu: (typeof mtuVal === 'number' && mtuVal > 0) ? mtuVal : DEFAULT_MTU,
      useChannel: (typeof ucVal === 'number' && ucVal >= 0 && ucVal <= 2) ? ucVal : 2,
      stunServers: this.paramStr(params, 'stunServers'),
      nameServers: this.paramStr(params, 'nameServers'),
      ports: this.paramStr(params, 'ports'),
      cipherModel: (typeof ciVal === 'number' && ciVal >= 0 && ciVal <= 6) ? ciVal : 0,
      compressor: (typeof coVal === 'number' && coVal >= 0 && coVal <= 1) ? coVal : 1,
      serverEncrypt: (typeof seVal === 'boolean') ? (seVal ? 1 : 0) : 1,
      finger: (typeof fiVal === 'boolean') ? (fiVal ? 1 : 0) : 1,
      enableTraffic: (typeof trVal === 'boolean') ? (trVal ? 1 : 0) : 1
    };
    return vntParams;
  }

  private paramStr(params: Record<string, Object>, key: string): string {
    const val: Object | undefined = params[key];
    if (typeof val === 'string') {
      return val;
    }
    return '';
  }
}
