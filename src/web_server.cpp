/**
 * Async Web Server - Config Portal + REST API
 *
 * Serves a dark-themed config UI and provides JSON endpoints
 * for reading/writing config and checking device status.
 */

#include "web_server.h"
#include "config.h"
#include "wifi_setup.h"
#include "ntp_time.h"
#include "api_manager.h"

#include <WiFi.h>
#include <ESPAsyncWebServer.h>
#include <ArduinoJson.h>
#include <Preferences.h>

// ============================================================
// External references
// ============================================================
extern AppConfig g_config;
extern void config_save(const AppConfig &cfg);
extern void config_load(AppConfig &cfg);

// ============================================================
// Server instance
// ============================================================
static AsyncWebServer server(80);

// ============================================================
// Mask API key: show first 4 + last 4, rest asterisks
// ============================================================
static String maskKey(const char *key) {
    size_t len = strlen(key);
    if (len == 0) return "";
    if (len <= 8) return "********";
    String masked = String(key).substring(0, 4);
    for (size_t i = 4; i < len - 4; i++) masked += '*';
    masked += String(key).substring(len - 4);
    return masked;
}

// ============================================================
// Uptime string
// ============================================================
static String getUptime() {
    unsigned long sec = millis() / 1000;
    unsigned long d = sec / 86400; sec %= 86400;
    unsigned long h = sec / 3600;  sec %= 3600;
    unsigned long m = sec / 60;    sec %= 60;
    char buf[32];
    snprintf(buf, sizeof(buf), "%lud %luh %lum %lus", d, h, m, sec);
    return String(buf);
}

// ============================================================
// Embedded HTML/CSS/JS - Config Portal UI
// ============================================================
static const char INDEX_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AI Monitor Config</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#1A1A2E;color:#E0E0E0;min-height:100vh;display:flex;justify-content:center;padding:16px}
.container{width:100%;max-width:480px}
h1{text-align:center;color:#E94560;font-size:1.4em;margin-bottom:8px}
.subtitle{text-align:center;color:#666;font-size:.85em;margin-bottom:20px}
.status-bar{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:20px;padding:12px;background:#16213E;border-radius:8px;font-size:.8em}
.status-bar .item{display:flex;flex-direction:column}
.status-bar .label{color:#888;font-size:.75em;text-transform:uppercase}
.status-bar .value{color:#0F3460;font-weight:600;color:#E94560}
.group{margin-bottom:16px;padding:14px;background:#16213E;border-radius:8px}
.group h2{font-size:.95em;color:#E94560;margin-bottom:10px;border-bottom:1px solid #0F3460;padding-bottom:6px}
.field{margin-bottom:10px}
.field label{display:block;font-size:.8em;color:#AAA;margin-bottom:4px}
.field .input-wrap{position:relative;display:flex}
.field input{width:100%;padding:8px 10px;background:#0F3460;border:1px solid #1A1A2E;border-radius:4px;color:#E0E0E0;font-size:.9em;outline:none}
.field input:focus{border-color:#E94560}
.field input[type="number"]{-moz-appearance:textfield}
.toggle-btn{position:absolute;right:6px;top:50%;transform:translateY(-50%);background:none;border:none;color:#888;cursor:pointer;font-size:1.1em;padding:4px}
.toggle-btn:hover{color:#E94560}
.actions{display:flex;gap:10px;margin-top:16px}
.btn{flex:1;padding:12px;border:none;border-radius:6px;font-size:.95em;font-weight:600;cursor:pointer;transition:background .2s}
.btn-save{background:#E94560;color:#fff}
.btn-save:hover{background:#c73550}
.btn-save.success{background:#27ae60}
.btn-restart{background:#0F3460;color:#E0E0E0}
.btn-restart:hover{background:#1a4a8a}
.msg{text-align:center;padding:8px;margin-top:10px;border-radius:4px;font-size:.85em;display:none}
.msg.show{display:block}
.msg.ok{background:#27ae6033;color:#27ae60}
.msg.err{background:#e9456033;color:#E94560}
</style>
</head>
<body>
<div class="container">
<h1>AI Usage Monitor</h1>
<p class="subtitle">Configuration Portal</p>

<div class="status-bar" id="status">
  <div class="item"><span class="label">IP</span><span class="value" id="s-ip">--</span></div>
  <div class="item"><span class="label">RSSI</span><span class="value" id="s-rssi">--</span></div>
  <div class="item"><span class="label">Heap</span><span class="value" id="s-heap">--</span></div>
  <div class="item"><span class="label">Uptime</span><span class="value" id="s-uptime">--</span></div>
</div>

<form id="configForm">
  <div class="group">
    <h2>Anthropic</h2>
    <div class="field">
      <label>API Key</label>
      <div class="input-wrap">
        <input type="password" id="anthropic_key" name="anthropic_key" placeholder="sk-ant-...">
        <button type="button" class="toggle-btn" onclick="toggleVis(this)">&#128065;</button>
      </div>
    </div>
    <div class="field">
      <label>Organization ID</label>
      <input type="text" id="anthropic_org" name="anthropic_org" placeholder="org-...">
    </div>
  </div>

  <div class="group">
    <h2>OpenAI</h2>
    <div class="field">
      <label>API Key</label>
      <div class="input-wrap">
        <input type="password" id="openai_key" name="openai_key" placeholder="sk-...">
        <button type="button" class="toggle-btn" onclick="toggleVis(this)">&#128065;</button>
      </div>
    </div>
    <div class="field">
      <label>Organization ID</label>
      <input type="text" id="openai_org" name="openai_org" placeholder="org-...">
    </div>
  </div>

  <div class="group">
    <h2>Settings</h2>
    <div class="field">
      <label>Polling Interval (seconds)</label>
      <input type="number" id="poll_interval_sec" name="poll_interval_sec" min="10" max="86400" value="300">
    </div>
  </div>

  <div class="actions">
    <button type="submit" class="btn btn-save" id="saveBtn">Save</button>
    <button type="button" class="btn btn-restart" onclick="doRestart()">Restart</button>
  </div>
  <div class="msg" id="msg"></div>
</form>
</div>

<script>
function toggleVis(btn){
  const inp=btn.parentElement.querySelector('input');
  inp.type=inp.type==='password'?'text':'password';
}

function showMsg(text,ok){
  const m=document.getElementById('msg');
  m.textContent=text;
  m.className='msg show '+(ok?'ok':'err');
  setTimeout(()=>m.classList.remove('show'),3000);
}

async function loadStatus(){
  try{
    const r=await fetch('/api/status');
    const d=await r.json();
    document.getElementById('s-ip').textContent=d.ip||'--';
    document.getElementById('s-rssi').textContent=(d.rssi||'--')+' dBm';
    document.getElementById('s-heap').textContent=Math.round((d.free_heap||0)/1024)+' KB';
    document.getElementById('s-uptime').textContent=d.uptime||'--';
  }catch(e){}
}

async function loadConfig(){
  try{
    const r=await fetch('/api/config');
    const d=await r.json();
    document.getElementById('anthropic_key').placeholder=d.anthropic_key||'sk-ant-...';
    document.getElementById('anthropic_org').value=d.anthropic_org||'';
    document.getElementById('openai_key').placeholder=d.openai_key||'sk-...';
    document.getElementById('openai_org').value=d.openai_org||'';
    document.getElementById('poll_interval_sec').value=d.poll_interval_sec||300;
  }catch(e){}
}

document.getElementById('configForm').addEventListener('submit',async function(e){
  e.preventDefault();
  const btn=document.getElementById('saveBtn');
  const data={};
  const ak=document.getElementById('anthropic_key').value;
  if(ak)data.anthropic_key=ak;
  const ao=document.getElementById('anthropic_org').value;
  if(ao)data.anthropic_org=ao;
  const ok_=document.getElementById('openai_key').value;
  if(ok_)data.openai_key=ok_;
  const oo=document.getElementById('openai_org').value;
  if(oo)data.openai_org=oo;
  data.poll_interval_sec=parseInt(document.getElementById('poll_interval_sec').value)||300;

  try{
    const r=await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
    if(r.ok){
      btn.classList.add('success');btn.textContent='Saved!';
      setTimeout(()=>{btn.classList.remove('success');btn.textContent='Save';},2000);
      showMsg('Configuration saved successfully',true);
      loadConfig();
    }else{
      showMsg('Failed to save',false);
    }
  }catch(e){showMsg('Error: '+e.message,false);}
});

async function doRestart(){
  if(!confirm('Restart the device?'))return;
  try{await fetch('/api/restart',{method:'POST'});}catch(e){}
  showMsg('Restarting...',true);
}

loadStatus();
loadConfig();
setInterval(loadStatus,5000);
</script>
</body>
</html>
)rawliteral";

// ============================================================
// Init Web Server
// ============================================================
void webserver_init() {
    // Serve config page
    server.on("/", HTTP_GET, [](AsyncWebServerRequest *request) {
        request->send_P(200, "text/html", INDEX_HTML);
    });

    // GET /api/config — return config with masked keys
    server.on("/api/config", HTTP_GET, [](AsyncWebServerRequest *request) {
        JsonDocument doc;
        doc["anthropic_key"] = maskKey(g_config.anthropic_key);
        doc["anthropic_org"] = String(g_config.anthropic_org);
        doc["openai_key"]    = maskKey(g_config.openai_key);
        doc["openai_org"]    = String(g_config.openai_org);
        doc["poll_interval_sec"] = g_config.poll_interval_sec;

        String json;
        serializeJson(doc, json);
        request->send(200, "application/json", json);
    });

    // POST /api/config — save config
    server.on("/api/config", HTTP_POST,
        // Request handler (called after body is received)
        [](AsyncWebServerRequest *request) {},
        // Upload handler (not used)
        nullptr,
        // Body handler
        [](AsyncWebServerRequest *request, uint8_t *data, size_t len, size_t index, size_t total) {
            // Collect body (should fit in one chunk for our small JSON)
            if (index == 0 && len == total) {
                JsonDocument doc;
                DeserializationError err = deserializeJson(doc, data, len);
                if (err) {
                    request->send(400, "application/json", "{\"error\":\"Invalid JSON\"}");
                    return;
                }

                // Only update fields that are present and non-empty
                if (doc["anthropic_key"].is<const char*>()) {
                    const char *v = doc["anthropic_key"];
                    if (strlen(v) > 0) strlcpy(g_config.anthropic_key, v, sizeof(g_config.anthropic_key));
                }
                if (doc["anthropic_org"].is<const char*>()) {
                    strlcpy(g_config.anthropic_org, doc["anthropic_org"], sizeof(g_config.anthropic_org));
                }
                if (doc["openai_key"].is<const char*>()) {
                    const char *v = doc["openai_key"];
                    if (strlen(v) > 0) strlcpy(g_config.openai_key, v, sizeof(g_config.openai_key));
                }
                if (doc["openai_org"].is<const char*>()) {
                    strlcpy(g_config.openai_org, doc["openai_org"], sizeof(g_config.openai_org));
                }
                if (doc["poll_interval_sec"].is<unsigned int>()) {
                    uint32_t val = doc["poll_interval_sec"];
                    if (val >= 10 && val <= 86400) g_config.poll_interval_sec = val;
                }

                config_save(g_config);
                request->send(200, "application/json", "{\"status\":\"ok\"}");
                Serial.println("[Web] Config updated via API");
            }
        }
    );

    // GET /api/status
    server.on("/api/status", HTTP_GET, [](AsyncWebServerRequest *request) {
        JsonDocument doc;
        doc["ip"]        = wifi_get_ip();
        doc["ssid"]      = wifi_get_ssid();
        doc["rssi"]      = wifi_get_rssi();
        doc["free_heap"] = ESP.getFreeHeap();
        doc["min_heap"]  = ESP.getMinFreeHeap();
        doc["uptime"]    = getUptime();
        doc["time"]      = ntp_get_datetime();
        doc["time_synced"] = ntp_is_synced();

        String json;
        serializeJson(doc, json);
        request->send(200, "application/json", json);
    });

    // GET /api/usage — return current MonitorState as JSON
    server.on("/api/usage", HTTP_GET, [](AsyncWebServerRequest *request) {
        const MonitorState &s = api_manager_get_state();
        JsonDocument doc;

        // Status
        doc["status"]          = s.status;
        doc["is_fetching"]     = s.is_fetching;
        doc["total_today_cost"] = s.total_today_cost;
        doc["total_month_cost"] = s.total_month_cost;

        // Helper lambda to serialize UsageData
        auto serializeUsage = [](JsonObject obj, const UsageData &u) {
            obj["valid"]       = u.valid;
            obj["last_fetch"]  = u.last_fetch;
            obj["error"]       = u.error;

            JsonObject today = obj["today"].to<JsonObject>();
            today["input_tokens"]  = u.today_input_tokens;
            today["output_tokens"] = u.today_output_tokens;
            today["cached_tokens"] = u.today_cached_tokens;
            today["requests"]      = u.today_requests;
            today["cost"]          = u.today_cost;

            JsonObject month = obj["month"].to<JsonObject>();
            month["input_tokens"]  = u.month_input_tokens;
            month["output_tokens"] = u.month_output_tokens;
            month["cached_tokens"] = u.month_cached_tokens;
            month["requests"]      = u.month_requests;
            month["cost"]          = u.month_cost;

            JsonArray models = obj["models"].to<JsonArray>();
            for (uint8_t i = 0; i < u.model_count; i++) {
                JsonObject m = models.add<JsonObject>();
                m["model"]        = u.models[i].model;
                m["input_tokens"] = u.models[i].input_tokens;
                m["output_tokens"] = u.models[i].output_tokens;
                m["cached_tokens"] = u.models[i].cached_tokens;
                m["requests"]     = u.models[i].requests;
            }
        };

        JsonObject anthropic = doc["anthropic"].to<JsonObject>();
        serializeUsage(anthropic, s.anthropic);

        JsonObject openai = doc["openai"].to<JsonObject>();
        serializeUsage(openai, s.openai);

        String json;
        serializeJson(doc, json);
        request->send(200, "application/json", json);
    });

    // POST /api/restart
    server.on("/api/restart", HTTP_POST, [](AsyncWebServerRequest *request) {
        request->send(200, "application/json", "{\"status\":\"restarting\"}");
        delay(500);
        ESP.restart();
    });

    // Start server
    server.begin();
    Serial.println("[Web] AsyncWebServer started on port 80");
}

// ============================================================
// Get URL for QR code
// ============================================================
String webserver_get_url() {
    return "http://" + wifi_get_ip() + "/";
}
