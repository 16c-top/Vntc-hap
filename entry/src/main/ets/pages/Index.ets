import { Want, common } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError, commonEventManager, deviceInfo } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import vntNapi from 'libvnt_napi.so';
import { VPN_STATUS_EVENT } from '../vpn/VpnConst';
import { VpnConfigItem } from '../vpn/VpnConfigItem';
import { ConfigStore } from '../vpn/ConfigStore';

const BUNDLE_NAME: string = 'top.16c.vntc';
const VPN_ABILITY_NAME: string = 'VntVpnAbility';
const HEARTBEAT_TIMEOUT_MS: number = 6000;
const DEFAULT_MTU: number = 1400;
const DEFAULT_DNS: Array<string> = ['223.5.5.5', '114.114.114.114'];
const DEFAULT_STUN: Array<string> =
  ['stun.miwifi.com', 'stun.chat.bilibili.com', 'stun.hitv.com', 'stun.cdnbye.com'];

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
struct DlgField {
  label: string = '';
  placeholder: string = '';
  @Link text: string;
  isPassword: boolean = false;

  build() {
    Column() {
      Text(this.label)
        .fontSize(13)
        .fontColor(COLOR_TEXT_SUB)
        .margin({ bottom: 6 })
      TextInput({ placeholder: this.placeholder, text: this.text })
        .onChange((value: string): void => {
          this.text = value;
        })
        .type(this.isPassword ? InputType.Password : InputType.Normal)
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
  @Link dnsList: Array<string>;
  @Link stunList: Array<string>;
  @Link inList: Array<string>;
  @Link outList: Array<string>;
  @Link mappingList: Array<string>;
  @State expChannel: boolean = false;
  @State expSubnet: boolean = false;
  @State expMapping: boolean = false;
  @State expAdvanced: boolean = false;
  @Link ports: string;
  @Link cipher: string;
  @Link compressor: string;
  @Link serverEncrypt: boolean;
  @Link finger: boolean;
  @Link traffic: boolean;
  @Prop coreVersion: string = 'v1';
  onSave: () => void = (): void => {};
  onClose: () => void = (): void => {};
  @State tip: string = '';

  private closeDialog(): void {
    this.onClose();
  }

  private applyScanResult(content: string): boolean {
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(content) as Record<string, Object>;
    } catch (e) {
      this.tip = '二维码不是有效的 JSON';
      return false;
    }
    if (parsed['type'] !== 'vnt-network') {
      this.tip = '二维码不是 vnt-network 组网信息';
      return false;
    }
    const codeVal: Object | undefined = parsed['network_code'];
    if (typeof codeVal !== 'string' || codeVal === '') {
      this.tip = '二维码缺少 network_code';
      return false;
    }
    this.token = codeVal;
    const serverVal: Object | undefined = parsed['server'];
    if (Array.isArray(serverVal)) {
      const servers: Array<string> = [];
      for (let i = 0; i < serverVal.length; i++) {
        const item: Object = serverVal[i];
        if (typeof item === 'string' && item.trim() !== '') {
          servers.push(item.trim());
        }
      }
      this.server = servers.join(',');
    } else if (typeof serverVal === 'string' && serverVal !== '') {
      this.server = serverVal;
    }
    const mtuVal: Object | undefined = parsed['mtu'];
    if (typeof mtuVal === 'number' && mtuVal > 0) {
      this.mtuText = `${mtuVal}`;
    }
    const pwdVal: Object | undefined = parsed['password'];
    if (typeof pwdVal === 'string' && pwdVal !== '') {
      this.password = pwdVal;
    }
    this.tip = '';
    return true;
  }

  private doScan(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.tip = '无法获取上下文';
      return;
    }
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: false,
      enableAlbum: true
    };
    scanBarcode.startScanForResult(ctx, options).then((result: scanBarcode.ScanResult): void => {
      const content: string = result.originalValue;
      if (content === '') {
        return;
      }
      this.applyScanResult(content);
    }).catch((err: BusinessError): void => {
      this.tip = `扫码失败 ${err.code}: ${err.message}`;
    });
  }

  private doSave(): void {
    if (this.name === '' || this.server === '' || this.token === '') {
      this.tip = '名称、服务端、令牌为必填项';
      return;
    }
    if (this.coreVersion === 'v2') {
      const sv: string = this.server.trim();
      if (sv.startsWith('udp://') || sv.startsWith('ws://')) {
        this.tip = 'V2 内核不支持 udp:// 与明文 ws://，请使用 tcp://、wss://、quic:// 或 dynamic://';
        return;
      }
      if (sv.includes(',') && this.virtualIp.trim() === '') {
        this.tip = 'V2 多服务端地址必须指定固定虚拟 IP';
        return;
      }
    }
    this.tip = '';
    this.onSave();
    this.closeDialog();
  }

  private cipherOptions(): SelectOption[] {
    if (this.coreVersion === 'v2') {
      return [
        { value: 'V2 固定 ChaCha20-Poly1305' }
      ];
    }
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

  private cipherDisplayIndex(): number {
    if (this.coreVersion === 'v2') {
      return 0;
    }
    const idx: number = Number(this.cipher);
    return (idx >= 0 && idx < this.cipherOptions().length) ? idx : 0;
  }

  private onCipherSelect(index: number): void {
    if (this.coreVersion === 'v2') {
      return;
    }
    this.cipher = `${index}`;
  }

  private compressorOptions(): SelectOption[] {
    if (this.coreVersion === 'v2') {
      return [
        { value: '关闭' },
        { value: '开启（LZ4）' }
      ];
    }
    return [
      { value: '不压缩' },
      { value: 'LZ4（默认）' },
      { value: 'Zstd' }
    ];
  }

  private compressorDisplayIndex(): number {
    if (this.coreVersion === 'v2') {
      return Number(this.compressor) > 0 ? 1 : 0;
    }
    const idx: number = Number(this.compressor);
    return (idx >= 0 && idx < this.compressorOptions().length) ? idx : 1;
  }

  private onCompressorSelect(index: number): void {
    if (this.coreVersion === 'v2') {
      this.compressor = index === 1 ? '1' : '0';
      return;
    }
    this.compressor = `${index}`;
  }

  private serverPlaceholder(): string {
    return this.coreVersion === 'v2' ? 'tcp://host:port（强制 TLS）' : 'udp://host:port';
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
  dlgServerRows(isDns: boolean) {
    Column() {
      Text(isDns ? 'DNS 服务器' : 'STUN 服务器')
        .fontSize(13)
        .fontColor(COLOR_TEXT_SUB)
        .margin({ bottom: 6 })
        .width('100%')
      ForEach(isDns ? this.dnsList : this.stunList, (item: string, index: number) => {
        Row({ space: 8 }) {
          TextInput({ placeholder: isDns ? '如 223.5.5.5' : '如 stun.miwifi.com', text: item })
            .onChange((value: string): void => {
              if (isDns) {
                this.dnsList[index] = value;
              } else {
                this.stunList[index] = value;
              }
            })
            .type(InputType.Normal)
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(COLOR_TEXT_MAIN)
            .placeholderColor(COLOR_TEXT_FAINT)
            .backgroundColor(COLOR_INPUT)
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
          Text('−')
            .fontSize(18)
            .fontColor(COLOR_RED)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .backgroundColor(COLOR_INPUT)
            .borderRadius(10)
            .onClick((): void => {
              if (isDns) {
                this.dnsList.splice(index, 1);
              } else {
                this.stunList.splice(index, 1);
              }
            })
        }
        .width('100%')
        .margin({ bottom: 8 })
      }, (item: string, index: number): string => `${index}`)
      Text('+ 添加一行')
        .fontSize(12)
        .fontColor(COLOR_ACCENT_END)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(COLOR_INPUT)
        .borderRadius(10)
        .onClick((): void => {
          if (isDns) {
            this.dnsList.push('');
          } else {
            this.stunList.push('');
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
  }

  @Builder
  sectionHeader(title: string, expanded: boolean, onToggle: () => void) {
    Row() {
      Text(title)
        .fontSize(13)
        .fontColor(COLOR_ACCENT_END)
        .fontWeight(FontWeight.Medium)
      Column()
        .layoutWeight(1)
      Text(expanded ? '▾' : '▸')
        .fontSize(12)
        .fontColor(COLOR_TEXT_FAINT)
    }
    .width('100%')
    .padding({ top: 6, bottom: 8 })
    .onClick((): void => {
      onToggle();
    })
  }

  @Builder
  dlgRouteRows(isOut: boolean) {
    Column() {
      Text(isOut ? '出站路由：暴露本机所在网段，格式 x.x.x.x/mask' :
        '入站路由：经对端网关访问网段，格式 x.x.x.x/mask,对端虚拟IP')
        .fontSize(12)
        .fontColor(COLOR_TEXT_FAINT)
        .margin({ bottom: 6 })
        .width('100%')
      ForEach(isOut ? this.outList : this.inList, (item: string, index: number) => {
        Row({ space: 8 }) {
          TextInput({
            placeholder: isOut ? '如 192.168.1.0/24' : '如 192.168.0.0/24,10.26.0.3',
            text: item
          })
            .onChange((value: string): void => {
              if (isOut) {
                this.outList[index] = value;
              } else {
                this.inList[index] = value;
              }
            })
            .type(InputType.Normal)
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(COLOR_TEXT_MAIN)
            .placeholderColor(COLOR_TEXT_FAINT)
            .backgroundColor(COLOR_INPUT)
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
          Text('−')
            .fontSize(18)
            .fontColor(COLOR_RED)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .backgroundColor(COLOR_INPUT)
            .borderRadius(10)
            .onClick((): void => {
              if (isOut) {
                this.outList.splice(index, 1);
              } else {
                this.inList.splice(index, 1);
              }
            })
        }
        .width('100%')
        .margin({ bottom: 8 })
      }, (item: string, index: number): string => `${index}`)
      Text('+ 添加一行')
        .fontSize(12)
        .fontColor(COLOR_ACCENT_END)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(COLOR_INPUT)
        .borderRadius(10)
        .onClick((): void => {
          if (isOut) {
            this.outList.push('');
          } else {
            this.inList.push('');
          }
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
  }

  @Builder
  dlgMappingRows() {
    Column() {
      Text(this.coreVersion === 'v2' ?
        'V2 格式 协议://本机地址:端口-虚拟目标IP-目标主机:端口\n' +
        '示例 tcp://0.0.0.0:8080-10.26.0.10-192.168.1.5:80' :
        '格式 协议:本机地址:端口-目标地址:端口（单个 - 分隔）\n' +
        '示例 tcp:127.0.0.1:80-10.26.0.10:8080')
        .fontSize(12)
        .fontColor(COLOR_TEXT_FAINT)
        .margin({ bottom: 6 })
        .width('100%')
      ForEach(this.mappingList, (item: string, index: number) => {
        Row({ space: 8 }) {
          TextInput({
            placeholder: this.coreVersion === 'v2' ? 'tcp://0.0.0.0:8080-10.26.0.10-192.168.1.5:80' :
              'tcp:127.0.0.1:80-10.26.0.10:8080',
            text: item
          })
            .onChange((value: string): void => {
              this.mappingList[index] = value;
            })
            .type(InputType.Normal)
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(COLOR_TEXT_MAIN)
            .placeholderColor(COLOR_TEXT_FAINT)
            .backgroundColor(COLOR_INPUT)
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
          Text('−')
            .fontSize(18)
            .fontColor(COLOR_RED)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .backgroundColor(COLOR_INPUT)
            .borderRadius(10)
            .onClick((): void => {
              this.mappingList.splice(index, 1);
            })
        }
        .width('100%')
        .margin({ bottom: 8 })
      }, (item: string, index: number): string => `${index}`)
      Text('+ 添加一行')
        .fontSize(12)
        .fontColor(COLOR_ACCENT_END)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor(COLOR_INPUT)
        .borderRadius(10)
        .onClick((): void => {
          this.mappingList.push('');
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
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
      Row() {
        Text(`${this.title} · ${this.coreVersion === 'v2' ? 'V2' : 'V1'} 内核`)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.coreVersion === 'v2') {
          Text('扫码导入')
            .fontSize(13)
            .fontColor(COLOR_ACCENT_END)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(COLOR_INPUT)
            .borderRadius(10)
            .margin({ left: 8 })
            .onClick((): void => {
              this.doScan();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          DlgField({ label: '配置名称', placeholder: '如：家里服务器', text: $name, isPassword: false })
          DlgField({ label: '服务端', placeholder: this.serverPlaceholder(), text: $server, isPassword: false })
          DlgField({ label: '令牌 Token', placeholder: '与服务端一致', text: $token, isPassword: false })
          DlgField({ label: '密码（可选）', placeholder: '组网密码', text: $password, isPassword: true })
          DlgField({ label: '设备 ID', placeholder: '留空自动生成', text: $deviceId, isPassword: false })
          DlgField({ label: '设备名称', placeholder: '展示名称', text: $deviceName, isPassword: false })
          DlgField({ label: '虚拟 IP', placeholder: '留空由服务端分配', text: $virtualIp, isPassword: false })
          DlgField({ label: 'MTU', placeholder: '默认 1400', text: $mtuText, isPassword: false })

          this.sectionHeader('通道模式', this.expChannel, (): void => {
            this.expChannel = !this.expChannel;
          })
          if (this.expChannel) {
            Row({ space: 8 }) {
              this.dlgModeButton('仅中继', '0')
              this.dlgModeButton('仅 P2P', '1')
              this.dlgModeButton('自动（推荐）', '2')
            }
            .width('100%')
            .margin({ bottom: 10 })
          }

          // 本地端口配置暂不开放
          // this.dlgField('本地端口', '逗号分隔，如 35535,35536', this.ports, false,
          //   (value: string): void => {
          //     this.ports = value;
          //   })

          this.sectionHeader('子网代理', this.expSubnet, (): void => {
            this.expSubnet = !this.expSubnet;
          })
          if (this.expSubnet) {
            this.dlgRouteRows(false)
            this.dlgRouteRows(true)
          }

          this.sectionHeader('端口映射', this.expMapping, (): void => {
            this.expMapping = !this.expMapping;
          })
          if (this.expMapping) {
            this.dlgMappingRows()
          }

          this.sectionHeader('高级选项', this.expAdvanced, (): void => {
            this.expAdvanced = !this.expAdvanced;
          })
          if (this.expAdvanced) {
            this.dlgServerRows(false)
            if (this.coreVersion !== 'v2') {
              this.dlgServerRows(true)
            }
            Row() {
            Text('加密算法')
              .fontSize(13)
              .fontColor(COLOR_TEXT_SUB)
              .layoutWeight(1)
            Select(this.cipherOptions())
              .selected(this.cipherDisplayIndex())
              .value(this.cipherOptions()[this.cipherDisplayIndex()].value as string)
              .font({ size: 13 })
              .fontColor(COLOR_TEXT_MAIN)
              .optionFont({ size: 13 })
              .optionFontColor(COLOR_TEXT_MAIN)
              .optionBgColor(COLOR_INPUT)
              .selectedOptionFont({ size: 13 })
              .selectedOptionFontColor('#FFFFFF')
              .selectedOptionBgColor(COLOR_ACCENT_START)
              .menuBackgroundColor(COLOR_CARD)
              .onSelect((index: number): void => {
                this.onCipherSelect(index);
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
              .selected(this.compressorDisplayIndex())
              .value(this.compressorOptions()[this.compressorDisplayIndex()].value as string)
              .font({ size: 13 })
              .fontColor(COLOR_TEXT_MAIN)
              .optionFont({ size: 13 })
              .optionFontColor(COLOR_TEXT_MAIN)
              .optionBgColor(COLOR_INPUT)
              .selectedOptionFont({ size: 13 })
              .selectedOptionFontColor('#FFFFFF')
              .selectedOptionBgColor(COLOR_ACCENT_START)
              .menuBackgroundColor(COLOR_CARD)
              .onSelect((index: number): void => {
                this.onCompressorSelect(index);
              })
          }
          .width('100%')
          .margin({ bottom: 10 })
          if (this.coreVersion !== 'v2') {
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
          } else {
            Text('V2 内核：加密、服务端传输加密、流量统计由内核固定实现，以上选项不可配置')
              .fontSize(12)
              .fontColor(COLOR_TEXT_FAINT)
              .width('100%')
              .margin({ bottom: 10 })
          }
          }
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
    .onClick((): void => {
    })
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
  @State deviceDetails: Array<Record<string, Object>> = [];
  @State routeTable: Array<Record<string, Object>> = [];
  @State detailDevIp: string = '';
  @State detailOpen: boolean = false;
  @State connectStart: number = 0;
  @State runElapsed: number = 0;
  @State coreVersion: string = 'v1';
  @State coreLibVersion: string = '';
  @State coreDropdownOpen: boolean = false;

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
  @State dlgDnsList: Array<string> = DEFAULT_DNS.slice();
  @State dlgStunList: Array<string> = DEFAULT_STUN.slice();
  @State dlgInList: Array<string> = [];
  @State dlgOutList: Array<string> = [];
  @State dlgMappingList: Array<string> = [];
  @State dlgPorts: string = '';
  @State dlgCipher: string = '0';
  @State dlgCompressor: string = '1';
  @State dlgServerEncrypt: boolean = true;
  @State dlgFinger: boolean = true;
  @State dlgTraffic: boolean = true;
  @State dlgCoreVersion: string = 'v1';
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
        .then((id: string): Promise<string> => {
          this.selectedId = id;
          return this.store.loadCoreVersion();
        })
        .then((version: string): void => {
          this.coreVersion = version;
          this.applyCoreVersion();
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
    const details: Object | undefined = payload['device_detail'];
    if (Array.isArray(details)) {
      this.deviceDetails = details as Array<Record<string, Object>>;
    }
    const routes: Object | undefined = payload['route_table'];
    if (Array.isArray(routes)) {
      this.routeTable = routes as Array<Record<string, Object>>;
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

  private describeDevStatus(dev: Record<string, Object> | undefined): string {
    if (dev === undefined || dev['online'] !== true) {
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

  private findDeviceDetail(ip: string): Record<string, Object> | undefined {
    for (let i = 0; i < this.deviceDetails.length; i++) {
      if (this.deviceDetails[i]['ip'] === ip) {
        return this.deviceDetails[i];
      }
    }
    return undefined;
  }

  private detailText(dev: Record<string, Object> | undefined, key: string): string {
    if (dev === undefined) {
      return '--';
    }
    const val: Object | undefined = dev[key];
    if (typeof val === 'string' && val !== '') {
      return val;
    }
    if (typeof val === 'number') {
      return `${val}`;
    }
    return '--';
  }

  private detailIps(dev: Record<string, Object> | undefined): string {
    if (dev === undefined) {
      return '--';
    }
    const val: Object | undefined = dev['public_ips'];
    if (Array.isArray(val) && val.length > 0) {
      const out: Array<string> = [];
      for (let i = 0; i < val.length; i++) {
        const item: Object = val[i];
        if (typeof item === 'string' && item !== '') {
          out.push(item);
        }
      }
      if (out.length > 0) {
        return out.join('、');
      }
    }
    return '--';
  }

  private detailNum(dev: Record<string, Object> | undefined, key: string, suffix: string): string {
    if (dev === undefined) {
      return '--';
    }
    const val: Object | undefined = dev[key];
    if (typeof val === 'number' && val >= 0) {
      return `${val}${suffix}`;
    }
    return '--';
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

  private splitList(raw: string): Array<string> {
    const out: Array<string> = [];
    if (raw !== '') {
      const parts: Array<string> = raw.split(';');
      for (let i = 0; i < parts.length; i++) {
        const item: string = parts[i].trim();
        if (item !== '') {
          out.push(item);
        }
      }
    }
    return out;
  }

  private splitServers(raw: string, defaults: Array<string>): Array<string> {
    const out: Array<string> = [];
    if (raw !== '') {
      const parts: Array<string> = raw.split(',');
      for (let i = 0; i < parts.length; i++) {
        const item: string = parts[i].trim();
        if (item !== '') {
          out.push(item);
        }
      }
    }
    return out.length > 0 ? out : defaults.slice();
  }

  private joinServers(list: Array<string>, sep: string): string {
    const out: Array<string> = [];
    for (let i = 0; i < list.length; i++) {
      const item: string = list[i].trim();
      if (item !== '') {
        out.push(item);
      }
    }
    return out.join(sep);
  }

  private genId(): string {
    return `cfg_${Date.now()}`;
  }

  private cfgCoreVersion(cfg: VpnConfigItem): string {
    return cfg.coreVersion === 'v2' ? 'v2' : 'v1';
  }

  private selectConfig(id: string): void {
    if (this.running) {
      this.errMsg = '连接运行中，请先停止再切换配置';
      return;
    }
    let target: VpnConfigItem | undefined = undefined;
    for (let i = 0; i < this.configs.length; i++) {
      if (this.configs[i].id === id) {
        target = this.configs[i];
        break;
      }
    }
    if (target === undefined) {
      return;
    }
    if (this.cfgCoreVersion(target) !== this.coreVersion) {
      this.errMsg = `该配置属于 ${this.coreVersionLabel(this.cfgCoreVersion(target))} 内核，请先切换内核`;
      return;
    }
    this.selectedId = id;
    this.dropdownOpen = false;
    this.store.saveSelected(id);
  }

  private openNewConfig(): void {
    this.editingId = '';
    this.dlgTitle = '新增配置';
    this.dlgCoreVersion = this.coreVersion;
    this.dlgName = '';
    this.dlgServer = '';
    this.dlgToken = '';
    this.dlgPassword = '';
    this.dlgDeviceId = '';
    this.dlgDeviceName = deviceInfo.marketName !== '' ? deviceInfo.marketName : deviceInfo.productModel;
    this.dlgVirtualIp = '';
    this.dlgMtuText = '1400';
    this.dlgUseChannel = '2';
    this.dlgDnsList = DEFAULT_DNS.slice();
    this.dlgStunList = DEFAULT_STUN.slice();
    this.dlgInList = [];
    this.dlgOutList = [];
    this.dlgMappingList = [];
    this.dlgPorts = '';
    this.dlgCipher = '0';
    this.dlgCompressor = this.dlgCoreVersion === 'v2' ? '0' : '1';
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
    this.dlgCoreVersion = this.cfgCoreVersion(cfg);
    this.dlgName = cfg.name;
    this.dlgServer = cfg.server;
    this.dlgToken = cfg.token;
    this.dlgPassword = cfg.password;
    this.dlgDeviceId = cfg.deviceId;
    this.dlgDeviceName = cfg.deviceName;
    this.dlgVirtualIp = cfg.virtualIp;
    this.dlgMtuText = cfg.mtu;
    this.dlgUseChannel = (typeof cfg.useChannel === 'string' && cfg.useChannel !== '') ? cfg.useChannel : '2';
    this.dlgDnsList = this.splitServers(cfg.nameServers ?? '', DEFAULT_DNS);
    this.dlgStunList = this.splitServers(cfg.stunServers ?? '', DEFAULT_STUN);
    this.dlgInList = this.splitList(cfg.inIps ?? '');
    this.dlgOutList = this.splitList(cfg.outIps ?? '');
    this.dlgMappingList = this.splitList(cfg.portMappings ?? '');
    this.dlgPorts = cfg.ports ?? '';
    this.dlgCipher = (typeof cfg.cipherModel === 'string' && cfg.cipherModel !== '') ? cfg.cipherModel : '0';
    this.dlgCompressor = (typeof cfg.compressor === 'string' && cfg.compressor !== '')
      ? cfg.compressor : (this.dlgCoreVersion === 'v2' ? '0' : '1');
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
      coreVersion: this.dlgCoreVersion,
      server: this.dlgServer,
      token: this.dlgToken,
      password: this.dlgPassword,
      deviceId: devId,
      deviceName: this.dlgDeviceName,
      virtualIp: this.dlgVirtualIp,
      mtu: this.dlgMtuText,
      useChannel: this.dlgUseChannel,
      stunServers: this.joinServers(this.dlgStunList, ','),
      nameServers: this.joinServers(this.dlgDnsList, ','),
      inIps: this.joinServers(this.dlgInList, ';'),
      outIps: this.joinServers(this.dlgOutList, ';'),
      portMappings: this.joinServers(this.dlgMappingList, ';'),
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

  private applyCoreVersion(): void {
    if (vntNapi.setCoreVersion(this.coreVersion)) {
      this.coreLibVersion = vntNapi.version();
    } else {
      this.coreLibVersion = '';
      this.errMsg = `内核 ${this.coreVersion} 加载失败：${vntNapi.lastError()}`;
    }
  }

  private coreVersionLabel(version: string): string {
    return version === 'v2' ? 'V2' : 'V1';
  }

  @Builder
  coreDropdownRow(version: string, label: string, desc: string) {
    Row() {
      Column() {
        Text(label)
          .fontSize(13)
          .fontColor(this.coreVersion === version ? COLOR_TEXT_MAIN : COLOR_TEXT_SUB)
        Text(desc)
          .fontSize(11)
          .fontColor(COLOR_TEXT_FAINT)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.coreVersion === version) {
        Text('✓')
          .fontSize(13)
          .fontColor(COLOR_ACCENT_END)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 8, bottom: 8, left: 12, right: 12 })
    .borderRadius(10)
    .backgroundColor(this.coreVersion === version ? COLOR_INPUT : '#00000000')
    .onClick((): void => {
      this.coreDropdownOpen = false;
      this.onCoreSelect(version === 'v2' ? 1 : 0);
    })
  }

  @Builder
  coreDropdownPanel() {
    Column({ space: 4 }) {
      this.coreDropdownRow('v1', 'V1 内核', '连接 1.x 服务端，支持 zstd')
      this.coreDropdownRow('v2', 'V2 内核', '连接 2.x 服务端，强制 TLS')
    }
    .width(220)
    .padding(8)
  }

  private onCoreSelect(index: number): void {
    if (this.running) {
      this.errMsg = '连接运行中，请先停止再切换内核';
      return;
    }
    const next: string = index === 1 ? 'v2' : 'v1';
    if (next === this.coreVersion) {
      return;
    }
    this.coreVersion = next;
    this.store.saveCoreVersion(next);
    this.applyCoreVersion();
    let msg: string = `已切换到 ${this.coreVersionLabel(next)} 内核`;
    if (this.coreLibVersion !== '') {
      msg += `（v${this.coreLibVersion}）`;
    }
    const current: VpnConfigItem | undefined = this.selectedConfig();
    if (current !== undefined && this.cfgCoreVersion(current) === next) {
      this.lastEvent = msg;
      return;
    }
    let firstMatch: VpnConfigItem | undefined = undefined;
    for (let i = 0; i < this.configs.length; i++) {
      if (this.cfgCoreVersion(this.configs[i]) === next) {
        firstMatch = this.configs[i];
        break;
      }
    }
    if (firstMatch !== undefined) {
      this.selectedId = firstMatch.id;
      this.store.saveSelected(firstMatch.id);
      msg += `，已自动选择配置「${firstMatch.name}」`;
    } else {
      this.selectedId = '';
      this.store.saveSelected('');
      msg += '，暂无支持该内核的配置';
    }
    this.lastEvent = msg;
  }

  private startVpn(): void {
    const cfg: VpnConfigItem | undefined = this.selectedConfig();
    if (cfg === undefined) {
      this.errMsg = '请先在下拉框选择一个配置';
      return;
    }
    const cfgVer: string = this.cfgCoreVersion(cfg);
    if (cfgVer !== this.coreVersion) {
      this.errMsg = `当前为 ${this.coreVersionLabel(this.coreVersion)} 内核，该配置属于 ` +
        `${this.coreVersionLabel(cfgVer)} 内核，请先切换内核`;
      return;
    }
    if (this.running) {
      this.errMsg = '连接已在运行，请先停止';
      return;
    }
    if (this.coreVersion === 'v2') {
      const sv: string = cfg.server.trim();
      if (sv.startsWith('udp://') || sv.startsWith('ws://')) {
        this.errMsg = 'V2 内核不支持 udp:// 与明文 ws://，请修改服务端地址';
        return;
      }
      if (sv.includes(',') && cfg.virtualIp.trim() === '') {
        this.errMsg = 'V2 多服务端地址必须指定固定虚拟 IP，请在配置中填写';
        return;
      }
    }
    const mtuParsed: number = Number(cfg.mtu);
    const mtu: number = mtuParsed > 0 ? mtuParsed : DEFAULT_MTU;
    const ucParsed: number = Number(cfg.useChannel);
    const ciParsed: number = Number(cfg.cipherModel);
    const coParsed: number = Number(cfg.compressor);
    const params: Record<string, Object> = {
      'coreVersion': this.coreVersion,
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
      'inIps': cfg.inIps ?? '',
      'outIps': (cfg.outIps ?? '').split(';').filter((s: string): boolean => s.trim() !== '').join(','),
      'mapping': cfg.portMappings ?? '',
      'cipherModel': (ciParsed >= 0 && ciParsed <= 6) ? ciParsed : 0,
      'compressor': (coParsed >= 0 && coParsed <= 2) ? coParsed : (this.coreVersion === 'v2' ? 0 : 1),
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
              if (this.cfgCoreVersion(cfg) === this.coreVersion) {
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

                  Text(this.coreVersionLabel(this.cfgCoreVersion(cfg)))
                    .fontSize(10)
                    .fontColor(this.cfgCoreVersion(cfg) === 'v2' ? COLOR_ACCENT_END : COLOR_TEXT_FAINT)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(COLOR_CARD)
                    .borderRadius(6)
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
              } else {
                Row({ space: 8 }) {
                  Column() {
                    Text(cfg.name)
                      .fontSize(15)
                      .fontColor(COLOR_TEXT_FAINT)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`属于 ${this.coreVersionLabel(this.cfgCoreVersion(cfg))} 内核，切换内核后可选`)
                      .fontSize(11)
                      .fontColor(COLOR_TEXT_FAINT)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .onClick((): void => {
                    this.errMsg = `该配置属于 ${this.coreVersionLabel(this.cfgCoreVersion(cfg))} 内核，请先切换内核`;
                  })

                  Text(this.coreVersionLabel(this.cfgCoreVersion(cfg)))
                    .fontSize(10)
                    .fontColor(COLOR_TEXT_FAINT)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .backgroundColor(COLOR_CARD)
                    .borderRadius(6)
                  Text('详情')
                    .fontSize(12)
                    .fontColor(COLOR_TEXT_FAINT)
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
                .opacity(0.6)
              }
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

  @Builder
  detailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(COLOR_TEXT_FAINT)
        .width(96)
      Text(value)
        .fontSize(13)
        .fontColor(COLOR_TEXT_MAIN)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  deviceDetailPanel() {
    Column() {
      Row() {
        Column() {
          Text(this.detailText(this.findDeviceDetail(this.detailDevIp), 'name'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_TEXT_MAIN)
          Text(this.detailDevIp)
            .fontSize(12)
            .fontColor(COLOR_TEXT_SUB)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('关闭')
          .fontSize(14)
          .fontColor(COLOR_TEXT_SUB)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(COLOR_INPUT)
          .borderRadius(10)
          .onClick((): void => {
            this.detailOpen = false;
          })
      }
      .width('100%')
      .margin({ bottom: 12 })

      Text('对端 NAT 信息')
        .fontSize(13)
        .fontColor(COLOR_ACCENT_END)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ bottom: 4 })
      Column() {
        this.detailRow('状态', this.describeDevStatus(this.findDeviceDetail(this.detailDevIp)))
        this.detailRow('NAT 类型', this.detailText(this.findDeviceDetail(this.detailDevIp), 'nat_type'))
        this.detailRow('本地 IPv4', this.detailText(this.findDeviceDetail(this.detailDevIp), 'local_ipv4'))
        this.detailRow('公网出口', this.detailIps(this.findDeviceDetail(this.detailDevIp)))
        this.detailRow('IPv6', this.detailText(this.findDeviceDetail(this.detailDevIp), 'ipv6'))
        this.detailRow('时延', this.detailNum(this.findDeviceDetail(this.detailDevIp), 'delay', 'ms'))
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLOR_INPUT)
      .borderRadius(12)

      Text('路由表')
        .fontSize(13)
        .fontColor(COLOR_ACCENT_END)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .margin({ top: 16, bottom: 4 })

      List({ space: 6 }) {
        if (this.routeTable.length === 0) {
          ListItem() {
            Text('暂无路由信息')
              .fontSize(13)
              .fontColor(COLOR_TEXT_FAINT)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 16, bottom: 16 })
          }
        } else {
          ForEach(this.routeTable, (route: Record<string, Object>) => {
            ListItem() {
              Column({ space: 4 }) {
                Row({ space: 8 }) {
                  Text(`${route['destination']}`)
                    .fontSize(13)
                    .fontColor(COLOR_TEXT_MAIN)
                    .fontWeight(FontWeight.Medium)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${route['protocol'] ?? ''}`)
                    .fontSize(11)
                    .fontColor(COLOR_ACCENT_END)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor(COLOR_CARD)
                    .borderRadius(8)
                }
                .width('100%')
                Text(`下一跳 ${route['next_hop'] ?? '--'} · 跳数 ${route['metric'] ?? '--'} · ` +
                  `${typeof route['rtt'] === 'number' && (route['rtt'] as number) >= 0 ? `${route['rtt']}ms` : '未测得'}`)
                  .fontSize(11)
                  .fontColor(COLOR_TEXT_SUB)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(`承载 ${route['interface'] ?? '--'}`)
                  .fontSize(11)
                  .fontColor(COLOR_TEXT_FAINT)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(10)
              .backgroundColor(COLOR_INPUT)
              .borderRadius(10)
            }
            .width('100%')
          }, (route: Record<string, Object>): string =>
            `${route['destination']}_${route['next_hop']}_${route['metric']}_${route['rtt']}_${route['interface']}`)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .margin({ top: 4 })
    }
    .width('92%')
    .height('88%')
    .padding(20)
    .backgroundColor(COLOR_CARD)
    .borderRadius(16)
    .border({ width: 1, color: COLOR_CARD_BORDER })
    .onClick((): void => {
    })
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
            Row({ space: 8 }) {
              Text('内核版本')
                .fontSize(13)
                .fontColor(COLOR_TEXT_SUB)
              Text(`${this.coreVersionLabel(this.coreVersion)} 内核 ▾`)
                .fontSize(12)
                .fontColor(COLOR_TEXT_MAIN)
                .height(26)
                .padding({ left: 10, right: 10 })
                .backgroundColor(COLOR_INPUT)
                .borderRadius(8)
                .onClick((): void => {
                  if (this.running) {
                    this.errMsg = '连接运行中，请先停止再切换内核';
                    return;
                  }
                  this.coreDropdownOpen = !this.coreDropdownOpen;
                })
                .bindPopup(this.coreDropdownOpen, {
                  builder: (): void => {
                    this.coreDropdownPanel();
                  },
                  placement: Placement.BottomLeft,
                  popupColor: COLOR_CARD,
                  backgroundBlurStyle: BlurStyle.NONE,
                  enableArrow: false,
                  autoCancel: true,
                  targetSpace: 6,
                  mask: { color: '#00000000' },
                  onStateChange: (e: PopupStateChangeEvent): void => {
                    if (!e.isVisible) {
                      this.coreDropdownOpen = false;
                    }
                  }
                })
              Text(this.coreLibVersion === '' ? '' : `v${this.coreLibVersion}`)
                .fontSize(12)
                .fontColor(COLOR_TEXT_FAINT)
            }
            .margin({ top: 4 })
            .alignItems(VerticalAlign.Center)
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
                  Button(this.online ? '断开连接' : '取消连接')
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
                  .onClick((): void => {
                    this.detailDevIp = `${dev['ip']}`;
                    this.detailOpen = true;
                  })
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
            dnsList: $dlgDnsList,
            stunList: $dlgStunList,
            inList: $dlgInList,
            outList: $dlgOutList,
            mappingList: $dlgMappingList,
            ports: $dlgPorts,
            cipher: $dlgCipher,
            compressor: $dlgCompressor,
            serverEncrypt: $dlgServerEncrypt,
            finger: $dlgFinger,
            traffic: $dlgTraffic,
            coreVersion: this.dlgCoreVersion,
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

      if (this.detailOpen) {
        Column() {
          this.deviceDetailPanel()
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .backgroundColor('rgba(0, 0, 0, 0.55)')
        .justifyContent(FlexAlign.Center)
        .onClick((): void => {
          this.detailOpen = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
