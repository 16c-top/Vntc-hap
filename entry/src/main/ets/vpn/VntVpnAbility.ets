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
  coreVersion: string;
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
  inIps: string;
  outIps: string;
  mapping: string;
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
    this.tunVirtualIp = '';
    this.eventText = '连接已断开';
    this.publishStatus();
    this.cancelKeepAliveNotification();
    this.teardown();
  }

  private failStart(eventText: string): void {
    hilog.error(DOMAIN, TAG, 'setup vpn failed: %{public}s', this.lastError);
    vntNapi.setEventListener(null);
    this.suppressStatus = false;
    this.eventText = eventText;
    this.publishStatus();
    this.teardown();
  }

  private buildV2Json(params: VpnParams, virtualIp: string): string {
    const json: Record<string, Object> = {};
    json['network_code'] = params.token;
    json['server'] = params.server;
    json['device_mode'] = 'tun';
    if (params.deviceId !== '') {
      json['device_id'] = params.deviceId;
    }
    if (params.name !== '') {
      json['device_name'] = params.name;
    }
    if (params.password !== '') {
      json['password'] = params.password;
    }
    if (virtualIp !== '') {
      json['ip'] = virtualIp;
    }
    if (params.mtu > 0) {
      json['mtu'] = params.mtu;
    }
    if (params.stunServers.trim() !== '') {
      json['udp_stun'] = params.stunServers.trim();
    }
    if (params.inIps.trim() !== '') {
      json['input'] = params.inIps.trim();
    }
    if (params.outIps.trim() !== '') {
      json['output'] = params.outIps.trim();
    }
    if (params.mapping.trim() !== '') {
      json['port_mapping'] = params.mapping.trim();
    }
    json['compress'] = params.compressor !== 0;
    if (params.useChannel === 0) {
      json['no_punch'] = true;
    }
    const portsRaw: string = params.ports.trim();
    if (portsRaw !== '') {
      const firstPort: number = Number(portsRaw.split(',')[0].trim());
      if (Number.isFinite(firstPort) && firstPort > 0 && firstPort <= 65535) {
        json['tunnel_port'] = firstPort;
      }
    }
    return JSON.stringify(json);
  }

  private startCore(tunFd: number, virtualIp: string): Promise<boolean> {
    const params: VpnParams | undefined = this.params;
    if (params === undefined) {
      return Promise.resolve(false);
    }
    if (params.coreVersion === 'v2') {
      return vntNapi.startJson(tunFd, this.buildV2Json(params, virtualIp));
    }
    return vntNapi.start(tunFd, params.token, params.deviceId, params.name,
      params.server, params.password, virtualIp, params.mtu, params.useChannel,
      params.stunServers, params.nameServers, params.ports, params.cipherModel,
      params.compressor, params.serverEncrypt, params.finger, params.enableTraffic,
      params.inIps, params.outIps, params.mapping);
  }

  private async setupVpn(want: Want): Promise<void> {
    try {
      const params: VpnParams = this.readParams(want);
      this.params = params;

      if (params.coreVersion === 'v2') {
        const sv: string = params.server.trim();
        if (sv.startsWith('udp://') || sv.startsWith('ws://')) {
          this.lastError = 'V2 内核不支持 udp:// 与明文 ws://';
          this.failStart('服务端协议不受支持');
          return;
        }
        if (sv.includes(',') && params.virtualIp.trim() === '') {
          this.lastError = 'V2 多服务端地址必须指定固定虚拟 IP';
          this.failStart('缺少固定虚拟 IP');
          return;
        }
      }

      vntNapi.setEventListener((event: number, json: string): void => {
        this.onVntEvent(event, json);
      });

      if (!vntNapi.setCoreVersion(params.coreVersion)) {
        this.lastError = `内核 ${params.coreVersion} 加载失败：${vntNapi.lastError()}`;
        this.failStart('内核加载失败');
        return;
      }

      hilog.info(DOMAIN, TAG, 'phase 1: start vnt without tun to learn gateway');
      let ok: boolean = await this.startCore(-1, params.virtualIp);
      if (!ok) {
        hilog.warn(DOMAIN, TAG, 'start without tun failed: %{public}s, fallback to placeholder tun',
          vntNapi.lastError());
        const tunIp: string = this.resolveTunAddress(params.virtualIp);
        if (tunIp === '') {
          this.lastError = params.virtualIp.trim() === ''
            ? '未能从服务端获取虚拟 IP，且未配置固定虚拟 IP：请在配置中填写"虚拟 IP"（如 10.26.0.5）后重试'
            : `虚拟 IP 格式无效：${params.virtualIp}（应为 IPv4，可带前缀如 10.26.0.5/24）`;
          hilog.error(DOMAIN, TAG, 'no usable virtual ip: %{public}s', params.virtualIp);
          this.eventText = '缺少可用虚拟 IP';
          this.suppressStatus = false;
          this.publishStatus();
          this.teardown();
          return;
        }
        const conn: vpnExtension.VpnConnection =
          vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
        this.vpnConnection = conn;
        const cfg: vpnExtension.VpnConfig = {
          addresses: [{
            address: { address: tunIp, family: 1 },
            prefixLength: this.resolveTunPrefix(params.virtualIp)
          }],
          mtu: params.mtu,
          isIPv4Accepted: true,
          dnsAddresses: ['223.5.5.5', '114.114.114.114'],
          blockedApplications: [BUNDLE_NAME]
        };
        const tunFd: number = await conn.create(cfg);
        hilog.info(DOMAIN, TAG, 'tun fd: %{public}d', tunFd);
        ok = await this.startCore(tunFd, tunIp);
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
    if (code === 'ERROR') {
      return '内核报错';
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
        mtu: params.mtu,
        isIPv4Accepted: true,
        dnsAddresses: ['223.5.5.5', '114.114.114.114'],
        blockedApplications: [BUNDLE_NAME]
      };
      const tunFd: number = await conn.create(cfg);
      const ok: boolean = await this.startCore(tunFd, vip);
      if (!ok) {
        this.lastError = vntNapi.lastError();
        this.eventText = '连接重建失败';
        hilog.error(DOMAIN, TAG, 'vnt restart failed: %{public}s', this.lastError);
      }
    } catch (e) {
      this.lastError = JSON.stringify(e) ?? '';
      this.eventText = '连接重建失败';
      hilog.error(DOMAIN, TAG, 'rebuild vpn error: %{public}s', this.lastError);
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
    try {
      payload['device_detail'] = JSON.parse(vntNapi.deviceDetail());
    } catch (e) {
      payload['device_detail'] = [];
    }
    try {
      payload['route_table'] = JSON.parse(vntNapi.routeTable());
    } catch (e) {
      payload['route_table'] = [];
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

  private isValidIpv4(text: string): boolean {
    const parts: Array<string> = text.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i];
      if (seg === '' || seg.length > 3) {
        return false;
      }
      for (let j = 0; j < seg.length; j++) {
        const ch: number = seg.charCodeAt(j);
        if (ch < 48 || ch > 57) {
          return false;
        }
      }
      if (Number(seg) > 255) {
        return false;
      }
    }
    return true;
  }

  private resolveTunAddress(virtualIp: string): string {
    const raw: string = virtualIp.trim();
    if (raw === '') {
      return '';
    }
    const slash: number = raw.indexOf('/');
    const addr: string = (slash >= 0 ? raw.substring(0, slash) : raw).trim();
    return this.isValidIpv4(addr) ? addr : '';
  }

  private resolveTunPrefix(virtualIp: string): number {
    const raw: string = virtualIp.trim();
    const slash: number = raw.indexOf('/');
    if (slash < 0) {
      return 24;
    }
    const val: number = Number(raw.substring(slash + 1).trim());
    if (!Number.isFinite(val) || val <= 0 || val > 32) {
      return 24;
    }
    return val;
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
    const coreV2: boolean = this.paramStr(params, 'coreVersion') === 'v2';
    const vntParams: VpnParams = {
      coreVersion: coreV2 ? 'v2' : 'v1',
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
      inIps: this.paramStr(params, 'inIps'),
      outIps: this.paramStr(params, 'outIps'),
      mapping: this.paramStr(params, 'mapping'),
      cipherModel: (typeof ciVal === 'number' && ciVal >= 0 && ciVal <= 6) ? ciVal : 0,
      compressor: (typeof coVal === 'number' && coVal >= 0 && coVal <= 2) ? coVal : (coreV2 ? 0 : 1),
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
