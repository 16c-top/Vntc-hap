/*
 * vnt_ffi —— vnt 2.0 动态库 C 接口
 *
 * 使用方式：调用方（App / VpnExtensionAbility）负责创建虚拟网卡，
 * 把 tun 的文件描述符作为 vnt_start_json() 的 tun_fd 参数传入，本库负责收发 IP 报文。
 *
 * 配置入口只有一个：vnt_start_json()，第二个参数是一段 JSON 文本。
 * JSON 字段与 vnt 2.0 的配置文件一一对应，**2.0 支持的全部配置项都可下发**
 * （证书绑定、FEC / RTX、TURN、子网映射、端口映射、事件脚本等）。
 * 未知字段会被拒绝（启动失败），便于尽早发现拼写错误。
 *
 * ⚠️ 与 vnt 1.0 的接口不兼容：
 *    1.0 的 VntConfig 结构体入口 vnt_start / vnt_start_with_port_mapping 已取消，
 *    本头文件不再定义 VntConfig；请改为构造 JSON 后调用 vnt_start_json。
 *    1.0 的枚举常量（VNT_CIPHER_* / VNT_PUNCH_* / VNT_CHANNEL_* / VNT_COMPRESS_*）
 *    也不再提供，相关能力改由 JSON 中的 punch_model / no_punch / compress 等字段表达。
 *
 * 所有由本库返回的 char*（除 vnt_version 外）均需使用 vnt_string_free 释放。
 *
 * 迁移与字段对照见交付包 docs/v1-v2-interface-diff.md、docs/INTERFACE.md。
 */
#ifndef VNT_FFI_H
#define VNT_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------- 常量 ---------------- */

/* 事件类型（vnt_set_event_callback 的 event 参数） */
#define VNT_EVENT_SUCCESS  0 /* 连接成功（拿到虚拟 IP 后） */
#define VNT_EVENT_REGISTER 1 /* 注册成功：{} */
#define VNT_EVENT_TUN_INFO 2 /* 虚拟网卡信息就绪：{"virtual_ip":..,"netmask":..,"gateway":..,"mtu":..} */
#define VNT_EVENT_PEERS    3 /* 设备列表变化：[{"ip":..,"name":..,"online":true}] */
#define VNT_EVENT_ERROR    4 /* 错误：{"code":"ERROR","msg":..} */
#define VNT_EVENT_STOP     5 /* 已停止：{} */

/* 日志级别（vnt_set_log_callback 的 level 参数） */
#define VNT_LOG_ERROR 1
#define VNT_LOG_WARN  2
#define VNT_LOG_INFO  3
#define VNT_LOG_DEBUG 4
#define VNT_LOG_TRACE 5

/* ---------------- 回调 ---------------- */

/* json / msg 仅在回调期间有效，如需保存请自行拷贝 */
typedef void (*vnt_event_cb)(void *ctx, int event, const char *json);
typedef void (*vnt_log_cb)(void *ctx, int level, const char *msg);

/* ---------------- 句柄 ---------------- */

typedef struct VntHandle VntHandle;

/* ---------------- 接口 ---------------- */

/* 库版本号（静态字符串，无需释放） */
const char *vnt_version(void);

/* 初始化日志器，进程内首次调用即可 */
void vnt_init(void);

/* 设置事件回调（cb 传 NULL 取消） */
void vnt_set_event_callback(vnt_event_cb cb, void *ctx);

/* 设置日志回调（cb 传 NULL 取消） */
void vnt_set_log_callback(vnt_log_cb cb, void *ctx);

/*
 * 启动 vnt。
 *   json   : 全量配置（JSON 对象文本，UTF-8，以 '\0' 结尾），字段见下方“配置字段”
 *   tun_fd : 虚拟网卡 fd（VpnConnection.create 返回值）；
 *            传 -1 表示无网卡模式（仅端口映射 / 流量出口，需要 root 权限的场景不适用）；
 *            若 JSON 中显式写了 device_mode，则以 JSON 为准
 *
 * 成功返回句柄，失败返回 NULL，错误见 vnt_last_error()。
 * 注意：本调用是**阻塞**的（内部要完成连接服务端 → 注册 → 启动网卡），
 * 请在子线程中调用，不要在 UI 线程直接调用。
 */
VntHandle *vnt_start_json(const char *json, int tun_fd);

/* 停止并回收内部任务（句柄仍可查询统计）；返回 0 成功，-1 句柄无效 */
int vnt_stop(VntHandle *handle);

/* 释放句柄（内部先停止） */
void vnt_free(VntHandle *handle);

/* 是否运行：1 运行、0 已停止、-1 句柄无效 */
int vnt_is_running(VntHandle *handle);

/* 运行状态 JSON：{"virtual_ip":..,"netmask":..,"gateway":..,"server":..,
 *                "online":true,"running":true,
 *                "channel":"p2p","relay":false,"p2p_peers":1,"relay_peers":0,
 *                "delay":12,"up_stream":0,"down_stream":0}
 * channel    : 本机通道汇总，p2p(全部点对点) / relay(全部中继) / mixed(部分中继) / none(无在线对端)
 * relay      : 当前是否有流量走服务端中继
 * p2p_peers  : 点对点通道的对端数
 * relay_peers: 中继通道的对端数
 * delay      : 已测得通道的平均往返时延（毫秒），未测得为 -1 */
char *vnt_status_json(VntHandle *handle);

/* 设备列表 JSON：[{"ip":..,"name":..,"online":true,"wireguard":false,"channel":"p2p","delay":12}]
 * channel    : p2p / tcp-p2p / server-relay
 * delay      : 该对端的往返时延（毫秒），未测得为 -1
 * name       : 来自服务端 RPC，最长 5 秒刷新一次；刚启动时可能为空 */
char *vnt_device_list_json(VntHandle *handle);

/* 设备详情 JSON：在设备列表基础上附带每个对端的 NAT 信息
 * [{"ip":..,"name":..,"online":true,"wireguard":false,"channel":..,"delay":12,
 *   "nat_type":"Cone","local_ipv4":"192.168.1.5","public_ips":["1.2.3.4"],"ipv6":null}]
 * nat_type  : 对端 NAT 类型（Symmetric / Cone）；无对端 NAT 信息时为空字符串
 * local_ipv4: 对端本地 ipv4，未获取到为 null（本网内地址会被服务端过滤）
 * public_ips: 对端公网出口 IP 列表，未获取到为 []
 * ipv6      : 对端 ipv6，未获取到为 null
 * 注意：NAT 字段仅在设备在线且已测得 NAT 信息时有效 */
char *vnt_device_detail_json(VntHandle *handle);

/* 路由表 JSON：
 * [{"destination":"10.26.0.3","next_hop":"127.0.0.1:3000","metric":1,"rtt":12,
 *   "protocol":"udp","interface":"127.0.0.1:3000"}]
 * destination: 目标虚拟 IP
 * next_hop   : 该路由的下一跳物理端点；2.0 的路由表不保存下一跳虚拟 IP
 * metric     : 跳数，1 表示直连
 * rtt        : 往返时延（毫秒），未测得为 -1
 * protocol   : 传输协议（udp/tcp/ws/wss）
 * interface  : 路由键字符串（物理端点描述） */
char *vnt_route_table_json(VntHandle *handle);

/* 已发送字节数（汇总所有对端） */
unsigned long long vnt_up_stream(VntHandle *handle);

/* 已接收字节数（汇总所有对端） */
unsigned long long vnt_down_stream(VntHandle *handle);

/* 收集需要保护的 UDP socket fd（避免 VPN 流量回环），返回写入数量，-1 表示参数错误。
 * out 需由调用方提供，建议容量 64 */
int vnt_collect_udp_fds(VntHandle *handle, int *out, int capacity);

/* 上一次错误信息（不清空） */
char *vnt_last_error(void);

/* 释放本库返回的字符串 */
void vnt_string_free(char *s);

/* ==========================================================================
 * vnt_start_json 的配置字段（全部为可选，除标注“必填”者外）
 *
 * 示例：
 * {
 *   "network_code": "your_token",              // 必填，旧名 token
 *   "server": ["tcp://101.35.230.139:6660"],   // 必填，也可写 "a,b"
 *   "device_id": "device-001",                 // 缺省取系统机器码
 *   "device_name": "my-phone",                 // 旧名 name，缺省取主机名
 *   "password": "group-password",
 *   "cert_mode": "finger:0011..ff",            // skip(默认) / standard / finger:<64位hex>
 *   "peer_address": ["udp://1.2.3.4:29872"],   // 主动探测的固定对端
 *   "turn": ["10.26.0.0/16,10.26.0.2"],        // 目标网段,中转节点虚拟IP
 *   "punch_model": ["10.26.0.0/16,IPv4Tcp,IPv4Udp"],  // 空表示不限
 *   "device_mode": "tun",                      // no / tun / tap，缺省按 tun_fd 推导
 *   "tun_name": "vnt-tun",
 *   "ip": "10.26.0.5",                         // 旧名 virtual_ip，缺省由服务端分配
 *   "mtu": 1400,                               // 缺省或 0 → 1400
 *   "outbound_interface": "wlan0",             // 旧名 local_dev
 *   "input": ["192.168.0.0/24,10.26.0.3"],     // 旧名 in_ips
 *   "output": ["0.0.0.0/0"],                   // 旧名 out_ips，空则取 0.0.0.0/0
 *   "subnet_mapping": ["192.168.2.2/32,192.168.1.3/32"],
 *   "auto_sync_subnet": false,
 *   "no_punch": false,                         // true = 仅走中继
 *   "no_broadcast": false,
 *   "no_nat": false,
 *   "allow_ikev2": false,
 *   "allow_wireguard": false,                  // 旧名 allow_wire_guard
 *   "compress": true,                          // 默认 true（lz4）
 *   "rtx": false,
 *   "fec": false,
 *   "udp_stun": ["stun.miwifi.com"],           // 旧名 stun_servers，空则用内置列表
 *   "tcp_stun": ["stun.example.com"],
 *   "tunnel_port": 35535,
 *   "port_mapping": ["tcp://0.0.0.0:8080-10.26.0.10-192.168.1.5:80"],
 *   "allow_mapping": false,                    // 旧名 allow_port_mapping
 *   "event_script": "/data/vnt-on-change.sh"
 * }
 *
 * 说明：
 * 1. 列表字段既可写成 JSON 数组，也可写成字符串：
 *    - 条目内部不含逗号的字段（server / peer_address / output / port_mapping /
 *      udp_stun / tcp_stun）字符串按 `,` `;` 空格 换行 切分；
 *    - 条目内部自带逗号的字段（turn / punch_model / input / subnet_mapping）
 *      字符串只按 `;` 或换行切分，例如
 *      "input": "192.168.0.0/24,10.26.0.3;172.16.0.0/16,10.26.0.4"
 * 2. input 另兼容 1.0 的整串逗号写法（段数为偶数时两两配对）。
 * 3. STUN 地址不带端口时自动补 :3478。
 * 4. 字段名拼错或出现未知字段会导致 vnt_start_json 返回 NULL。
 * 5. 1.0 的 use_channel / compressor / ports / cipher_model / server_encrypt /
 *    finger / first_latency / enable_traffic 不再接受，请改用上表中的
 *    no_punch / compress / tunnel_port 等字段。
 * 6. OHOS 上虚拟网卡的地址与路由由调用方（VpnExtensionAbility）配置，
 *    本库不做改网卡地址的操作；实际可用的是 device_mode = "tun"（传入 App
 *    自己创建的 fd）与 "no"（无网卡），"tap" 未在该平台验证。
 * ========================================================================== */

#ifdef __cplusplus
}
#endif

#endif /* VNT_FFI_H */
