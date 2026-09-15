#include "napi/native_api.h"
#include <hilog/log.h>
#include <dlfcn.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include "vnt_ffi.h"

namespace {
constexpr unsigned int VNT_LOG_DOMAIN = 0x0056;
constexpr const char *VNT_LOG_TAG = "vnt_ffi";
constexpr const char *VNT_LIB_DIR = "/data/storage/el1/bundle/libs/arm64";

struct VntApi {
    const char *(*vnt_version)(void);
    void (*vnt_init)(void);
    void (*vnt_set_event_callback)(vnt_event_cb cb, void *ctx);
    void (*vnt_set_log_callback)(vnt_log_cb cb, void *ctx);
    VntHandle *(*vnt_start)(const VntConfig *cfg);
    VntHandle *(*vnt_start_with_port_mapping)(const VntConfig *cfg, const char *mapping);
    VntHandle *(*vnt_start_json)(const char *json, int tun_fd);
    int (*vnt_stop)(VntHandle *handle);
    void (*vnt_free)(VntHandle *handle);
    int (*vnt_is_running)(VntHandle *handle);
    char *(*vnt_status_json)(VntHandle *handle);
    char *(*vnt_device_list_json)(VntHandle *handle);
    char *(*vnt_device_detail_json)(VntHandle *handle);
    char *(*vnt_route_table_json)(VntHandle *handle);
    unsigned long long (*vnt_up_stream)(VntHandle *handle);
    unsigned long long (*vnt_down_stream)(VntHandle *handle);
    int (*vnt_collect_udp_fds)(VntHandle *handle, int *out, int capacity);
    char *(*vnt_last_error)(void);
    void (*vnt_string_free)(char *s);
};

VntApi g_api = {};
void *g_coreLib = nullptr;
std::string g_coreVersion;
std::string g_loadError("内核尚未加载");

VntHandle *g_handle = nullptr;
napi_threadsafe_function g_event_tsfn = nullptr;
int g_dummyTunFd = -1;
int g_dummyPeerFd = -1;

struct EventPayload {
  int event;
  std::string json;
};

static void CloseDummyTun()
{
    if (g_dummyTunFd >= 0) {
        close(g_dummyTunFd);
        g_dummyTunFd = -1;
    }
    if (g_dummyPeerFd >= 0) {
        close(g_dummyPeerFd);
        g_dummyPeerFd = -1;
    }
}

std::string NapiGetString(napi_env env, napi_value value)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return std::string();
    }
    std::string str(len, '\0');
    size_t copied = 0;
    napi_get_value_string_utf8(env, value, &str[0], len + 1, &copied);
    str.resize(copied);
    return str;
}

const char *OrNull(const std::string &str)
{
    return str.empty() ? nullptr : str.c_str();
}

void EventCallJs(napi_env env, napi_value jsCallback, void *context, void *data)
{
    (void)context;
    EventPayload *payload = static_cast<EventPayload *>(data);
    if (env != nullptr && jsCallback != nullptr && payload != nullptr) {
        napi_value undefined = nullptr;
        napi_get_undefined(env, &undefined);
        napi_value argv[2] = {nullptr, nullptr};
        napi_create_int32(env, payload->event, &argv[0]);
        napi_create_string_utf8(env, payload->json.c_str(), NAPI_AUTO_LENGTH, &argv[1]);
        napi_call_function(env, undefined, jsCallback, 2, argv, nullptr);
    }
    delete payload;
}

void NativeEventCb(void *ctx, int event, const char *json)
{
    (void)ctx;
    if (g_event_tsfn == nullptr) {
        return;
    }
    EventPayload *payload = new EventPayload();
    payload->event = event;
    payload->json = (json != nullptr) ? json : "";
    napi_call_threadsafe_function(g_event_tsfn, payload, napi_tsfn_blocking);
}

void NativeLogCb(void *ctx, int level, const char *msg)
{
    (void)ctx;
    LogLevel logLevel = LOG_DEBUG;
    switch (level) {
        case VNT_LOG_ERROR:
            logLevel = LOG_ERROR;
            break;
        case VNT_LOG_WARN:
            logLevel = LOG_WARN;
            break;
        case VNT_LOG_INFO:
            logLevel = LOG_INFO;
            break;
        default:
            logLevel = LOG_DEBUG;
            break;
    }
    OH_LOG_Print(LOG_APP, logLevel, VNT_LOG_DOMAIN, VNT_LOG_TAG, "%{public}s", (msg != nullptr) ? msg : "");
}

bool ResolveSymbols(void *lib)
{
    g_api = {};
    g_api.vnt_version = reinterpret_cast<const char *(*)(void)>(dlsym(lib, "vnt_version"));
    g_api.vnt_init = reinterpret_cast<void (*)(void)>(dlsym(lib, "vnt_init"));
    g_api.vnt_set_event_callback =
        reinterpret_cast<void (*)(vnt_event_cb, void *)>(dlsym(lib, "vnt_set_event_callback"));
    g_api.vnt_set_log_callback =
        reinterpret_cast<void (*)(vnt_log_cb, void *)>(dlsym(lib, "vnt_set_log_callback"));
    g_api.vnt_start = reinterpret_cast<VntHandle *(*)(const VntConfig *)>(dlsym(lib, "vnt_start"));
    g_api.vnt_start_with_port_mapping =
        reinterpret_cast<VntHandle *(*)(const VntConfig *, const char *)>(dlsym(lib, "vnt_start_with_port_mapping"));
    g_api.vnt_start_json = reinterpret_cast<VntHandle *(*)(const char *, int)>(dlsym(lib, "vnt_start_json"));
    g_api.vnt_stop = reinterpret_cast<int (*)(VntHandle *)>(dlsym(lib, "vnt_stop"));
    g_api.vnt_free = reinterpret_cast<void (*)(VntHandle *)>(dlsym(lib, "vnt_free"));
    g_api.vnt_is_running = reinterpret_cast<int (*)(VntHandle *)>(dlsym(lib, "vnt_is_running"));
    g_api.vnt_status_json = reinterpret_cast<char *(*)(VntHandle *)>(dlsym(lib, "vnt_status_json"));
    g_api.vnt_device_list_json = reinterpret_cast<char *(*)(VntHandle *)>(dlsym(lib, "vnt_device_list_json"));
    g_api.vnt_device_detail_json = reinterpret_cast<char *(*)(VntHandle *)>(dlsym(lib, "vnt_device_detail_json"));
    g_api.vnt_route_table_json = reinterpret_cast<char *(*)(VntHandle *)>(dlsym(lib, "vnt_route_table_json"));
    g_api.vnt_up_stream =
        reinterpret_cast<unsigned long long (*)(VntHandle *)>(dlsym(lib, "vnt_up_stream"));
    g_api.vnt_down_stream =
        reinterpret_cast<unsigned long long (*)(VntHandle *)>(dlsym(lib, "vnt_down_stream"));
    g_api.vnt_collect_udp_fds =
        reinterpret_cast<int (*)(VntHandle *, int *, int)>(dlsym(lib, "vnt_collect_udp_fds"));
    g_api.vnt_last_error = reinterpret_cast<char *(*)(void)>(dlsym(lib, "vnt_last_error"));
    g_api.vnt_string_free = reinterpret_cast<void (*)(char *)>(dlsym(lib, "vnt_string_free"));
    return g_api.vnt_version != nullptr && g_api.vnt_stop != nullptr &&
        (g_api.vnt_start != nullptr || g_api.vnt_start_json != nullptr) &&
        g_api.vnt_free != nullptr && g_api.vnt_string_free != nullptr && g_api.vnt_last_error != nullptr;
}

bool LoadCore(const std::string &version)
{
    if (version != "v1" && version != "v2") {
        g_loadError = "不支持的内核版本：" + version;
        return false;
    }
    if (g_coreLib != nullptr && g_coreVersion == version) {
        return true;
    }
    if (g_handle != nullptr) {
        g_loadError = "连接运行中，请先停止再切换内核";
        return false;
    }
    const std::string fileName = "libvnt_ffi_" + version + ".so";
    void *lib = dlopen(fileName.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (lib == nullptr) {
        const std::string fullPath = std::string(VNT_LIB_DIR) + "/" + fileName;
        lib = dlopen(fullPath.c_str(), RTLD_NOW | RTLD_LOCAL);
    }
    if (lib == nullptr) {
        const char *err = dlerror();
        g_loadError = (err != nullptr) ? std::string("加载内核失败：") + err : "加载内核失败：" + fileName;
        return false;
    }
    if (!ResolveSymbols(lib)) {
        g_loadError = "内核符号解析失败：" + fileName;
        g_api = {};
        return false;
    }
    g_coreLib = lib;
    g_coreVersion = version;
    g_loadError.clear();
    g_api.vnt_init();
    g_api.vnt_set_log_callback(NativeLogCb, nullptr);
    if (g_event_tsfn != nullptr) {
        g_api.vnt_set_event_callback(NativeEventCb, nullptr);
    }
    return true;
}

napi_value SetCoreVersion(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string version;
    if (argc > 0 && argv[0] != nullptr) {
        version = NapiGetString(env, argv[0]);
    }
    bool ok = LoadCore(version);
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value Version(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    const char *version = (g_coreLib != nullptr && g_api.vnt_version != nullptr) ? g_api.vnt_version() : "";
    napi_create_string_utf8(env, (version != nullptr) ? version : "", NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value CoreVersion(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    napi_create_string_utf8(env, g_coreVersion.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

struct StartWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool ok = false;

    std::string token;
    std::string deviceId;
    std::string name;
    std::string server;
    std::string password;
    std::string virtualIp;
    std::string nameServers;
    std::string stunServers;
    std::string ports;
    std::string inIps;
    std::string outIps;
    std::string mapping;
    int tunFd = -1;
    int mtu = 0;
    int useChannel = 2;
    int cipherModel = 0;
    int compressor = 1;
    int serverEncrypt = 1;
    int finger = 1;
    int enableTraffic = 1;
};

void StartExecute(napi_env env, void *data)
{
    (void)env;
    StartWork *work = static_cast<StartWork *>(data);
    work->ok = false;
    if (g_coreLib == nullptr) {
        g_loadError = g_loadError.empty() ? "内核尚未加载" : g_loadError;
        return;
    }
    if (g_api.vnt_start == nullptr) {
        g_loadError = "当前内核不支持结构体入口，请使用 startJson";
        return;
    }
    if (g_handle != nullptr) {
        g_api.vnt_free(g_handle);
        g_handle = nullptr;
    }
    CloseDummyTun();
    int tunFd = work->tunFd;
    if (tunFd < 0) {
        int sv[2] = {-1, -1};
        if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0) {
            g_dummyTunFd = sv[0];
            g_dummyPeerFd = sv[1];
            tunFd = sv[0];
        }
    }

    VntConfig cfg = {};
    cfg.token = OrNull(work->token);
    cfg.device_id = OrNull(work->deviceId);
    cfg.name = OrNull(work->name);
    cfg.server = OrNull(work->server);
    cfg.password = OrNull(work->password);
    cfg.virtual_ip = OrNull(work->virtualIp);
    cfg.name_servers = OrNull(work->nameServers);
    cfg.stun_servers = OrNull(work->stunServers);
    cfg.ports = OrNull(work->ports);
    cfg.in_ips = OrNull(work->inIps);
    cfg.out_ips = OrNull(work->outIps);
    cfg.tun_fd = tunFd;
    cfg.mtu = (work->mtu > 0) ? static_cast<unsigned int>(work->mtu) : 0;
    cfg.use_channel = (work->useChannel >= 0 && work->useChannel <= 2) ? work->useChannel : VNT_CHANNEL_ALL;
    cfg.cipher_model = (work->cipherModel >= 0 && work->cipherModel <= 6) ? work->cipherModel : VNT_CIPHER_AES_GCM;
    cfg.compressor = (work->compressor >= 0 && work->compressor <= 2) ? work->compressor : VNT_COMPRESS_LZ4;
    cfg.punch_model = VNT_PUNCH_ALL;
    cfg.server_encrypt = (work->serverEncrypt != 0) ? 1 : 0;
    cfg.finger = (work->finger != 0) ? 1 : 0;
    cfg.enable_traffic = (work->enableTraffic != 0) ? 1 : 0;

    if (!work->mapping.empty()) {
        g_handle = g_api.vnt_start_with_port_mapping(&cfg, work->mapping.c_str());
    } else {
        g_handle = g_api.vnt_start(&cfg);
    }
    work->ok = (g_handle != nullptr);
}

void StartComplete(napi_env env, napi_status status, void *data)
{
    (void)status;
    StartWork *work = static_cast<StartWork *>(data);
    napi_value result = nullptr;
    napi_get_boolean(env, work->ok, &result);
    napi_resolve_deferred(env, work->deferred, result);
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 20;
    napi_value argv[20] = {};
    for (int i = 0; i < 20; i++) {
        argv[i] = nullptr;
    }
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);

    if (argc < 20) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        napi_resolve_deferred(env, deferred, result);
        return promise;
    }

    StartWork *work = new StartWork();
    work->deferred = deferred;
    napi_get_value_int32(env, argv[0], &work->tunFd);
    napi_get_value_int32(env, argv[7], &work->mtu);
    napi_get_value_int32(env, argv[8], &work->useChannel);
    napi_get_value_int32(env, argv[12], &work->cipherModel);
    napi_get_value_int32(env, argv[13], &work->compressor);
    napi_get_value_int32(env, argv[14], &work->serverEncrypt);
    napi_get_value_int32(env, argv[15], &work->finger);
    napi_get_value_int32(env, argv[16], &work->enableTraffic);
    work->token = NapiGetString(env, argv[1]);
    work->deviceId = NapiGetString(env, argv[2]);
    work->name = NapiGetString(env, argv[3]);
    work->server = NapiGetString(env, argv[4]);
    work->password = NapiGetString(env, argv[5]);
    work->virtualIp = NapiGetString(env, argv[6]);
    work->stunServers = NapiGetString(env, argv[9]);
    work->nameServers = NapiGetString(env, argv[10]);
    work->ports = NapiGetString(env, argv[11]);
    work->inIps = NapiGetString(env, argv[17]);
    work->outIps = NapiGetString(env, argv[18]);
    work->mapping = NapiGetString(env, argv[19]);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "vntStart", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, StartExecute, StartComplete, work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}

struct StartJsonWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool ok = false;
    std::string json;
    int tunFd = -1;
};

void StartJsonExecute(napi_env env, void *data)
{
    (void)env;
    StartJsonWork *work = static_cast<StartJsonWork *>(data);
    work->ok = false;
    if (g_coreLib == nullptr || g_api.vnt_start_json == nullptr) {
        g_loadError = (g_coreLib == nullptr) ? "内核尚未加载" : "当前内核不支持 JSON 入口";
        return;
    }
    if (g_handle != nullptr) {
        g_api.vnt_free(g_handle);
        g_handle = nullptr;
    }
    CloseDummyTun();
    int tunFd = work->tunFd;
    if (tunFd < 0) {
        int sv[2] = {-1, -1};
        if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0) {
            g_dummyTunFd = sv[0];
            g_dummyPeerFd = sv[1];
            tunFd = sv[0];
        }
    }
    g_handle = g_api.vnt_start_json(work->json.c_str(), tunFd);
    work->ok = (g_handle != nullptr);
}

void StartJsonComplete(napi_env env, napi_status status, void *data)
{
    (void)status;
    StartJsonWork *work = static_cast<StartJsonWork *>(data);
    napi_value result = nullptr;
    napi_get_boolean(env, work->ok, &result);
    napi_resolve_deferred(env, work->deferred, result);
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value StartJson(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);

    napi_valuetype fdType = napi_undefined;
    napi_valuetype jsonType = napi_undefined;
    if (argv[0] != nullptr) {
        napi_typeof(env, argv[0], &fdType);
    }
    if (argv[1] != nullptr) {
        napi_typeof(env, argv[1], &jsonType);
    }
    if (fdType != napi_number || jsonType != napi_string) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        napi_resolve_deferred(env, deferred, result);
        return promise;
    }

    StartJsonWork *work = new StartJsonWork();
    work->deferred = deferred;
    napi_get_value_int32(env, argv[0], &work->tunFd);
    work->json = NapiGetString(env, argv[1]);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "vntStartJson", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, StartJsonExecute, StartJsonComplete, work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}

napi_value Stop(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_handle != nullptr && g_api.vnt_free != nullptr) {
        g_api.vnt_free(g_handle);
        g_handle = nullptr;
    }
    CloseDummyTun();
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

napi_value IsRunning(napi_env env, napi_callback_info info)
{
    (void)info;
    bool running = (g_handle != nullptr) && (g_api.vnt_is_running != nullptr) && (g_api.vnt_is_running(g_handle) == 1);
    napi_value result = nullptr;
    napi_get_boolean(env, running, &result);
    return result;
}

napi_value Status(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string json = "{}";
    if (g_handle != nullptr && g_api.vnt_status_json != nullptr) {
        char *raw = g_api.vnt_status_json(g_handle);
        if (raw != nullptr) {
            json = raw;
            g_api.vnt_string_free(raw);
        }
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value DeviceList(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string json = "[]";
    if (g_handle != nullptr && g_api.vnt_device_list_json != nullptr) {
        char *raw = g_api.vnt_device_list_json(g_handle);
        if (raw != nullptr) {
            json = raw;
            g_api.vnt_string_free(raw);
        }
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value DeviceDetail(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string json = "[]";
    if (g_handle != nullptr && g_api.vnt_device_detail_json != nullptr) {
        char *raw = g_api.vnt_device_detail_json(g_handle);
        if (raw != nullptr) {
            json = raw;
            g_api.vnt_string_free(raw);
        }
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value RouteTable(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string json = "[]";
    if (g_handle != nullptr && g_api.vnt_route_table_json != nullptr) {
        char *raw = g_api.vnt_route_table_json(g_handle);
        if (raw != nullptr) {
            json = raw;
            g_api.vnt_string_free(raw);
        }
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value LastError(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string message;
    if (g_coreLib == nullptr || g_api.vnt_last_error == nullptr) {
        message = g_loadError;
    } else {
        char *raw = g_api.vnt_last_error();
        if (raw != nullptr) {
            message = raw;
            g_api.vnt_string_free(raw);
        }
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value UpStream(napi_env env, napi_callback_info info)
{
    (void)info;
    unsigned long long bytes = (g_handle != nullptr && g_api.vnt_up_stream != nullptr) ? g_api.vnt_up_stream(g_handle) : 0;
    napi_value result = nullptr;
    napi_create_int64(env, static_cast<int64_t>(bytes), &result);
    return result;
}

napi_value DownStream(napi_env env, napi_callback_info info)
{
    (void)info;
    unsigned long long bytes =
        (g_handle != nullptr && g_api.vnt_down_stream != nullptr) ? g_api.vnt_down_stream(g_handle) : 0;
    napi_value result = nullptr;
    napi_create_int64(env, static_cast<int64_t>(bytes), &result);
    return result;
}

napi_value SetEventListener(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (g_event_tsfn != nullptr) {
        if (g_api.vnt_set_event_callback != nullptr) {
            g_api.vnt_set_event_callback(nullptr, nullptr);
        }
        napi_release_threadsafe_function(g_event_tsfn, napi_tsfn_release);
        g_event_tsfn = nullptr;
    }

    napi_valuetype type = napi_undefined;
    if (argc > 0 && argv[0] != nullptr) {
        napi_typeof(env, argv[0], &type);
    }
    if (type == napi_function) {
        napi_value resourceName = nullptr;
        napi_create_string_utf8(env, "vntEvent", NAPI_AUTO_LENGTH, &resourceName);
        napi_create_threadsafe_function(env, argv[0], nullptr, resourceName, 0, 1,
            nullptr, nullptr, nullptr, EventCallJs, &g_event_tsfn);
        if (g_api.vnt_set_event_callback != nullptr) {
            g_api.vnt_set_event_callback(NativeEventCb, nullptr);
        }
    }

    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"setCoreVersion", nullptr, SetCoreVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreVersion", nullptr, CoreVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startJson", nullptr, StartJson, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deviceList", nullptr, DeviceList, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deviceDetail", nullptr, DeviceDetail, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"routeTable", nullptr, RouteTable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, LastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"upStream", nullptr, UpStream, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"downStream", nullptr, DownStream, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEventListener", nullptr, SetEventListener, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_vntNapiModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "vnt_napi",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterVntNapiModule(void)
{
    napi_module_register(&g_vntNapiModule);
}
