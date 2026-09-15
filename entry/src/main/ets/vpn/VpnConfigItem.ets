export interface VpnConfigItem {
  id: string;
  name: string;
  coreVersion?: string;
  server: string;
  token: string;
  password: string;
  deviceId: string;
  deviceName: string;
  virtualIp: string;
  mtu: string;
  useChannel: string;
  inIps?: string;
  outIps?: string;
  portMappings?: string;
  stunServers: string;
  nameServers: string;
  ports: string;
  cipherModel: string;
  compressor: string;
  serverEncrypt: boolean;
  finger: boolean;
  enableTraffic: boolean;
}
