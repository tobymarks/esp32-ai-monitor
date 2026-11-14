#include "standalone_runtime.h"
#include "standalone_profile.h"
#include "standalone_http.h"
#include "standalone_record.h"
#include "standalone_transfer.h"
#include "standalone_policy.h"
#include "config_store.h"
#include "board.h"
#include "wifi_time.h"
#include <Arduino.h>
#include <LittleFS.h>
#include <esp_tls.h>
// Core 2's WiFiClientSecure header shadows IDF's identically named header.
// Use the IDF symbol, whose library embeds the SDK's full maintained CA bundle.
// Arduino's similarly named helper requires a user bundle and is NOT used.
extern "C" esp_err_t esp_crt_bundle_attach(void *conf);
#if !CONFIG_MBEDTLS_CERTIFICATE_BUNDLE
#error Standalone HTTPS requires the verified ESP-IDF certificate bundle
#endif
#include <esp_heap_caps.h>
#include <esp_system.h>
#include <mbedtls/sha256.h>
#include <lwip/dns.h>
#include <lwip/tcpip.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h>
#include <atomic>
#include <string>
#include <new>
#if !defined(__EXCEPTIONS)
#error Standalone runtime requires C++ allocation failure handling
#endif
#include <strings.h>

namespace {
constexpr uint32_t DEADLINE_MS = 12000;
std::atomic<uint32_t> generation{1};
struct Job {
    uint32_t generation;
    std::string profile;
};
struct Result {
    uint32_t generation;
    const char *error = nullptr;
    std::string scene;
};
QueueHandle_t jobs = nullptr, results = nullptr;
bool busy = false, storage = false, enabled = false, owner = false;
bool success = false, failed = false, boot_storage_failed = false, profile_unavailable = false;
uint32_t record_generation = 0, last_success = 0, next_poll = 0;
unsigned failures = 0;
int record_slot = -1;
std::string profile;
char profile_id[41] = "", plugin_version[33] = "", digest_hex[65] = "";
char saved_layout[12] = "", saved_theme[8] = "", saved_locale[4] = "";
uint32_t interval_seconds = 60;
const char *state = "disabled", *last_error = nullptr;
bool previous_config = true, previous_wifi = false, previous_clock = false;
PluginSceneSlot scene = {};
const char *paths[] = {"/standalone-a.rec", "/standalone-b.rec"};

void hash(const void *bytes, size_t length, unsigned char digest[32]) {
#if defined(MBEDTLS_VERSION_MAJOR) && MBEDTLS_VERSION_MAJOR >= 3
    mbedtls_sha256((const unsigned char *)bytes, length, digest, 0);
#else
    mbedtls_sha256_ret((const unsigned char *)bytes, length, digest, 0);
#endif
}
std::string hexadecimal(const unsigned char *data, size_t n) {
    static const char *digits = "0123456789abcdef";
    std::string s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) {
        s += digits[data[i] >> 4];
        s += digits[data[i] & 15];
    }
    return s;
}
std::string sha(const std::string &s) {
    unsigned char digest[32];
    hash(s.data(), s.size(), digest);
    return hexadecimal(digest, 32);
}
void clear_scene() {
    free(scene.json);
    scene.json = nullptr;
    scene.bytes = 0;
    scene.ready = false;
    ++scene.revision;
    success = false;
    failed = false;
}
bool parse_profile(const std::string &bytes, JsonDocument &doc, const char **error) {
    return standalone_parse(bytes.data(), bytes.size(), doc, error) &&
           standalone_validate(doc.as<JsonObjectConst>(), error);
}
void metadata(JsonObjectConst p) {
    strlcpy(profile_id, p["pluginId"] | "", sizeof(profile_id));
    strlcpy(plugin_version, p["pluginVersion"] | "", sizeof(plugin_version));
    strlcpy(saved_layout, p["layout"] | "", sizeof(saved_layout));
    strlcpy(saved_theme, p["theme"] | "", sizeof(saved_theme));
    strlcpy(saved_locale, p["locale"] | "", sizeof(saved_locale));
    interval_seconds = p["intervalSeconds"] | 60;
    strlcpy(digest_hex, sha(profile).c_str(), sizeof(digest_hex));
}
bool matches_config() {
    const char *layout = SCREEN_WIDTH == SCREEN_HEIGHT  ? "square"
                         : SCREEN_WIDTH > SCREEN_HEIGHT ? "landscape"
                                                        : "portrait";
    return !strcmp(layout, saved_layout) &&
           !strcmp(g_config.theme == THEME_LIGHT ? "light" : "dark", saved_theme) &&
           !strcmp(g_config.language == LANG_EN ? "en" : "de", saved_locale);
}

// Metadata is authenticated by the integrity digest as well as the body. A bit
// flip cannot silently enable a disabled profile. The second slot survives a
// truncated write; this is recovery, not a claim of hardware power-cut testing.
using Record = StandaloneRecord;
bool read_record(int slot, Record &r) {
    File file = LittleFS.open(paths[slot], "r");
    if (!file)
        return false;
    size_t size = file.size();
    if (size < 80 || size > STANDALONE_PROFILE_BYTES + 256) {
        file.close();
        return false;
    }
    std::string bytes(size, '\0');
    bool complete = file.readBytes(&bytes[0], size) == size;
    file.close();
    if (!complete)
        return false;
    return standalone_record_decode(bytes, r, sha, [](const std::string &body) {
        StandaloneAllocator allocator;
        JsonDocument doc(&allocator);
        const char *error = nullptr;
        return parse_profile(body, doc, &error);
    });
}
bool save_record(const std::string &body, bool on, const char **error) {
    if (!storage || !board_persists_config()) {
        if (error)
            *error = "storage_unavailable";
        return false;
    }
    if (record_generation == UINT32_MAX) {
        if (error)
            *error = "storage_generation";
        return false;
    }
    unsigned version = record_generation + 1;
    int slot = record_slot == 0 ? 1 : 0;
    Record pending;
    pending.version = version;
    pending.enabled = on;
    pending.body = body;
    std::string encoded = standalone_record_encode(pending, sha);
    size_t header_bytes = encoded.find('\n') + 1;
    std::string header = encoded.substr(0, header_bytes);
    File file = LittleFS.open(paths[slot], "w");
    if (!file) {
        if (error)
            *error = "storage_write";
        return false;
    }
    bool ok = file.write((const uint8_t *)header.data(), header.size()) == header.size() &&
              file.write((const uint8_t *)body.data(), body.size()) == body.size();
    file.flush();
    if (ok)
        ok = file.write((const uint8_t *)"\nCOMMIT\n", 8) == 8;
    file.flush();
    file.close();
    Record verify;
    if (!ok || !read_record(slot, verify) || verify.version != version || verify.enabled != on ||
        verify.body != body) {
        if (error)
            *error = "storage_readback";
        return false;
    }
    record_generation = version;
    record_slot = slot;
    profile_unavailable = false;
    return true;
}

// The resolver runs on lwIP's thread; its context survives an expired request.
// We never reuse it while a callback is outstanding. TLS connects to the numeric
// answer, with the ORIGINAL DNS name supplied for certificate verification/SNI.
struct DnsRequest {
    std::atomic<bool> pending{false}, done{false};
    bool valid = false;
    char host[254] = {};
    char address[48] = {};
};
DnsRequest dns;
void dns_found(const char *, const ip_addr_t *address, void *) {
    dns.valid = address != nullptr;
    if (address)
        ipaddr_ntoa_r(address, dns.address, sizeof(dns.address));
    dns.done.store(true);
    dns.pending.store(false);
}
void dns_start(void *) {
    ip_addr_t answer;
    err_t err =
        dns_gethostbyname_addrtype(dns.host, &answer, dns_found, nullptr, LWIP_DNS_ADDRTYPE_IPV4);
    if (err == ERR_OK)
        dns_found(dns.host, &answer, nullptr);
    else if (err != ERR_INPROGRESS)
        dns_found(dns.host, nullptr, nullptr);
}
bool current(uint32_t gen, uint32_t start) {
    return standalone_request_current(gen, generation.load(), start, millis());
}
const char *request(const char *url, uint32_t gen, std::string &body) {
    uint32_t start = millis();
    std::string address = url + 8;
    size_t slash = address.find_first_of("/?");
    std::string host = address.substr(0, slash);
    size_t colon = host.find(':');
    if (colon != std::string::npos)
        host.resize(colon);
    std::string path = slash == std::string::npos ? "/" : address.substr(slash);
    if (path[0] == '?')
        path = "/" + path;
    if (host.size() >= sizeof(dns.host))
        return "profile_url";
    if (dns.pending.load())
        return "dns_pending";
    dns.done.store(false);
    dns.pending.store(true);
    strlcpy(dns.host, host.c_str(), sizeof(dns.host));
    if (tcpip_try_callback(dns_start, nullptr) != ERR_OK) {
        dns.pending.store(false);
        return "dns_error";
    }
    while (!dns.done.load() && current(gen, start))
        vTaskDelay(pdMS_TO_TICKS(10));
    if (!current(gen, start))
        return generation.load() != gen ? "cancelled" : "request_timeout";
    if (!dns.valid)
        return "dns_error";
    esp_tls_t *tls = esp_tls_init();
    if (!tls)
        return "resource_limit";
    struct TlsGuard {
        esp_tls_t *handle;
        ~TlsGuard() {
            if (handle)
                esp_tls_conn_destroy(handle);
        }
    } tls_guard{tls};
    esp_tls_cfg_t config = {};
    config.non_block = true;
    config.timeout_ms = 500;
    config.common_name = host.c_str();
    config.crt_bundle_attach = esp_crt_bundle_attach;
    int connected = 0;
    while (current(gen, start) && (connected = esp_tls_conn_new_async(
                                       dns.address, strlen(dns.address), 443, &config, tls)) == 0)
        vTaskDelay(pdMS_TO_TICKS(10));
    const char *error = nullptr;
    if (connected != 1)
        error = current(gen, start) ? "tls_error" : "request_timeout";
    std::string wire = "GET " + path + " HTTP/1.1\r\nHost: " + host +
                       "\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nUser-Agent: "
                       "AI-Monitor-Standalone/1\r\nConnection: close\r\n\r\n";
    size_t written = 0;
    while (!error && written < wire.size() && current(gen, start)) {
        int n = esp_tls_conn_write(tls, wire.data() + written, wire.size() - written);
        if (n > 0)
            written += n;
        else if (n != ESP_TLS_ERR_SSL_WANT_READ && n != ESP_TLS_ERR_SSL_WANT_WRITE)
            error = "http_write";
        else
            vTaskDelay(pdMS_TO_TICKS(10));
    }
    StandaloneHttpDecoder decoder;
    char buffer[768];
    while (!error && !decoder.complete() && current(gen, start)) {
        int n = esp_tls_conn_read(tls, buffer, sizeof(buffer));
        if (n > 0) {
            if (!decoder.feed(buffer, n))
                error = decoder.error();
        } else if (n == 0) {
            if (!decoder.eof())
                error = decoder.error();
            break;
        } else if (n != ESP_TLS_ERR_SSL_WANT_READ && n != ESP_TLS_ERR_SSL_WANT_WRITE)
            error = "http_read";
        else
            vTaskDelay(pdMS_TO_TICKS(10));
    }
    if (!current(gen, start))
        error = generation.load() != gen ? "cancelled" : "request_timeout";
    esp_tls_conn_destroy(tls);
    tls_guard.handle = nullptr;
    if (!error)
        body = decoder.body();
    return error;
}
void worker(void *) {
    for (;;) {
        Job *job = nullptr;
        if (xQueueReceive(jobs, &job, portMAX_DELAY) != pdTRUE)
            continue;
        Result *result = new (std::nothrow) Result;
        if (!result) {
            delete job; // Wake main with a null result so busy is released.
            xQueueSend(results, &result, portMAX_DELAY);
            continue;
        }
        result->generation = job->generation;
#if defined(__EXCEPTIONS)
        try {
#endif
            std::string url;
            {
                StandaloneAllocator allocator;
                JsonDocument doc(&allocator);
                if (!parse_profile(job->profile, doc, &result->error)) {
                } else
                    url = doc["url"].as<const char *>();
            }
            std::string body;
            if (!result->error && generation.load() != job->generation)
                result->error = "cancelled";
            if (!result->error && (heap_caps_get_free_size(MALLOC_CAP_INTERNAL) < 80000 ||
                                   heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL) < 32768))
                result->error = "resource_limit";
            if (!result->error)
                result->error = request(url.c_str(), job->generation, body);
            if (!result->error) {
                StandaloneAllocator pa, ra, sa;
                JsonDocument p(&pa), response(&ra), rendered(&sa);
                if (parse_profile(job->profile, p, &result->error) &&
                    standalone_parse(body.data(), body.size(), response, &result->error) &&
                    standalone_render(p.as<JsonObjectConst>(), response.as<JsonVariantConst>(),
                                      rendered, &result->error))
                    serializeJson(rendered, result->scene);
            }
#if defined(__EXCEPTIONS)
        } catch (const std::bad_alloc &) {
            result->error = "resource_limit";
            result->scene.clear();
        }
#endif
        delete job;
        xQueueSend(results, &result, portMAX_DELAY);
    }
}

StandaloneTransfer staging;
void expire_transfer() {
    staging.expire(millis());
}
} // namespace

void standalone_invalidate() {
    generation.fetch_add(1);
    next_poll = millis();
}
static void init_impl() {
    // Never auto-format: a blank or damaged filesystem cannot harm USB or NVS.
    storage = board_persists_config() && LittleFS.begin(false, "/littlefs", 4, "spiffs");
    boot_storage_failed = !storage;
    if (storage) {
        Record best;
        for (int i = 0; i < 2; ++i) {
            Record candidate;
            if (read_record(i, candidate) && candidate.version > best.version) {
                best = std::move(candidate);
                record_slot = i;
            }
        }
        profile_unavailable =
            best.version == 0 && (LittleFS.exists(paths[0]) || LittleFS.exists(paths[1]));
        record_generation = best.version;
        enabled = best.enabled;
        profile = std::move(best.body);
        if (!profile.empty()) {
            StandaloneAllocator allocator;
            JsonDocument doc(&allocator);
            const char *error = nullptr;
            if (parse_profile(profile, doc, &error))
                metadata(doc.as<JsonObjectConst>());
            else {
                enabled = false;
                profile.clear();
            }
        }
    }
    jobs = xQueueCreate(1, sizeof(Job *));
    results = xQueueCreate(1, sizeof(Result *));
    if (!jobs || !results ||
        xTaskCreate(worker, "standalone", 8192, nullptr, 1, nullptr) != pdPASS) {
        if (jobs)
            vQueueDelete(jobs);
        if (results)
            vQueueDelete(results);
        jobs = nullptr;
        results = nullptr;
        state = "resource_limit";
    }
}
void standalone_init() {
    try {
        init_impl();
    } catch (const std::bad_alloc &) {
        enabled = false;
        owner = false;
        profile.clear();
        profile_unavailable = true;
        state = "resource_limit";
        last_error = "resource_limit";
    }
}
bool standalone_active() {
    return owner;
}
const PluginSceneSlot *standalone_scene() {
    return &scene;
}
const char *standalone_status() {
    return state;
}
uint32_t standalone_success_age_seconds() {
    return success ? (uint32_t)(millis() - last_success) / 1000 : UINT32_MAX;
}
bool standalone_stale() {
    return success &&
           (failed || (uint32_t)(millis() - last_success) >= interval_seconds * 1000 + DEADLINE_MS);
}
void standalone_tick(bool usb_owner) {
    expire_transfer();
    bool config_matches = matches_config(), wifi = wifi_time_is_connected(),
         clock = wifi_time_clock_trusted();
    if (config_matches != previous_config || wifi != previous_wifi || clock != previous_clock)
        standalone_invalidate();
    if (!config_matches && previous_config)
        clear_scene();
    previous_config = config_matches;
    previous_wifi = wifi;
    previous_clock = clock;
    bool next_owner = enabled && !profile.empty() && !usb_owner;
    if (next_owner != owner) {
        standalone_invalidate();
        owner = next_owner;
    }
    if (results) {
        Result *result = nullptr;
        if (xQueueReceive(results, &result, 0) == pdTRUE) {
            busy = false;
            if (!result) {
                failed = true;
                last_error = "resource_limit";
                state = "resource_limit";
                next_poll = millis() + 60000;
            } else {
                if (standalone_result_current(result->generation, generation.load(), owner)) {
                    if (!result->error && !result->scene.empty()) {
                        char *replacement = (char *)malloc(result->scene.size() + 1);
                        if (replacement) {
                            memcpy(replacement, result->scene.c_str(), result->scene.size() + 1);
                            free(scene.json);
                            scene.json = replacement;
                            scene.bytes = result->scene.size() + 1;
                            scene.ready = true;
                            ++scene.revision;
                            success = true;
                            failed = false;
                            last_error = nullptr;
                            failures = 0;
                            last_success = millis();
                            state = "fresh";
                            next_poll = millis() + interval_seconds * 1000;
                        } else
                            result->error = "resource_limit";
                    }
                    if (result->error) {
                        failed = true;
                        last_error = result->error;
                        state = success ? "stale" : result->error;
                        next_poll = millis() + standalone_retry_ms(failures, esp_random());
                    }
                }
                delete result;
            }
        }
    }
    if (!enabled || profile.empty()) {
        state = boot_storage_failed   ? "storage_unavailable"
                : profile_unavailable ? "profile_unavailable"
                                      : "disabled";
        return;
    }
    if (usb_owner) {
        state = "usb";
        return;
    }
    if (!config_matches) {
        state = "configuration_changed";
        failed = true;
        return;
    }
    if (!wifi) {
        state = "waiting_wifi";
        failed = success;
        return;
    }
    if (!clock) {
        state = "waiting_time";
        failed = success;
        return;
    }
    if (!jobs || !results) {
        state = "resource_limit";
        return;
    }
    if (busy || staging.active() || (int32_t)(millis() - next_poll) < 0)
        return;
    Job *job = new (std::nothrow) Job;
    if (!job) {
        state = "resource_limit";
        next_poll = millis() + 60000;
        return;
    }
    job->generation = generation.load();
#if defined(__EXCEPTIONS)
    try {
        job->profile = profile;
    } catch (const std::bad_alloc &) {
        delete job;
        state = "resource_limit";
        next_poll = millis() + 60000;
        return;
    }
#else
    job->profile = profile;
#endif
    if (xQueueSend(jobs, &job, 0) == pdTRUE) {
        busy = true;
        if (!success)
            state = "loading";
    } else
        delete job;
}
static bool command_impl(JsonObjectConst command, JsonDocument &reply) {
    const char *cmd = command["cmd"] | "";
    if (strncmp(cmd, "standalone_", 11))
        return false;
    expire_transfer();
    reply["type"] = "standalone_ack";
    reply["command"] = cmd;
    reply["ok"] = false;
    const char *transaction = command["transaction"] | "";
    if (*transaction)
        reply["transaction"] = transaction;
    const char *error = nullptr;
    if (busy && (!strcmp(cmd, "standalone_commit") || !strcmp(cmd, "standalone_remove") ||
                 !strcmp(cmd, "standalone_enabled"))) {
        standalone_invalidate();
        next_poll = millis() + 15000;
        reply["error"] = "worker_busy";
        return true;
    }
    if (!strcmp(cmd, "standalone_status")) {
        reply.clear();
        reply["type"] = "standalone_status";
        reply["available"] = jobs && results;
        reply["experimental"] = true;
        reply["storageReady"] = storage;
        reply["enabled"] = enabled;
        reply["profileId"] = profile_id;
        reply["pluginVersion"] = plugin_version;
        reply["digest"] = digest_hex;
        reply["intervalSeconds"] = interval_seconds;
        reply["state"] = state;
        reply["error"] = last_error;
        if (success)
            reply["lastSuccessAgeSeconds"] = standalone_success_age_seconds();
        else
            reply["lastSuccessAgeSeconds"] = nullptr;
        return true;
    } else if (!strcmp(cmd, "standalone_setup")) {
        if (storage) {
        } // Explicit setup never erases an already mounted filesystem.
        else if (busy)
            error = "worker_busy";
        else if (!board_persists_config())
            error = "storage_unavailable";
        else if (!LittleFS.format() || !LittleFS.begin(false, "/littlefs", 4, "spiffs"))
            error = "storage_setup";
        else {
            storage = true;
            boot_storage_failed = false;
            record_slot = -1;
            record_generation = 0;
        }
    } else if (!strcmp(cmd, "standalone_begin")) {
        if (!storage)
            error = "storage_unavailable";
        else if (!command["bytes"].is<unsigned>())
            error = "transfer_invalid";
        else if (staging.begin(transaction, command["bytes"].as<unsigned>(), command["sha256"],
                               millis(), &error)) {
            standalone_invalidate();
            reply["offset"] = staging.received();
        }
    } else if (!strcmp(cmd, "standalone_chunk")) {
        if (!command["offset"].is<unsigned>() || !command["data"].is<const char *>())
            error = "transfer_chunk";
        else {
            JsonString data = command["data"].as<JsonString>();
            if (staging.chunk(transaction, command["offset"].as<unsigned>(), data.c_str(),
                              data.size(), millis(), &error))
                reply["offset"] = staging.received();
        }
    } else if (!strcmp(cmd, "standalone_abort")) {
        if (staging.active() && strcmp(staging.transaction(), transaction))
            error = "transfer_transaction";
        else
            staging.reset();
    } else if (!strcmp(cmd, "standalone_commit")) {
        if (staging.complete(transaction, millis(), &error)) {
            std::string candidate(staging.data(), staging.size());
            if (sha(candidate) != staging.digest())
                error = "transfer_digest";
            else {
                StandaloneAllocator allocator;
                JsonDocument doc(&allocator);
                if (parse_profile(candidate, doc, &error) && save_record(candidate, true, &error)) {
                    standalone_invalidate();
                    clear_scene();
                    profile = std::move(candidate);
                    enabled = true;
                    metadata(doc.as<JsonObjectConst>());
                    staging.reset();
                    failures = 0;
                    next_poll = millis();
                    state = "loading";
                    last_error = nullptr;
                }
            }
        }
    } else if (!strcmp(cmd, "standalone_remove")) {
        if (save_record("", false, &error)) {
            standalone_invalidate();
            clear_scene();
            profile.clear();
            enabled = false;
            owner = false;
            profile_id[0] = plugin_version[0] = digest_hex[0] = 0;
            staging.reset();
            state = "disabled";
            last_error = nullptr;
        }
    } else if (!strcmp(cmd, "standalone_enabled")) {
        if (!command["value"].is<bool>() || profile.empty())
            error = "profile_unavailable";
        else if (save_record(profile, command["value"].as<bool>(), &error)) {
            standalone_invalidate();
            enabled = command["value"].as<bool>();
            state = enabled ? "loading" : "disabled";
            if (!enabled) {
                owner = false;
                clear_scene();
                state = "disabled";
                last_error = nullptr;
            }
            next_poll = millis();
        }
    } else
        error = "unknown_command";
    reply["ok"] = !error;
    if (error)
        reply["error"] = error;
    return true;
}

bool standalone_command(JsonObjectConst command, JsonDocument &reply) {
#if defined(__EXCEPTIONS)
    try {
        return command_impl(command, reply);
    } catch (const std::bad_alloc &) {
        reply.clear();
        reply["type"] = "standalone_ack";
        reply["command"] = command["cmd"];
        reply["transaction"] = command["transaction"];
        reply["ok"] = false;
        reply["error"] = "resource_limit";
        return true;
    }
#else
    return command_impl(command, reply);
#endif
}
