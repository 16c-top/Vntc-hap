#include "napi/native_api.h"
#include <hilog/log.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include "vnt_ffi.h"

namespace {
constexpr unsigned int VNT_LOG_DOMAIN = 0x0056;
constexpr const char *VNT_LOG_TAG = "vnt_ffi";

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

napi_value Version(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    const char *version = vnt_version();
    napi_create_string_utf8(env, (version != nullptr) ? version : "", NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 17;
    napi_value argv[17] = {};
    for (int i = 0; i < 17; i++) {
        argv[i] = nullptr;
    }
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    napi_value result = nullptr;
    napi_get_boolean(env, false, &result);
    if (argc < 17) {
        return result;
    }

    int32_t tunFd = -1;
    int32_t mtu = 0;
    int32_t useChannel = 2;
    int32_t cipherModel = 0;
    int32_t compressor = 1;
    int32_t serverEncrypt = 1;
    int32_t finger = 1;
    int32_t enableTraffic = 1;
    napi_get_value_int32(env, argv[0], &tunFd);
    napi_get_value_int32(env, argv[7], &mtu);
    napi_get_value_int32(env, argv[8], &useChannel);
    napi_get_value_int32(env, argv[12], &cipherModel);
    napi_get_value_int32(env, argv[13], &compressor);
    napi_get_value_int32(env, argv[14], &serverEncrypt);
    napi_get_value_int32(env, argv[15], &finger);
    napi_get_value_int32(env, argv[16], &enableTraffic);
    std::string token = NapiGetString(env, argv[1]);
    std::string deviceId = NapiGetString(env, argv[2]);
    std::string name = NapiGetString(env, argv[3]);
    std::string server = NapiGetString(env, argv[4]);
    std::string password = NapiGetString(env, argv[5]);
    std::string virtualIp = NapiGetString(env, argv[6]);
    std::string stunServers = NapiGetString(env, argv[9]);
    std::string nameServers = NapiGetString(env, argv[10]);
    std::string ports = NapiGetString(env, argv[11]);

    if (g_handle != nullptr) {
        vnt_free(g_handle);
        g_handle = nullptr;
    }
    CloseDummyTun();
    if (tunFd < 0) {
        int sv[2] = {-1, -1};
        if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0) {
            g_dummyTunFd = sv[0];
            g_dummyPeerFd = sv[1];
            tunFd = sv[0];
        }
    }
    vnt_init();
    vnt_set_log_callback(NativeLogCb, nullptr);

    VntConfig cfg = {};
    cfg.token = token.c_str();
    cfg.device_id = deviceId.c_str();
    cfg.name = name.c_str();
    cfg.server = server.c_str();
    cfg.password = OrNull(password);
    cfg.virtual_ip = OrNull(virtualIp);
    cfg.name_servers = OrNull(nameServers);
    cfg.stun_servers = OrNull(stunServers);
    cfg.ports = OrNull(ports);
    cfg.tun_fd = tunFd;
    cfg.mtu = (mtu > 0) ? static_cast<unsigned int>(mtu) : 0;
    cfg.use_channel = (useChannel >= 0 && useChannel <= 2) ? useChannel : VNT_CHANNEL_ALL;
    cfg.cipher_model = (cipherModel >= 0 && cipherModel <= 6) ? cipherModel : VNT_CIPHER_AES_GCM;
    cfg.compressor = (compressor >= 0 && compressor <= 1) ? compressor : VNT_COMPRESS_LZ4;
    cfg.punch_model = VNT_PUNCH_ALL;
    cfg.server_encrypt = (serverEncrypt != 0) ? 1 : 0;
    cfg.finger = (finger != 0) ? 1 : 0;
    cfg.enable_traffic = (enableTraffic != 0) ? 1 : 0;

    g_handle = vnt_start(&cfg);
    napi_get_boolean(env, g_handle != nullptr, &result);
    return result;
}

napi_value Stop(napi_env env, napi_callback_info info)
{
    (void)info;
    if (g_handle != nullptr) {
        vnt_free(g_handle);
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
    bool running = (g_handle != nullptr) && (vnt_is_running(g_handle) == 1);
    napi_value result = nullptr;
    napi_get_boolean(env, running, &result);
    return result;
}

napi_value Status(napi_env env, napi_callback_info info)
{
    (void)info;
    std::string json = "{}";
    if (g_handle != nullptr) {
        char *raw = vnt_status_json(g_handle);
        if (raw != nullptr) {
            json = raw;
            vnt_string_free(raw);
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
    if (g_handle != nullptr) {
        char *raw = vnt_device_list_json(g_handle);
        if (raw != nullptr) {
            json = raw;
            vnt_string_free(raw);
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
    char *raw = vnt_last_error();
    if (raw != nullptr) {
        message = raw;
        vnt_string_free(raw);
    }
    napi_value result = nullptr;
    napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value UpStream(napi_env env, napi_callback_info info)
{
    (void)info;
    unsigned long long bytes = (g_handle != nullptr) ? vnt_up_stream(g_handle) : 0;
    napi_value result = nullptr;
    napi_create_int64(env, static_cast<int64_t>(bytes), &result);
    return result;
}

napi_value DownStream(napi_env env, napi_callback_info info)
{
    (void)info;
    unsigned long long bytes = (g_handle != nullptr) ? vnt_down_stream(g_handle) : 0;
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
        vnt_set_event_callback(nullptr, nullptr);
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
        vnt_set_event_callback(NativeEventCb, nullptr);
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
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deviceList", nullptr, DeviceList, nullptr, nullptr, nullptr, napi_default, nullptr},
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
