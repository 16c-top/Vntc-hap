export const version: () => string;
export const coreVersion: () => string;
export const setCoreVersion: (coreVersion: string) => boolean;
export const start: (tunFd: number, token: string, deviceId: string, name: string, server: string,
  password: string, virtualIp: string, mtu: number, useChannel: number, stunServers: string,
  nameServers: string, ports: string, cipherModel: number, compressor: number,
  serverEncrypt: number, finger: number, enableTraffic: number, inIps: string, outIps: string,
  mapping: string) => Promise<boolean>;
export const startJson: (tunFd: number, json: string) => Promise<boolean>;
export const stop: () => boolean;
export const isRunning: () => boolean;
export const status: () => string;
export const deviceList: () => string;
export const deviceDetail: () => string;
export const routeTable: () => string;
export const lastError: () => string;
export const upStream: () => number;
export const downStream: () => number;
export const setEventListener: (listener: ((event: number, json: string) => void) | null) => void;
