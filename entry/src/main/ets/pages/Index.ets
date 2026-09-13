import { Want, common } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError, commonEventManager, deviceInfo } from '@kit.BasicServicesKit';
import vntNapi from 'libvnt_napi.so';
import { VPN_STATUS_EVENT } from '../vpn/VpnConst';
import { VpnConfigItem } from '../vpn/VpnConfigItem';
import { ConfigStore } from '../vpn/ConfigStore';

const BUNDLE_NAME: string = 'top.16c.vntc';
const VPN_ABILITY_NAME: string = 'VntVpnAbility';
const HEARTBEAT_TIMEOUT_MS: number = 6000;
const DEFAULT_MTU: number = 1400;

const COLOR_BG_TOP: string = '#0B101D';
const COLOR_BG_BOTTOM: string = '#141C30';
const COLOR_CARD: string = '#1A2336';
const COLOR_CARD_BORDER: string = '#273353';
const COLOR_INPUT: string = '#121A2B';
const COLOR_TEXT_MAIN: string = '#F2F5FA';
const COLOR_TEXT_SUB: string = '#8590A8';
const COLOR_TEXT_FAINT: string = '#5A6478';
const COLOR_ACCENT_START: string = '#2E6BFF';
const COLOR_ACCENT_END: string = '#5B9BFF';
const COLOR_GREEN: string = '#30D158';
const COLOR_RED: string = '#FF6B6B';
const COLOR_ORANGE: string = '#FFA940';

interface PopupStateChangeEvent {
  isVisible: boolean;
}

@Component
struct ConfigEditDialog {
  @Link title: string;
  @Link name: string;
  @Link server: string;
  @Link token: string;
  @Link password: string;
  @Link deviceId: string;
  @Link deviceName: string;
  @Link virtualIp: string;
  @Link mtuText: string;
  @Link useChannel: string;
  @Link stunServers: string;
  @Link nameServers: string;
  @Link ports: string;
  @Link cipher: string;
  @Link compressor: string;
  @Link serverEncrypt: boolean;
  @Link finger: boolean;
  @Link traffic: boolean;
  onSave: () => void = (): void => {};
  onClose: () => void = (): void => {};
  @State tip: string = '';

  private closeDialog(): void {
    this.onClose();
  }

  private doSave(): void {
    if (this.name === '' || this.server === '' || this.token === '') {
      this.tip = '名称、服务端、令牌为必填项';
      return;
    }
    this.tip = '';
    this.onSave();
    this.closeDialog();
  }

  @Builder
  dlgField(label: string, placeholder: string, text: string, isPassword: boolean,
    onChange: (value: string) => void)
  {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(COLOR_TEXT_SUB)
        .margin({ bottom: 6 })
      TextInput({ placeholder: placeholder, text: text })
        .onChange((value: string): void => {
          onChange(value);
        })
        .type(isPassword ? InputType.Password : InputType.Normal)
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(COLOR_TEXT_MAIN)
        .placeholderColor(COLOR_TEXT_FAINT)
        .backgroundColor(COLOR_INPUT)
        .borderRadius(10)
        .padding({ left: 12, right: 12 })
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
  }

  private cipherOptions(): SelectOption[] {
    return [
      { value: 'AES-GCM（默认）' },
      { value: 'ChaCha20-Poly1305' },
      { value: 'ChaCha20' },
      { value: 'AES-CBC' },
      { value: 'AES-ECB' },
      { value: 'XOR' },
      { value: '不加密' }
    ];
  }

  private compressorOptions(): SelectOption[] {
    return [
      { value: '不压缩' },
      { value: 'LZ4（默认）' }
    ];
  }

  @Builder
  dlgModeButton(label: string, value: string) {
    Text(label)
      .fontSize(12)
      .fontColor(this.useChannel === value ? '#FFFFFF' : COLOR_TEXT_SUB)
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 8, left: 6, right: 6 })
      .borderRadius(10)
      .backgroundColor(this.useChannel === value ? COLOR_ACCENT_START : COLOR_INPUT)
      .layoutWeight(1)
      .onClick((): void => {
        this.useChannel = value;
      })
  }

  @Builder
  dlgToggleRow(label: string, on: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(COLOR_TEXT_SUB)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(COLOR_ACCENT_START)
        .onChange((v: boolean): void => {
          onChange(v);
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLOR_TEXT_MAIN)
        .width('100%')
        .textAlign(TextAlign.Start)

      Scroll() {
        Column() {
          this.dlgField('配置名称', '如：家里服务器', this.name, false,
            (value: string): void => {
              this.name = value;
            })
          this.dlgField('服务端（udp:// tcp:// ws://）', 'udp://host:port', this.server, false,
            (value: string): void => {
              this.server = value;
            })
          this.dlgField('令牌 Token', '与服务端一致', this.token, false,
            (value: string): void => {
              this.token = value;
            })
          this.dlgField('密码（可选）', '组网密码', this.password, true,
            (value: string): void => {
              this.password = value;
            })
          this.dlgField('设备 ID', '留空自动生成', this.deviceId, false,
            (value: string): void => {
              this.deviceId = value;
            })
          this.dlgField('设备名称', '展示名称', this.deviceName, false,
            (value: string): void => {
              this.deviceName = value;
            })
          this.dlgField('虚拟 IP', '留空由服务端分配', this.virtualIp, false,
            (value: string): void => {
              this.virtualIp = value;
            })
          this.dlgField('MTU', '默认 1400', this.mtuText, false,
            (value: string): void => {
              this.mtuText = value;
            })

          Text('通道模式')
            .fontSize(13)
            .fontColor(COLOR_ACCENT_END)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 4, bottom: 8 })
          Row({ space: 8 }) {
            this.dlgModeButton('仅中继', '0')
            this.dlgModeButton('仅 P2P', '1')
            this.dlgModeButton('自动（推荐）', '2')
          }
          .width('100%')
          .margin({ bottom: 10 })

          this.dlgField('STUN 服务器', '逗号分隔，留空使用默认', this.stunServers, false,
            (value: string): void => {
              this.stunServers = value;
            })
          this.dlgField('DNS 服务器', '逗号分隔，留空使用默认', this.nameServers, false,
            (value: string): void => {
              this.nameServers = value;
            })
          // 本地端口配置暂不开放
          // this.dlgField('本地端口', '逗号分隔，如 35535,35536', this.ports, false,
          //   (value: string): void => {
          //     this.ports = value;
          //   })

          Text('高级选项')
            .fontSize(13)
            .fontColor(COLOR_ACCENT_END)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 4, bottom: 8 })
          Row() {
            Text('加密算法')
              .fontSize(13)
              .fontColor(COLOR_TEXT_SUB)
              .layoutWeight(1)
            Select(this.cipherOptions())
              .selected(Number(this.cipher))
              .value(this.cipherOptions()[Number(this.cipher)].value as string)
              .font({ size: 13 })
              .selectedOptionFont({ size: 13 })
              .optionFont({ size: 13 })
              .fontColor(COLOR_TEXT_MAIN)
              .onSelect((index: number): void => {
                this.cipher = `${index}`;
              })
          }
          .width('100%')
          .margin({ bottom: 10 })
          Row() {
            Text('压缩算法')
              .fontSize(13)
              .fontColor(COLOR_TEXT_SUB)
              .layoutWeight(1)
            Select(this.compressorOptions())
              .selected(Number(this.compressor))
              .value(this.compressorOptions()[Number(this.compressor)].value as string)
              .font({ size: 13 })
              .selectedOptionFont({ size: 13 })
              .optionFont({ size: 13 })
              .fontColor(COLOR_TEXT_MAIN)
              .onSelect((index: number): void => {
                this.compressor = `${index}`;
              })
          }
          .width('100%')
          .margin({ bottom: 10 })
          this.dlgToggleRow('服务端加密协商', this.serverEncrypt,
            (v: boolean): void => {
              this.serverEncrypt = v;
            })
          this.dlgToggleRow('数据包指纹校验', this.finger,
            (v: boolean): void => {
              this.finger = v;
            })
          this.dlgToggleRow('统计流量', this.traffic,
            (v: boolean): void => {
              this.traffic = v;
            })
        }
        .width('100%')
        .padding({ right: 20 })
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 14, right: -20 })

      if (this.tip !== '') {
        Text(this.tip)
          .fontSize(12)
          .fontColor(COLOR_RED)
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 8 })
      }

      Row({ space: 12 }) {
        Button('取消')
          .onClick((): void => {
            this.tip = '';
            this.closeDialog();
          })
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(COLOR_TEXT_SUB)
          .backgroundColor(COLOR_INPUT)
          .borderRadius(12)
        Button('保存')
          .onClick((): void => {
            this.doSave();
          })
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor('#FFFFFF')
          .linearGradient({
            angle: 135,
            colors: [[COLOR_ACCENT_START, 0.0], [COLOR_ACCENT_END, 1.0]]
          })
          .borderRadius(12)
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('92%')
    .height('90%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(16)
    .border({ width: 1, color: COLOR_CARD_BORDER })
  }
}

@Component
struct StatCard {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop valueColor: string = COLOR_TEXT_MAIN;

  build() {
    Column() {
      Text(this.label)
        .fontSize(12)
        .fontColor(COLOR_TEXT_FAINT)
        .margin({ bottom: 4 })
      Text(this.value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.valueColor)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(COLOR_INPUT)
    .borderRadius(12)
    .padding(12)
  }
}

@Entry
@Component
struct Index {
  @State configs: Array<VpnConfigItem> = [];
  @State selectedId: string = '';
  @State dropdownOpen: boolean = false;
  @State running: boolean = false;
  @State online: boolean = false;
  @State currentIp: string = '';
  @State gateway: string = '';
  @State channel: string = '';
  @State delay: number = -1;
  @State upBytes: number = 0;
  @State downBytes: number = 0;
  @State lastEvent: string = '';
  @State errMsg: string = '';
  @State devices: Array<Record<string, Object>> = [];
  @State connectStart: number = 0;
  @State runElapsed: number = 0;

  @State dlgTitle: string = '新增配置';
  @State dlgName: string = '';
  @State dlgServer: string = '';
  @State dlgToken: string = '';
  @State dlgPassword: string = '';
  @State dlgDeviceId: string = '';
  @State dlgDeviceName: string = '';
  @State dlgVirtualIp: string = '';
  @State dlgMtuText: string = '1400';
  @State dlgUseChannel: string = '2';
  @State dlgStunServers: string = '';
  @State dlgNameServers: string = '';
  @State dlgPorts: string = '';
  @State dlgCipher: string = '0';
  @State dlgCompressor: string = '1';
  @State dlgServerEncrypt: boolean = true;
  @State dlgFinger: boolean = true;
  @State dlgTraffic: boolean = true;
  @State dialogOpen: boolean = false;

  private editingId: string = '';
  private store: ConfigStore = new ConfigStore();
  private timerId: number = -1;
  private subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
  private lastBeat: number = 0;

  aboutToAppear(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      this.store.init(ctx)
        .then((): Promise<Array<VpnConfigItem>> => {
          return this.store.loadAll();
        })
        .then((list: Array<VpnConfigItem>): Promise<string> => {
          this.configs = list;
          return this.store.loadSelected();
        })
        .then((id: string): void => {
          this.selectedId = id;
        })
        .catch((err: BusinessError): void => {
          this.errMsg = `配置读取失败 ${err.code}: ${err.message}`;
        });
    }
    const info: commonEventManager.CommonEventSubscribeInfo = { events: [VPN_STATUS_EVENT] };
    commonEventManager.createSubscriber(info,
      (err: BusinessError, sub: commonEventManager.CommonEventSubscriber): void => {
        if (err) {
          this.errMsg = `订阅状态事件失败 ${err.code}: ${err.message}`;
          return;
        }
        this.subscriber = sub;
        commonEventManager.subscribe(sub,
          (subErr: BusinessError, data: commonEventManager.CommonEventData): void => {
            if (subErr) {
              return;
            }
            this.onStatusEvent(data);
          });
      });
    this.timerId = setInterval((): void => {
      this.checkHeartbeat();
      if (this.connectStart > 0 && this.running) {
        this.runElapsed = Date.now() - this.connectStart;
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.subscriber !== undefined) {
      commonEventManager.unsubscribe(this.subscriber);
      this.subscriber = undefined;
    }
  }

  private onStatusEvent(data: commonEventManager.CommonEventData): void {
    this.lastBeat = Date.now();
    const json: string = data.data ?? '';
    if (json === '') {
      return;
    }
    let payload: Record<string, Object>;
    try {
      payload = JSON.parse(json) as Record<string, Object>;
    } catch (e) {
      return;
    }
    const isRunning: boolean = payload['running'] === true;
    const startAtVal: Object | undefined = payload['start_at'];
    if (isRunning && typeof startAtVal === 'number' && startAtVal > 0) {
      this.connectStart = startAtVal;
      this.runElapsed = Date.now() - startAtVal;
    } else {
      this.connectStart = 0;
      this.runElapsed = 0;
    }
    this.running = isRunning;
    this.online = payload['online'] === true;
    this.currentIp = `${payload['virtual_ip'] ?? ''}`;
    const gwVal: Object | undefined = payload['gateway'];
    this.gateway = typeof gwVal === 'string' ? gwVal : '';
    const chVal: Object | undefined = payload['channel'];
    this.channel = typeof chVal === 'string' ? chVal : '';
    const delayVal: Object | undefined = payload['delay'];
    this.delay = typeof delayVal === 'number' ? delayVal : -1;
    const up: Object | undefined = payload['up_stream'];
    this.upBytes = typeof up === 'number' ? up : 0;
    const down: Object | undefined = payload['down_stream'];
    this.downBytes = typeof down === 'number' ? down : 0;
    const devices: Object | undefined = payload['devices'];
    if (devices !== undefined && devices !== null) {
      this.devices = devices as Array<Record<string, Object>>;
    }
    const evtText: Object | undefined = payload['event_text'];
    if (typeof evtText === 'string' && evtText !== '') {
      this.lastEvent = evtText;
    }
    const errText: Object | undefined = payload['error'];
    this.errMsg = (typeof errText === 'string' && errText !== '') ? errText : '';
  }

  private checkHeartbeat(): void {
    if (this.lastBeat === 0 || !this.running) {
      return;
    }
    if (Date.now() - this.lastBeat > HEARTBEAT_TIMEOUT_MS) {
      this.running = false;
      this.online = false;
      this.connectStart = 0;
      this.runElapsed = 0;
      this.currentIp = '';
      this.gateway = '';
      this.channel = '';
      this.delay = -1;
      this.devices = [];
      this.lastEvent = '与连接服务进程失去联系';
    }
  }

  private describeDevStatus(dev: Record<string, Object>): string {
    if (dev['online'] !== true) {
      return '离线';
    }
    let text: string = '在线';
    const channelVal: Object | undefined = dev['channel'];
    if (typeof channelVal === 'string' && channelVal !== '') {
      text = this.channelText(channelVal);
    }
    const delayVal: Object | undefined = dev['delay'];
    if (typeof delayVal === 'number' && delayVal >= 0) {
      text += ` ${delayVal}ms`;
    }
    return text;
  }

  private statusChannelText(): string {
    if (this.channel === 'p2p') {
      return 'P2P';
    }
    if (this.channel === 'relay') {
      return '中继';
    }
    if (this.channel === 'mixed') {
      return '混合';
    }
    if (this.channel === 'none') {
      return '无通道';
    }
    return this.channel;
  }

  private channelText(channel: string): string {
    if (channel === 'p2p') {
      return 'P2P';
    }
    if (channel === 'tcp-p2p') {
      return 'TCP P2P';
    }
    if (channel === 'server-relay') {
      return '服务器中转';
    }
    if (channel === 'client-relay') {
      return '客户端中转';
    }
    return '在线';
  }

  private hex4(v: number): string {
    let s: string = v.toString(16);
    while (s.length < 4) {
      s = `0${s}`;
    }
    return s;
  }

  private randomDeviceId(): string {
    const a: number = Math.floor(Math.random() * 0x10000);
    const b: number = Math.floor(Math.random() * 0x10000);
    const c: number = Math.floor(Math.random() * 0x10000);
    const d: number = Math.floor(Math.random() * 0x10000);
    return `phone-${this.hex4(a)}${this.hex4(b)}${this.hex4(c)}${this.hex4(d)}`;
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

  private formatBytes(bytes: number): string {
    if (bytes >= 1024 * 1024) {
      return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
    }
    if (bytes >= 1024) {
      return `${(bytes / 1024).toFixed(2)} KB`;
    }
    return `${bytes} B`;
  }

  private selectedConfig(): VpnConfigItem | undefined {
    for (let i = 0; i < this.configs.length; i++) {
      if (this.configs[i].id === this.selectedId) {
        return this.configs[i];
      }
    }
    return undefined;
  }

  private selectedName(): string {
    const cfg: VpnConfigItem | undefined = this.selectedConfig();
    if (cfg === undefined) {
      return '选择配置';
    }
    return cfg.name;
  }

  private genId(): string {
    return `cfg_${Date.now()}`;
  }

  private selectConfig(id: string): void {
    if (this.running) {
      this.errMsg = '连接运行中，请先停止再切换配置';
      return;
    }
    this.selectedId = id;
    this.dropdownOpen = false;
    this.store.saveSelected(id);
  }

  private openNewConfig(): void {
    this.editingId = '';
    this.dlgTitle = '新增配置';
    this.dlgName = '';
    this.dlgServer = '';
    this.dlgToken = '';
    this.dlgPassword = '';
    this.dlgDeviceId = '';
    this.dlgDeviceName = deviceInfo.marketName !== '' ? deviceInfo.marketName : deviceInfo.productModel;
    this.dlgVirtualIp = '';
    this.dlgMtuText = '1400';
    this.dlgUseChannel = '2';
    this.dlgStunServers = '';
    this.dlgNameServers = '';
    this.dlgPorts = '';
    this.dlgCipher = '0';
    this.dlgCompressor = '1';
    this.dlgServerEncrypt = true;
    this.dlgFinger = true;
    this.dlgTraffic = true;
    this.dialogOpen = true;
  }

  private openDetail(id: string): void {
    let cfg: VpnConfigItem | undefined = undefined;
    for (let i = 0; i < this.configs.length; i++) {
      if (this.configs[i].id === id) {
        cfg = this.configs[i];
        break;
      }
    }
    if (cfg === undefined) {
      return;
    }
    this.editingId = id;
    this.dlgTitle = '配置详情';
    this.dlgName = cfg.name;
    this.dlgServer = cfg.server;
    this.dlgToken = cfg.token;
    this.dlgPassword = cfg.password;
    this.dlgDeviceId = cfg.deviceId;
    this.dlgDeviceName = cfg.deviceName;
    this.dlgVirtualIp = cfg.virtualIp;
    this.dlgMtuText = cfg.mtu;
    this.dlgUseChannel = (typeof cfg.useChannel === 'string' && cfg.useChannel !== '') ? cfg.useChannel : '2';
    this.dlgStunServers = cfg.stunServers ?? '';
    this.dlgNameServers = cfg.nameServers ?? '';
    this.dlgPorts = cfg.ports ?? '';
    this.dlgCipher = (typeof cfg.cipherModel === 'string' && cfg.cipherModel !== '') ? cfg.cipherModel : '0';
    this.dlgCompressor = (typeof cfg.compressor === 'string' && cfg.compressor !== '') ? cfg.compressor : '1';
    this.dlgServerEncrypt = cfg.serverEncrypt ?? true;
    this.dlgFinger = cfg.finger ?? true;
    this.dlgTraffic = cfg.enableTraffic ?? true;
    this.dialogOpen = true;
  }

  private saveDialogConfig(): void {
    const id: string = this.editingId === '' ? this.genId() : this.editingId;
    const rawDev: string = this.dlgDeviceId.trim();
    const devId: string = rawDev !== '' ? rawDev : this.randomDeviceId();
    const item: VpnConfigItem = {
      id: id,
      name: this.dlgName,
      server: this.dlgServer,
      token: this.dlgToken,
      password: this.dlgPassword,
      deviceId: devId,
      deviceName: this.dlgDeviceName,
      virtualIp: this.dlgVirtualIp,
      mtu: this.dlgMtuText,
      useChannel: this.dlgUseChannel,
      stunServers: this.dlgStunServers,
      nameServers: this.dlgNameServers,
      ports: this.dlgPorts,
      cipherModel: this.dlgCipher,
      compressor: this.dlgCompressor,
      serverEncrypt: this.dlgServerEncrypt,
      finger: this.dlgFinger,
      enableTraffic: this.dlgTraffic
    };
    const next: Array<VpnConfigItem> = [];
    let replaced: boolean = false;
    for (let i = 0; i < this.configs.length; i++) {
      if (this.configs[i].id === id) {
        next.push(item);
        replaced = true;
      } else {
        next.push(this.configs[i]);
      }
    }
    if (!replaced) {
      next.push(item);
    }
    this.configs = next;
    this.store.saveAll(next);
    if (this.editingId === '') {
      this.selectedId = id;
      this.store.saveSelected(id);
      this.dropdownOpen = false;
    }
  }

  private deleteConfig(id: string): void {
    const next: Array<VpnConfigItem> = [];
    for (let i = 0; i < this.configs.length; i++) {
      if (this.configs[i].id !== id) {
        next.push(this.configs[i]);
      }
    }
    this.configs = next;
    if (this.selectedId === id) {
      this.selectedId = '';
      this.store.saveSelected('');
    }
    this.store.saveAll(next);
  }

  private startVpn(): void {
    const cfg: VpnConfigItem | undefined = this.selectedConfig();
    if (cfg === undefined) {
      this.errMsg = '请先在下拉框选择一个配置';
      return;
    }
    if (this.running) {
      this.errMsg = '连接已在运行，请先停止';
      return;
    }
    const mtuParsed: number = Number(cfg.mtu);
    const mtu: number = mtuParsed > 0 ? mtuParsed : DEFAULT_MTU;
    const ucParsed: number = Number(cfg.useChannel);
    const ciParsed: number = Number(cfg.cipherModel);
    const coParsed: number = Number(cfg.compressor);
    const params: Record<string, Object> = {
      'server': cfg.server,
      'token': cfg.token,
      'password': cfg.password,
      'deviceId': cfg.deviceId !== '' ? cfg.deviceId : this.randomDeviceId(),
      'name': cfg.deviceName,
      'virtualIp': cfg.virtualIp,
      'mtu': mtu,
      'useChannel': (ucParsed === 0 || ucParsed === 1) ? ucParsed : 2,
      'stunServers': cfg.stunServers ?? '',
      'nameServers': cfg.nameServers ?? '',
      'ports': cfg.ports ?? '',
      'cipherModel': (ciParsed >= 0 && ciParsed <= 6) ? ciParsed : 0,
      'compressor': (coParsed === 0) ? 0 : 1,
      'serverEncrypt': cfg.serverEncrypt ?? true,
      'finger': cfg.finger ?? true,
      'enableTraffic': cfg.enableTraffic ?? true
    };
    const stopWant: Want = {
      deviceId: '',
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME
    };
    const startWant: Want = {
      deviceId: '',
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: params
    };
    this.errMsg = '正在连接...';
    vpnExtension.stopVpnExtensionAbility(stopWant).catch((): void => {
    }).then((): void => {
      vpnExtension.startVpnExtensionAbility(startWant).then((): void => {
        this.errMsg = '';
      }).catch((err: BusinessError): void => {
        this.errMsg = `启动失败 ${err.code}: ${err.message}`;
      });
    });
  }

  private stopVpn(): void {
    const want: Want = {
      deviceId: '',
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME
    };
    vpnExtension.stopVpnExtensionAbility(want).then((): void => {
      this.running = false;
      this.online = false;
      this.connectStart = 0;
      this.runElapsed = 0;
      this.currentIp = '';
      this.gateway = '';
      this.channel = '';
      this.delay = -1;
    }).catch((err: BusinessError): void => {
      this.errMsg = `停止失败 ${err.code}: ${err.message}`;
    });
  }

  @Builder
  dropdownPanel()
  {
    Column() {
      if (this.configs.length === 0) {
        Text('暂无配置，点击右上角【新增配置】')
          .fontSize(13)
          .fontColor(COLOR_TEXT_FAINT)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 16, bottom: 16 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.configs, (cfg: VpnConfigItem) => {
              Row({ space: 8 }) {
                Column() {
                  Text(cfg.name)
                    .fontSize(15)
                    .fontColor(cfg.id === this.selectedId ? COLOR_TEXT_MAIN : COLOR_TEXT_SUB)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(cfg.server)
                    .fontSize(11)
                    .fontColor(COLOR_TEXT_FAINT)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                .onClick((): void => {
                  this.selectConfig(cfg.id);
                })

                Text('详情')
                  .fontSize(12)
                  .fontColor(COLOR_ACCENT_END)
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .onClick((): void => {
                    this.dropdownOpen = false;
                    this.openDetail(cfg.id);
                  })
                Text('删除')
                  .fontSize(12)
                  .fontColor(COLOR_RED)
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .onClick((): void => {
                    this.deleteConfig(cfg.id);
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: 6, bottom: 6, left: 8, right: 8 })
              .borderRadius(10)
              .backgroundColor(cfg.id === this.selectedId ? COLOR_INPUT : '#00000000')
            }, (cfg: VpnConfigItem): string => cfg.id)
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 300 })
      }
    }
    .width(320)
    .padding(8)
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Column() {
            Text('Vntc 客户端')
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_TEXT_MAIN)
            Text(`内核版本 ${vntNapi.version()}`)
              .fontSize(13)
              .fontColor(COLOR_TEXT_SUB)
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button('新增配置')
            .onClick((): void => {
              this.openNewConfig();
            })
            .height(34)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .linearGradient({
              angle: 135,
              colors: [[COLOR_ACCENT_START, 0.0], [COLOR_ACCENT_END, 1.0]]
            })
            .borderRadius(10)
            .padding({ left: 14, right: 14 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ top: 8, bottom: 16 })

        Scroll() {
          Column() {
            Column() {
              Row() {
                Row({ space: 8 }) {
                  Column()
                    .width(10)
                    .height(10)
                    .borderRadius(5)
                    .backgroundColor(this.running ? (this.online ? COLOR_GREEN : COLOR_ORANGE) : '#5A6478')
                  Text(this.running ? (this.online ? '已连接' : '连接中') : '未连接')
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(COLOR_TEXT_MAIN)
                  if (this.online && this.channel !== '') {
                    Text(this.statusChannelText() + (this.delay >= 0 ? ` · ${this.delay}ms` : ''))
                      .fontSize(12)
                      .fontColor(COLOR_TEXT_SUB)
                      .padding({ left: 8, right: 10, top: 4, bottom: 4 })
                      .backgroundColor(COLOR_INPUT)
                      .borderRadius(10)
                  }
                }
                .alignItems(VerticalAlign.Center)

                Column()
                  .layoutWeight(1)

                Text(this.running ? `运行中 ${this.formatElapsed(this.runElapsed)}` : '已停止')
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .backgroundColor(this.running ? COLOR_GREEN : '#3A4560')
                  .borderRadius(12)
              }
              .width('100%')

              Row({ space: 10 }) {
                StatCard({
                  label: '虚拟 IP',
                  value: this.currentIp === '' ? (this.running ? '分配中' : '--') : this.currentIp,
                  valueColor: COLOR_TEXT_MAIN
                })
                StatCard({
                  label: '网关',
                  value: this.gateway === '' ? '--' : this.gateway,
                  valueColor: COLOR_TEXT_MAIN
                })
              }
              .width('100%')
              .margin({ top: 14 })

              Row({ space: 10 }) {
                StatCard({ label: '上传', value: `↑ ${this.formatBytes(this.upBytes)}`, valueColor: COLOR_GREEN })
                StatCard({ label: '下载', value: `↓ ${this.formatBytes(this.downBytes)}`, valueColor: COLOR_ACCENT_END })
              }
              .width('100%')
              .margin({ top: 10 })

              if (this.lastEvent !== '') {
                Text(this.lastEvent)
                  .fontSize(12)
                  .fontColor(COLOR_TEXT_FAINT)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 12 })
                  .width('100%')
              }
              if (this.errMsg !== '') {
                Text(this.errMsg)
                  .fontSize(12)
                  .fontColor(COLOR_RED)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 8 })
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(COLOR_CARD)
            .borderRadius(16)
            .border({ width: 1, color: COLOR_CARD_BORDER })

            Column() {
              Row({ space: 10 }) {
                Row({ space: 8 }) {
                  Text(this.selectedName())
                    .fontSize(15)
                    .fontColor(this.selectedId === '' ? COLOR_TEXT_FAINT : COLOR_TEXT_MAIN)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.dropdownOpen ? '▲' : '▼')
                    .fontSize(12)
                    .fontColor(COLOR_TEXT_FAINT)
                }
                .layoutWeight(1)
                .height(48)
                .padding({ left: 14, right: 14 })
                .alignItems(VerticalAlign.Center)
                .backgroundColor(COLOR_CARD)
                .borderRadius(14)
                .border({ width: 1, color: COLOR_CARD_BORDER })
                .opacity(this.running ? 0.5 : 1)
                .onClick((): void => {
                  if (this.running) {
                    this.errMsg = '连接运行中，请先停止再切换配置';
                    return;
                  }
                  this.dropdownOpen = !this.dropdownOpen;
                })
                .bindPopup(this.dropdownOpen, {
                  builder: (): void => {
                    this.dropdownPanel();
                  },
                  placement: Placement.BottomLeft,
                  popupColor: COLOR_CARD,
                  backgroundBlurStyle: BlurStyle.NONE,
                  enableArrow: false,
                  autoCancel: true,
                  targetSpace: 8,
                  mask: { color: '#00000000' },
                  onStateChange: (e: PopupStateChangeEvent): void => {
                    if (!e.isVisible) {
                      this.dropdownOpen = false;
                    }
                  }
                })

                if (this.running) {
                  Button('断开连接')
                    .onClick((): void => {
                      this.stopVpn();
                    })
                    .width(118)
                    .height(48)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(COLOR_RED)
                    .backgroundColor(COLOR_CARD)
                    .borderRadius(14)
                    .border({ width: 1, color: COLOR_CARD_BORDER })
                } else {
                  Button('启动连接')
                    .onClick((): void => {
                      this.startVpn();
                    })
                    .width(118)
                    .height(48)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#FFFFFF')
                    .linearGradient({
                      angle: 135,
                      colors: [[COLOR_ACCENT_START, 0.0], [COLOR_ACCENT_END, 1.0]]
                    })
                    .borderRadius(14)
                }
              }
              .width('100%')
            }
            .width('100%')
            .margin({ top: 16 })

            Column() {
              Row() {
                Text('组网设备')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(COLOR_TEXT_MAIN)
                Column()
                  .layoutWeight(1)
                Text(`${this.devices.length} 台`)
                  .fontSize(12)
                  .fontColor(COLOR_TEXT_FAINT)
              }
              .width('100%')
              .margin({ bottom: 10 })

              if (this.devices.length === 0) {
                Text('暂无设备，启动后自动加载')
                  .fontSize(13)
                  .fontColor(COLOR_TEXT_FAINT)
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 20, bottom: 20 })
              } else {
                ForEach(this.devices, (dev: Record<string, Object>) => {
                  Row({ space: 10 }) {
                    Column()
                      .width(8)
                      .height(8)
                      .borderRadius(4)
                      .backgroundColor(dev['online'] === true ? COLOR_GREEN : '#5A6478')
                    Column({ space: 4 }) {
                      Text(`${dev['name']}`)
                        .fontSize(14)
                        .fontColor(COLOR_TEXT_MAIN)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                      Text(`${dev['ip']} · ${this.describeDevStatus(dev)}`)
                        .fontSize(12)
                        .fontColor(dev['online'] === true ? COLOR_TEXT_SUB : COLOR_TEXT_FAINT)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width('100%')
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                  .padding({ top: 10, bottom: 10, left: 12, right: 12 })
                  .backgroundColor(COLOR_INPUT)
                  .borderRadius(10)
                  .margin({ bottom: 6 })
                }, (dev: Record<string, Object>): string => `${dev['ip']}_${dev['name']}_${dev['online']}_${dev['channel']}_${dev['delay']}`)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(COLOR_CARD)
            .borderRadius(16)
            .border({ width: 1, color: COLOR_CARD_BORDER })
            .margin({ top: 16 })

          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
      }
      .height('100%')
      .width('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .linearGradient({
        angle: 180,
        colors: [[COLOR_BG_TOP, 0.0], [COLOR_BG_BOTTOM, 1.0]]
      })

      if (this.dialogOpen) {
        Column() {
          ConfigEditDialog({
            title: $dlgTitle,
            name: $dlgName,
            server: $dlgServer,
            token: $dlgToken,
            password: $dlgPassword,
            deviceId: $dlgDeviceId,
            deviceName: $dlgDeviceName,
            virtualIp: $dlgVirtualIp,
            mtuText: $dlgMtuText,
            useChannel: $dlgUseChannel,
            stunServers: $dlgStunServers,
            nameServers: $dlgNameServers,
            ports: $dlgPorts,
            cipher: $dlgCipher,
            compressor: $dlgCompressor,
            serverEncrypt: $dlgServerEncrypt,
            finger: $dlgFinger,
            traffic: $dlgTraffic,
            onSave: (): void => {
              this.saveDialogConfig();
            },
            onClose: (): void => {
              this.dialogOpen = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .backgroundColor('rgba(0, 0, 0, 0.55)')
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.dialogOpen = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
