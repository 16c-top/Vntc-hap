/*
 * vnt_ffi —— vnt 动态库 C 接口
 *
 * 使用方式：调用方（App / VpnExtensionAbility）负责创建虚拟网卡，
 * 把 tun 的文件描述符通过 VntConfig.tun_fd 传入，本库负责收发 IP 报文。
 *
 * 所有由本库返回的 char*（除 vnt_version 外）均需使用 vnt_string_free 释放。
 */
#ifndef VNT_FFI_H
#define VNT_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------- 常量 ---------------- */

/* 事件类型（vnt_set_event_callback 的 event 参数） */
#define VNT_EVENT_SUCCESS  0 /* 连接成功 */
#define VNT_EVENT_REGISTER 1 /* 注册成功 */
#define VNT_EVENT_TUN_INFO 2 /* 虚拟网卡信息就绪：{"virtual_ip":..,"netmask":..,"gateway":..,"mtu":..} */
#define VNT_EVENT_PEERS    3 /* 设备列表变化：[{"ip":..,"name":..,"online":true}] */
#define VNT_EVENT_ERROR    4 /* 错误：{"code":..,"msg":..} */
#define VNT_EVENT_STOP     5 /* 已停止 */

/* 日志级别（vnt_set_log_callback 的 level 参数） */
#define VNT_LOG_ERROR 1
#define VNT_LOG_WARN  2
#define VNT_LOG_INFO  3
#define VNT_LOG_DEBUG 4
#define VNT_LOG_TRACE 5

/* 加密算法（VntConfig.cipher_model） */
#define VNT_CIPHER_AES_GCM   0
#define VNT_CIPHER_CHACHA20_POLY1305 1
#define VNT_CIPHER_CHACHA20  2
#define VNT_CIPHER_AES_CBC   3
#define VNT_CIPHER_AES_ECB   4
#define VNT_CIPHER_XOR       5
#define VNT_CIPHER_NONE      6

/* 打洞模型（VntConfig.punch_model） */
#define VNT_PUNCH_ALL      0
#define VNT_PUNCH_IPV4     1
#define VNT_PUNCH_IPV6     2
#define VNT_PUNCH_IPV4_TCP 3
#define VNT_PUNCH_IPV4_UDP 4
#define VNT_PUNCH_IPV6_TCP 5
#define VNT_PUNCH_IPV6_UDP 6

/* 通道类型（VntConfig.use_channel） */
#define VNT_CHANNEL_RELAY 0 /* 仅服务端转发 */
#define VNT_CHANNEL_P2P   1 /* 仅点对点 */
#define VNT_CHANNEL_ALL   2 /* 自动（推荐） */

/* 压缩算法（VntConfig.compressor）
 * 0 = 不压缩；1 = lz4；2 = zstd（固定压缩等级 9） */
#define VNT_COMPRESS_NONE 0
#define VNT_COMPRESS_LZ4  1
#define VNT_COMPRESS_ZSTD 2

/* ---------------- 回调 ---------------- */

/* json 仅在回调期间有效，如需保存请自行拷贝 */
typedef void (*vnt_event_cb)(void *ctx, int event, const char *json);
typedef void (*vnt_log_cb)(void *ctx, int level, const char *msg);

/* ---------------- 结构体 ---------------- */

typedef struct VntHandle VntHandle;

typedef struct {
    /* 必填：组网令牌（与服务端一致） */
    const char *token;
    /* 必填：本设备唯一标识，同一网络内不可重复 */
    const char *device_id;
    /* 必填：设备名称（展示用） */
    const char *name;
    /* 必填：服务端地址，支持 udp://host:port、tcp://host:port、
     * ws://host:port、wss://host:port、host:port（等价于 udp://） */
    const char *server;
    /* 可选：组网密码（与服务端一致），无密码填 NULL */
    const char *password;

    /* 可选：DNS，逗号分隔，默认 223.5.5.5,114.114.114.114 */
    const char *name_servers;
    /* 可选：STUN 服务器，逗号分隔，默认 stun.miwifi.com 等 */
    const char *stun_servers;
    /* 可选：指定物理网卡名（多网卡时） */
    const char *local_dev;
    /* 可选：指定本地端口，逗号分隔，如 35535,35536 */
    const char *ports;

    /* 可选：入站路由（本端网段 -> 对端），单条格式 x.x.x.x/mask,gateway，
     * 多条之间用 `;` 或换行分隔，也兼容直接用逗号连续书写，
     * 例如 192.168.0.0/24,10.26.0.3
     *      192.168.0.0/24,10.26.0.3;172.16.0.0/16,10.26.0.4 */
    const char *in_ips;
    /* 可选：出站路由，逗号分隔，格式 x.x.x.x/mask，默认 0.0.0.0/0 */
    const char *out_ips;
    /* 可选：期望的本机虚拟 IP，不指定则由服务端分配 */
    const char *virtual_ip;

    /* 必填：虚拟网卡文件描述符（VpnConnection.create 返回值） */
    int tun_fd;
    /* 可选：MTU，0 表示使用默认 1400，需与 VPN 配置一致 */
    unsigned int mtu;

    int cipher_model;     /* 见 VNT_CIPHER_*，默认 AES-GCM */
    int punch_model;      /* 见 VNT_PUNCH_*，默认 ALL */
    int use_channel;      /* 见 VNT_CHANNEL_*，默认 ALL */
    int compressor;       /* 见 VNT_COMPRESS_*，默认 LZ4 */
    int server_encrypt;   /* 非 0 表示启用服务端加密 */
    int finger;           /* 非 0 表示启用数据包指纹校验 */
    int first_latency;    /* 非 0 表示优先低延迟通道 */
    int enable_traffic;   /* 非 0 表示统计流量 */
    int allow_wire_guard; /* 非 0 表示允许转发 wireguard 流量 */
} VntConfig;

/* ---------------- 接口 ---------------- */

/* 库版本号（静态字符串，无需释放） */
const char *vnt_version(void);

/* 初始化日志器，进程内首次调用即可 */
void vnt_init(void);

/* 设置事件回调（cb 传 NULL 取消） */
void vnt_set_event_callback(vnt_event_cb cb, void *ctx);

/* 设置日志回调（cb 传 NULL 取消） */
void vnt_set_log_callback(vnt_log_cb cb, void *ctx);

/* 启动 vnt；成功返回句柄，失败返回 NULL，错误见 vnt_last_error */
VntHandle *vnt_start(const VntConfig *cfg);

/* 启动 vnt，并附加端口映射规则（VntConfig 布局保持不变）
 * mapping: 多条规则用逗号/分号/空格分隔，单条格式与 CLI --mapping 一致：
 *     tcp:127.0.0.1:80-10.26.0.10:8080
 *     udp:0.0.0.0:53-10.26.0.5:53
 *   格式为 协议:本机监听地址-目标地址:端口；
 *   语义：在本机监听地址上监听，连接转发到目标地址
 *         （目标可以是 VNT 网络内的虚拟 IP，也可以是本机路由可达的设备）
 * mapping 传 NULL 或空串时等价于 vnt_start；失败返回 NULL，错误见 vnt_last_error */
VntHandle *vnt_start_with_port_mapping(const VntConfig *cfg, const char *mapping);

/* 停止并回收读线程；返回 0 成功，-1 句柄无效 */
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
 * relay      : 当前是否有流量走服务端或客户端中继
 * p2p_peers  : 点对点通道的对端数
 * relay_peers: 中继通道的对端数
 * delay      : 已测得通道的平均往返时延（毫秒），未测得为 -1 */
char *vnt_status_json(VntHandle *handle);

/* 设备列表 JSON：[{"ip":..,"name":..,"online":true,"wireguard":false,"channel":"p2p","delay":12}]
 * channel : p2p / tcp-p2p / server-relay / client-relay
 * delay   : 该对端的往返时延（毫秒），未测得为 -1 */
char *vnt_device_list_json(VntHandle *handle);

/* 设备详情 JSON：在设备列表基础上附带每个对端的 NAT 信息
 * [{"ip":..,"name":..,"online":true,"wireguard":false,"channel":"p2p","delay":12,
 *   "nat_type":"Cone","local_ipv4":"192.168.1.5","public_ips":["1.2.3.4"],"ipv6":null}]
 * 字段除以下三项外均与 vnt_device_list_json 相同：
 * nat_type  : 对端 NAT 类型（Symmetric / Cone）；无对端 NAT 信息时为空字符串
 * local_ipv4: 对端本地 ipv4，未获取到为 null
 * public_ips: 对端公网出口 IP 列表，未获取到为 []
 * ipv6      : 对端 ipv6，未获取到为 null
 * 注意：NAT 字段仅在设备在线且已测得 NAT 信息时有效 */
char *vnt_device_detail_json(VntHandle *handle);

/* 路由表 JSON（对应 CLI 的 route）：
 * [{"destination":"10.26.0.3","next_hop":"10.26.0.1","metric":1,"rtt":12,
 *   "protocol":"UDP","interface":"192.168.1.5:35535"}]
 * destination: 目标虚拟 IP
 * next_hop   : 下一跳虚拟 IP，解析不到为空串
 * metric     : 跳数，1 表示直连
 * rtt        : 往返时延（毫秒），未测得为 -1
 * protocol   : 传输协议（UDP/TCP/WS/WSS）
 * interface  : 承载通道，UDP 为本地地址、TCP 为 tcp@地址、WS/WSS 为服务端地址 */
char *vnt_route_table_json(VntHandle *handle);

/* 已发送字节数 */
unsigned long long vnt_up_stream(VntHandle *handle);

/* 已接收字节数 */
unsigned long long vnt_down_stream(VntHandle *handle);

/* 收集需要保护的 UDP socket fd（避免 VPN 流量回环），返回写入数量，-1 表示参数错误。
 * out 需由调用方提供，建议容量 64 */
int vnt_collect_udp_fds(VntHandle *handle, int *out, int capacity);

/* 上一次错误信息（不清空） */
char *vnt_last_error(void);

/* 释放本库返回的字符串 */
void vnt_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* VNT_FFI_H */
