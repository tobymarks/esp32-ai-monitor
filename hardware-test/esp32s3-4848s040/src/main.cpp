/**
 * Hardware-Test ESP32-S3-4848S040
 *
 * Drei Seiten, Wechsel per Tipp auf "weiter" (oben rechts) oder `p` seriell:
 *   1. Farbtest   — Verlaeufe R/G/B/Grau, Vollfarben, 1-px-Rahmen am Rand
 *   2. Touch      — Punkte unter dem Finger, Zielkreuze, Helligkeitsleiste
 *   3. Drift-Test — feines Raster + bewegtes Feld, dazu NVS-Schreibzugriffe
 *                   im 200-ms-Takt (wie config_save() in der Firmware)
 *
 * Serielle Befehle (115200 Baud, mit Enter abschliessen):
 *   b<0..100>  Helligkeit in Prozent      f<hz>  PWM-Frequenz Backlight
 *   p          naechste Seite             n      NVS-Schreiblast an/aus
 *   w          WLAN-Scan                  d      WLAN aus
 *   x          esp_lcd_rgb_panel_restart()  t   automatischer Lasttest
 *   i          Board-Infos
 *
 * Achtung: Das Oeffnen des seriellen Ports startet das Board neu (der CH340
 * zieht dabei die Reset-Leitung). Jede Messung beginnt also mit einem Boot.
 *
 * Display-Parameter 1:1 aus dem Arduino_GFX-Preset ESP32_4848S040_86BOX_GUITION
 * (examples/PDQgraphicstest/Arduino_GFX_dev_device.h, v1.6.7), nur Rotation 0
 * statt 1: der Test soll die native Ausrichtung des Panels zeigen.
 */

#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <Wire.h>

// Nur fuer diesen Test: Arduino_GFX haelt den esp_lcd-Panel-Handle privat,
// wir brauchen ihn aber fuer esp_lcd_rgb_panel_restart(). In der Firmware
// wird die Board-Schnittstelle das Panel selbst anlegen, dann faellt der
// Kniff weg.
#define private public
#include <Arduino_GFX_Library.h>
#undef private

#include <esp_lcd_panel_rgb.h>
#include <esp_timer.h>

#ifndef BOUNCE_BUFFER_PX
#define BOUNCE_BUFFER_PX 0
#endif
#ifndef PCLK_HZ
#define PCLK_HZ 12000000
#endif
#ifndef PCLK_NEG
#define PCLK_NEG 0
#endif

// ============================================================
// Pins
// ============================================================
static const int PIN_BL        = 38;
static const int PIN_TOUCH_SDA = 19;
static const int PIN_TOUCH_SCL = 45;

static const int16_t SCR_W = 480;
static const int16_t SCR_H = 480;

// ============================================================
// Display: ST7701S, Init per 3-Wire-SPI (9 Bit), Pixel per 16-Bit-RGB
// ============================================================
static Arduino_DataBus *bus = new Arduino_SWSPI(
    GFX_NOT_DEFINED /* DC */, 39 /* CS */,
    48 /* SCK */, 47 /* MOSI */, GFX_NOT_DEFINED /* MISO */);

static Arduino_ESP32RGBPanel *rgbpanel = new Arduino_ESP32RGBPanel(
    18 /* DE */, 17 /* VSYNC */, 16 /* HSYNC */, 21 /* PCLK */,
    11 /* R0 */, 12 /* R1 */, 13 /* R2 */, 14 /* R3 */, 0 /* R4 */,
    8 /* G0 */, 20 /* G1 */, 3 /* G2 */, 46 /* G3 */, 9 /* G4 */, 10 /* G5 */,
    4 /* B0 */, 5 /* B1 */, 6 /* B2 */, 7 /* B3 */, 15 /* B4 */,
    1 /* hsync_polarity */, 10 /* hsync_front_porch */, 8 /* hsync_pulse_width */, 50 /* hsync_back_porch */,
    1 /* vsync_polarity */, 10 /* vsync_front_porch */, 8 /* vsync_pulse_width */, 20 /* vsync_back_porch */,
    PCLK_NEG /* pclk_active_neg */, PCLK_HZ /* prefer_speed */, false /* useBigEndian */,
    0 /* de_idle_high */, 0 /* pclk_idle_high */, BOUNCE_BUFFER_PX /* bounce_buffer_size_px */);

static Arduino_RGB_Display *gfx = new Arduino_RGB_Display(
    SCR_W, SCR_H, rgbpanel, 0 /* rotation */, true /* auto_flush */,
    bus, GFX_NOT_DEFINED /* RST */, st7701_type9_init_operations, sizeof(st7701_type9_init_operations));

// ============================================================
// Aussetzer-Erkennung
// ------------------------------------------------------------
// Das Panel meldet jeden Bildanfang. Reisst der Nachschub aus dem PSRAM ab,
// dauert ein Bild laenger als vorgesehen — genau dann rutscht das Bild. Die
// Zaehlung macht die Messung unabhaengig davon, ob jemand hinschaut.
// ============================================================
// Nennwert eines Bildes in Mikrosekunden: (480+8+10+50) x (480+8+10+20) / PCLK
static const int64_t FRAME_US_NOMINAL = (int64_t)(548.0 * 518.0 * 1000000.0 / (double)PCLK_HZ);

static volatile uint32_t vsync_frames = 0;
static volatile uint32_t vsync_glitches = 0;
static volatile int64_t  vsync_worst_us = 0;
static volatile int64_t  vsync_last_us = 0;

static bool IRAM_ATTR on_vsync(esp_lcd_panel_handle_t panel,
                               const esp_lcd_rgb_panel_event_data_t *data, void *user)
{
    int64_t now = esp_timer_get_time();
    if (vsync_last_us != 0) {
        int64_t dt = now - vsync_last_us;
        if (dt > (FRAME_US_NOMINAL * 3) / 2) {
            vsync_glitches++;
            if (dt > vsync_worst_us) vsync_worst_us = dt;
        }
    }
    vsync_last_us = now;
    vsync_frames++;
    return false;
}

static uint16_t rgb(uint8_t r, uint8_t g, uint8_t b)
{
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
}

static const uint16_t C_BLACK  = 0x0000;
static const uint16_t C_WHITE  = 0xFFFF;
static const uint16_t C_GRID   = rgb(60, 60, 60);
static const uint16_t C_SEC    = rgb(166, 164, 154);
static const uint16_t C_ACCENT = rgb(217, 119, 87);

// ============================================================
// Backlight (LEDC, Core-3-API: Pin statt Channel)
// ============================================================
static const uint8_t BL_RES_BITS = 8;
static uint32_t bl_freq_hz = 1000;
static uint8_t  bl_pct     = 80;

static void backlight_set(uint8_t pct)
{
    if (pct > 100) pct = 100;
    bl_pct = pct;
    ledcWrite(PIN_BL, (uint32_t)pct * 255u / 100u);
}

// ============================================================
// Touch: GT911 an I2C, INT und RST nicht angeschlossen
// ============================================================
static uint8_t gt_addr = 0;
static bool    touch_down = false;
static int16_t touch_x = 0, touch_y = 0;

static bool gt_read(uint16_t reg, uint8_t *buf, size_t len)
{
    Wire.beginTransmission(gt_addr);
    Wire.write((uint8_t)(reg >> 8));
    Wire.write((uint8_t)(reg & 0xFF));
    if (Wire.endTransmission(true) != 0) return false;
    if (Wire.requestFrom((uint16_t)gt_addr, (size_t)len, true) != len) return false;
    for (size_t i = 0; i < len; i++) buf[i] = Wire.read();
    return true;
}

static bool gt_write8(uint16_t reg, uint8_t value)
{
    Wire.beginTransmission(gt_addr);
    Wire.write((uint8_t)(reg >> 8));
    Wire.write((uint8_t)(reg & 0xFF));
    Wire.write(value);
    return Wire.endTransmission(true) == 0;
}

static bool gt_init()
{
    Wire.begin(PIN_TOUCH_SDA, PIN_TOUCH_SCL);
    Wire.setClock(400000);

    // Ohne RST/INT-Leitung entscheidet der Pegel beim Einschalten ueber die
    // Adresse — beide moeglichen probieren.
    const uint8_t candidates[] = {0x5D, 0x14};
    for (uint8_t addr : candidates) {
        Wire.beginTransmission(addr);
        if (Wire.endTransmission(true) == 0) {
            gt_addr = addr;
            break;
        }
    }
    if (gt_addr == 0) {
        Serial.println("[Touch] GT911 nicht gefunden (weder 0x5D noch 0x14)");
        return false;
    }

    uint8_t pid[5] = {0};
    uint8_t res[4] = {0};
    gt_read(0x8140, pid, 4);
    gt_read(0x8048, res, 4);
    Serial.printf("[Touch] GT911 an 0x%02X, Produkt-ID \"%s\", Aufloesung laut Config %ux%u\n",
                  gt_addr, (char *)pid, res[0] | (res[1] << 8), res[2] | (res[3] << 8));
    return true;
}

// Liest den ersten Beruehrungspunkt. Rohkoordinaten, keine Transformation:
// genau das soll der Test zeigen.
static void gt_poll()
{
    if (gt_addr == 0) return;
    uint8_t status = 0;
    if (!gt_read(0x814E, &status, 1)) return;
    if (!(status & 0x80)) return;  // noch keine neuen Daten

    uint8_t points = status & 0x0F;
    if (points > 0 && points <= 5) {
        uint8_t p[4];
        if (gt_read(0x8150, p, 4)) {
            touch_x = p[0] | (p[1] << 8);
            touch_y = p[2] | (p[3] << 8);
            touch_down = true;
        }
    } else {
        touch_down = false;
    }
    gt_write8(0x814E, 0);
}

// ============================================================
// Seiten
// ============================================================
enum Page : uint8_t { PAGE_COLORS = 0, PAGE_TOUCH, PAGE_DRIFT, PAGE_COUNT };
static Page page = PAGE_COLORS;

static const int16_t BTN_X = 372, BTN_Y = 8, BTN_W = 100, BTN_H = 44;

static void draw_title(const char *title)
{
    gfx->setTextColor(C_WHITE, C_BLACK);
    gfx->setTextSize(3);
    gfx->setCursor(16, 18);
    gfx->print(title);

    gfx->drawRoundRect(BTN_X, BTN_Y, BTN_W, BTN_H, 8, C_WHITE);
    gfx->setTextSize(2);
    gfx->setCursor(BTN_X + 14, BTN_Y + 15);
    gfx->print("weiter");

    gfx->drawFastHLine(0, 59, SCR_W, C_GRID);
}

// 1-px-Rahmen exakt auf Zeile/Spalte 0 und 479: fehlt eine Kante, stimmen
// Porch-Werte oder Aufloesung nicht.
static void draw_frame()
{
    gfx->drawRect(0, 0, SCR_W, SCR_H, C_WHITE);
    gfx->fillTriangle(0, 0, 24, 0, 0, 24, C_ACCENT);  // Markierung oben links
}

static void draw_page_colors()
{
    gfx->fillScreen(C_BLACK);
    draw_title("1/3 Farben");

    // Verlaeufe ueber 448 px: Rot/Blau 32 Stufen, Gruen 64, Grau 32.
    // Stufenspruenge oder falsche Farben deuten auf vertauschte Datenpins.
    const int16_t x0 = 16, w = 448, row_h = 52, gap = 8;
    int16_t y = 76;
    for (int row = 0; row < 4; row++) {
        for (int16_t i = 0; i < w; i++) {
            uint8_t v = (uint8_t)((uint32_t)i * 255u / (w - 1));
            uint16_t c;
            switch (row) {
                case 0:  c = rgb(v, 0, 0); break;
                case 1:  c = rgb(0, v, 0); break;
                case 2:  c = rgb(0, 0, v); break;
                default: c = rgb(v, v, v); break;
            }
            gfx->drawFastVLine(x0 + i, y, row_h, c);
        }
        y += row_h + gap;
    }

    // Vollfarben mit Beschriftung
    struct Swatch { uint16_t color; const char *label; uint16_t text; };
    const Swatch swatches[] = {
        {rgb(255, 0, 0),   "R", C_WHITE},
        {rgb(0, 255, 0),   "G", C_BLACK},
        {rgb(0, 0, 255),   "B", C_WHITE},
        {C_WHITE,          "W", C_BLACK},
        {rgb(43, 42, 39),  "BG", C_WHITE},   // Dashboard-Hintergrund dunkel
        {C_ACCENT,         "AC", C_WHITE},   // Claude-Akzent
    };
    const int16_t sw = 68, sgap = 8;
    y += 8;
    for (int i = 0; i < 6; i++) {
        int16_t sx = 16 + i * (sw + sgap);
        gfx->fillRect(sx, y, sw, 84, swatches[i].color);
        gfx->setTextColor(swatches[i].text);
        gfx->setTextSize(3);
        gfx->setCursor(sx + 8, y + 8);
        gfx->print(swatches[i].label);
    }

    draw_frame();
}

static const int16_t STRIP_X = 16, STRIP_Y = 404, STRIP_W = 448, STRIP_H = 60;

static void draw_brightness_strip()
{
    int16_t fill = (int16_t)((int32_t)STRIP_W * bl_pct / 100);
    gfx->fillRect(STRIP_X, STRIP_Y, fill, STRIP_H, C_ACCENT);
    gfx->fillRect(STRIP_X + fill, STRIP_Y, STRIP_W - fill, STRIP_H, C_GRID);
    gfx->setTextColor(C_WHITE);
    gfx->setTextSize(3);
    gfx->setCursor(STRIP_X + 12, STRIP_Y + 18);
    gfx->printf("Helligkeit %u%%", bl_pct);
}

static void draw_cross(int16_t x, int16_t y)
{
    gfx->drawFastHLine(x - 14, y, 29, C_WHITE);
    gfx->drawFastVLine(x, y - 14, 29, C_WHITE);
    gfx->drawCircle(x, y, 8, C_WHITE);
}

static void draw_page_touch()
{
    gfx->fillScreen(C_BLACK);
    for (int16_t x = 60; x < SCR_W; x += 60) gfx->drawFastVLine(x, 60, 330, C_GRID);
    for (int16_t y = 120; y < 390; y += 60) gfx->drawFastHLine(0, y, SCR_W, C_GRID);
    draw_title("2/3 Touch");

    // Ziele nahe den Ecken und in der Mitte: der Punkt muss genau im Kreis landen.
    draw_cross(40, 100);
    draw_cross(440, 100);
    draw_cross(40, 360);
    draw_cross(440, 360);
    draw_cross(240, 230);

    draw_brightness_strip();
    draw_frame();
}

static const int16_t ANIM_Y = 300, ANIM_H = 60, ANIM_BOX = 40;

static void draw_page_drift()
{
    gfx->fillScreen(C_BLACK);
    // Feines Raster: verrutscht das Bild, springen die Linien sichtbar.
    for (int16_t x = 20; x < SCR_W; x += 20) gfx->drawFastVLine(x, 60, SCR_H - 60, C_GRID);
    for (int16_t y = 80; y < SCR_H; y += 20) gfx->drawFastHLine(0, y, SCR_W, C_GRID);
    gfx->fillRect(0, ANIM_Y - 10, SCR_W, ANIM_H + 20, C_BLACK);
    draw_title("3/3 Drift");

    gfx->setTextSize(2);
    gfx->setTextColor(C_SEC, C_BLACK);
    gfx->setCursor(16, 218);
    gfx->printf("Bounce %d px, PCLK %d MHz", BOUNCE_BUFFER_PX, PCLK_HZ / 1000000);

    draw_frame();
}

static void draw_page()
{
    switch (page) {
        case PAGE_COLORS: draw_page_colors(); break;
        case PAGE_TOUCH:  draw_page_touch();  break;
        case PAGE_DRIFT:  draw_page_drift();  break;
        default: break;
    }
    Serial.printf("[UI] Seite %u\n", (unsigned)page + 1);
}

static void next_page()
{
    page = (Page)((page + 1) % PAGE_COUNT);
    draw_page();
}

// Zieht die Synchronisation des RGB-Peripherals wieder gerade, ohne das Panel
// neu zu initialisieren. Der Framebuffer bleibt erhalten.
static void panel_restart()
{
    esp_err_t err = esp_lcd_rgb_panel_restart(rgbpanel->_panel_handle);
    Serial.printf("[Panel] restart: %s\n", esp_err_to_name(err));
}

// ============================================================
// Drift-Seite: NVS-Last + Animation
// ============================================================
static Preferences prefs;
static uint32_t nvs_writes = 0;
static bool nvs_load_on = false;
static unsigned long last_nvs_ms = 0;
static unsigned long last_anim_ms = 0;
static int16_t anim_x = 0, anim_dx = 6;
static uint32_t frames = 0;
static unsigned long fps_window_ms = 0;

// Stossbetrieb (`r`): alle 15 s ein Schwung Schreibzugriffe wie bei einer
// Einstellungsaenderung, danach die Synchronisation nachziehen. Das bildet ab,
// was die echte Firmware tut — im Gegensatz zur Dauerlast von `n`.
static bool          burst_on = false;
static unsigned long last_burst_ms = 0;
static uint16_t      burst_count = 0;

static void burst_tick()
{
    if (!burst_on) return;
    unsigned long now = millis();
    if (now - last_burst_ms < 15000) return;
    last_burst_ms = now;

    unsigned long t0 = millis();
    for (int i = 0; i < 10; i++) prefs.putUInt("b", ++nvs_writes);
    unsigned long dauer = millis() - t0;

    panel_restart();
    Serial.printf("[Stoss] %u: 10 Schreibzugriffe in %lu ms, danach Restart\n",
                  ++burst_count, dauer);
}

// Schreiblast laeuft unabhaengig von der Seite, damit sie sich getrennt
// zuschalten laesst (`n`).
static void nvs_tick()
{
    unsigned long now = millis();
    if (!nvs_load_on || now - last_nvs_ms < 200) return;
    last_nvs_ms = now;
    prefs.putUInt("n", ++nvs_writes);
    if (page == PAGE_DRIFT) {
        gfx->setTextSize(2);
        gfx->setTextColor(C_WHITE, C_BLACK);
        gfx->setCursor(16, 160);
        gfx->printf("NVS-Schreibzugriffe: %lu   ", (unsigned long)nvs_writes);
    }
}

static void drift_tick()
{
    unsigned long now = millis();

    if (now - last_anim_ms >= 16) {
        last_anim_ms = now;
        gfx->fillRect(anim_x, ANIM_Y, ANIM_BOX, ANIM_H, C_BLACK);
        anim_x += anim_dx;
        if (anim_x <= 0 || anim_x >= SCR_W - ANIM_BOX) {
            anim_dx = -anim_dx;
            anim_x = constrain(anim_x, 0, SCR_W - ANIM_BOX);
        }
        gfx->fillRect(anim_x, ANIM_Y, ANIM_BOX, ANIM_H, C_ACCENT);
        frames++;
    }

    if (now - fps_window_ms >= 1000) {
        gfx->setTextSize(2);
        gfx->setTextColor(C_SEC, C_BLACK);
        gfx->setCursor(16, 190);
        gfx->printf("Animation: %lu Bilder/s   ", (unsigned long)frames);
        frames = 0;
        fps_window_ms = now;
    }
}

// ============================================================
// Automatischer Lasttest (`t`)
// ------------------------------------------------------------
// Schaltet die Lastphasen selbst weiter und schreibt Phase und Restzeit aufs
// Display, damit niemand mitstoppen muss. Ein Tipp auf den Bildschirm setzt
// eine Markierung ins Protokoll.
// ============================================================
struct SeqPhase { const char *name; uint16_t secs; };
static const SeqPhase SEQ[] = {
    {"A: keine Last",    30},
    {"B: NVS-Last",      30},
    {"C: NVS + WLAN",    50},
    {"D: + Restart 2s",  50},
    {"fertig",            0},
};
static const uint8_t SEQ_COUNT = sizeof(SEQ) / sizeof(SEQ[0]);

static bool          seq_active = false;
static uint8_t       seq_idx = 0;
static unsigned long seq_phase_start = 0;
static unsigned long seq_total_start = 0;
static unsigned long seq_last_draw = 0;
// Phase D zieht die Synchronisation regelmaessig nach, waehrend die Last
// weiterlaeuft. Zeigt, ob ein Restart als Gegenmittel taugt.
static bool          seq_periodic_restart = false;
static unsigned long seq_last_restart = 0;
static uint16_t      seq_restart_count = 0;

static void seq_draw()
{
    if (page != PAGE_DRIFT) return;
    unsigned long elapsed = (millis() - seq_phase_start) / 1000;
    int rest = (int)SEQ[seq_idx].secs - (int)elapsed;
    if (rest < 0) rest = 0;

    gfx->setTextSize(3);
    gfx->setTextColor(C_WHITE, C_BLACK);
    gfx->setCursor(16, 90);
    gfx->printf("%-16s", SEQ[seq_idx].name);

    gfx->setTextSize(2);
    gfx->setTextColor(C_SEC, C_BLACK);
    gfx->setCursor(16, 130);
    if (SEQ[seq_idx].secs > 0) {
        gfx->printf("noch %3d s  -  tippen = Markierung", rest);
    } else {
        gfx->printf("Test beendet                      ");
    }
}

static void seq_enter(uint8_t idx)
{
    if (idx >= SEQ_COUNT) idx = SEQ_COUNT - 1;
    seq_idx = idx;
    seq_phase_start = millis();
    seq_last_draw = seq_phase_start;

    switch (idx) {
        case 0:  // Ausgangslage: nichts laeuft
            nvs_load_on = false;
            WiFi.mode(WIFI_OFF);
            break;
        case 1:  // Schreibzugriffe wie config_save()
            nvs_load_on = true;
            break;
        case 2:  // zusaetzlich Funk
            WiFi.mode(WIFI_STA);
            WiFi.scanNetworks(true);
            seq_periodic_restart = false;
            break;
        case 3:  // Gegenmittel im Dauerbetrieb, Last bleibt an
            seq_periodic_restart = true;
            seq_last_restart = millis();
            seq_restart_count = 0;
            break;
        default:
            nvs_load_on = false;
            seq_periodic_restart = false;
            WiFi.mode(WIFI_OFF);
            seq_active = false;
            break;
    }

    Serial.printf("[Test] %lus: Phase %s\n",
                  (unsigned long)((millis() - seq_total_start) / 1000), SEQ[idx].name);
    seq_draw();
}

// Staerkere Stufe als der Restart: schickt die Init-Sequenz erneut an den
// ST7701S. Der Anzeigebaustein selbst faengt damit neu an zu zaehlen, nicht
// nur das RGB-Peripheral im Prozessor. Dauert rund 120 ms.
static void panel_reinit()
{
    unsigned long t0 = millis();
    bus->batchOperation(st7701_type9_init_operations, sizeof(st7701_type9_init_operations));
    esp_lcd_rgb_panel_restart(rgbpanel->_panel_handle);
    Serial.printf("[Panel] Init-Sequenz erneut geschickt (%lu ms)\n", millis() - t0);
    draw_page();
}

static void seq_start()
{
    page = PAGE_DRIFT;
    draw_page();
    seq_active = true;
    seq_total_start = millis();
    Serial.println("[Test] Lasttest gestartet");
    seq_enter(0);
}

// Tippen heisst jetzt: Stoerung melden UND sofort die Synchronisation neu
// ziehen. So zeigt sich unmittelbar, ob der Restart das Bild heilt.
static void seq_mark()
{
    Serial.printf("[Markierung] %lus %s -> Restart\n",
                  (unsigned long)(millis() / 1000),
                  seq_active ? SEQ[seq_idx].name : "Laufzeit");
    gfx->fillCircle(452, 88, 10, C_ACCENT);
    panel_restart();
}

static void seq_tick()
{
    if (!seq_active) return;
    unsigned long now = millis();

    if (seq_idx == 2) {  // WLAN-Scans nacheinander, damit die Last anliegt
        int found = WiFi.scanComplete();
        if (found >= 0) {
            Serial.printf("[WLAN] %d Netze\n", found);
            WiFi.scanDelete();
            WiFi.scanNetworks(true);
        }
    }

    if (seq_periodic_restart && now - seq_last_restart >= 2000) {
        seq_last_restart = now;
        esp_lcd_rgb_panel_restart(rgbpanel->_panel_handle);
        if (++seq_restart_count % 5 == 0) {
            Serial.printf("[Panel] %u automatische Restarts\n", seq_restart_count);
        }
    }

    if (SEQ[seq_idx].secs > 0 && now - seq_phase_start >= (unsigned long)SEQ[seq_idx].secs * 1000) {
        seq_enter(seq_idx + 1);
    } else if (now - seq_last_draw >= 1000) {
        seq_last_draw = now;
        seq_draw();
    }
}

// ============================================================
// Serielle Befehle
// ============================================================
static void print_info()
{
    Serial.println("----------------------------------------");
    Serial.printf("Chip: %s Rev %d, %d Kerne\n", ESP.getChipModel(), ESP.getChipRevision(), ESP.getChipCores());
    Serial.printf("Flash: %u MB\n", (unsigned)(ESP.getFlashChipSize() / (1024 * 1024)));
    Serial.printf("PSRAM: %u KB gesamt, %u KB frei\n",
                  (unsigned)(ESP.getPsramSize() / 1024), (unsigned)(ESP.getFreePsram() / 1024));
    Serial.printf("Heap intern: %u KB frei\n", (unsigned)(ESP.getFreeHeap() / 1024));
    Serial.printf("Arduino-Core %d.%d.%d, ESP-IDF %s\n",
                  ESP_ARDUINO_VERSION_MAJOR, ESP_ARDUINO_VERSION_MINOR, ESP_ARDUINO_VERSION_PATCH,
                  esp_get_idf_version());
    Serial.printf("Bounce Buffer: %d px, PCLK: %d Hz\n", BOUNCE_BUFFER_PX, PCLK_HZ);
    Serial.printf("Backlight: %u%% bei %u Hz, NVS-Last: %s, WLAN: %s\n",
                  bl_pct, (unsigned)bl_freq_hz,
                  nvs_load_on ? "an" : "aus",
                  WiFi.getMode() == WIFI_MODE_NULL ? "aus" : "an");
    Serial.printf("CPU: %u MHz, WLAN-Sleep: %s\n",
                  (unsigned)getCpuFrequencyMhz(),
                  WiFi.getSleep() ? "an" : "aus");
    Serial.printf("Letzter Reset: %d (1=POWERON 3=SW 5=DEEPSLEEP 6=BROWNOUT 7=WDT)\n",
                  (int)esp_reset_reason());
    Serial.println("----------------------------------------");
}

static char cmd_buf[32];
static size_t cmd_len = 0;
static bool wifi_scanning = false;

static void handle_command(const char *cmd)
{
    switch (cmd[0]) {
        case 'b': {
            int pct = atoi(cmd + 1);
            backlight_set((uint8_t)constrain(pct, 0, 100));
            Serial.printf("[BL] %u%%\n", bl_pct);
            if (page == PAGE_TOUCH) draw_brightness_strip();
            break;
        }
        case 'f': {
            long hz = atol(cmd + 1);
            if (hz < 50 || hz > 40000) {
                Serial.println("[BL] Frequenz 50..40000 Hz");
                break;
            }
            bl_freq_hz = (uint32_t)hz;
            ledcChangeFrequency(PIN_BL, bl_freq_hz, BL_RES_BITS);
            backlight_set(bl_pct);
            Serial.printf("[BL] PWM %u Hz\n", (unsigned)bl_freq_hz);
            break;
        }
        case 'p':
            next_page();
            break;
        case 'n':
            nvs_load_on = !nvs_load_on;
            Serial.printf("[NVS] Schreiblast %s (bisher %lu Schreibzugriffe)\n",
                          nvs_load_on ? "an" : "aus", (unsigned long)nvs_writes);
            break;
        case 'x':
            panel_restart();
            break;
        case 'g':
            panel_reinit();
            break;
        case 'r':
            burst_on = !burst_on;
            nvs_load_on = false;
            last_burst_ms = millis() - 14000;  // erster Stoss nach 1 s
            Serial.printf("[Stoss] Stossbetrieb %s\n", burst_on ? "an" : "aus");
            break;
        case 't':
            seq_start();
            break;
        case 'd':
            WiFi.disconnect(true, true);
            WiFi.mode(WIFI_OFF);
            Serial.println("[WLAN] aus");
            break;
        case 'e':
            // WLAN an, aber ohne Stromsparmodus: der schaltet sonst staendig
            // Takt und Funkteil um, was den Pixeltakt stoert.
            WiFi.mode(WIFI_STA);
            WiFi.setSleep(false);
            Serial.println("[WLAN] an, Stromsparmodus aus");
            break;
        case 'c': {
            int mhz = atoi(cmd + 1);
            if (mhz != 80 && mhz != 160 && mhz != 240) {
                Serial.println("[CPU] nur 80, 160 oder 240 MHz");
                break;
            }
            setCpuFrequencyMhz(mhz);
            Serial.printf("[CPU] %d MHz\n", getCpuFrequencyMhz());
            break;
        }
        case 'w':
            if (!wifi_scanning) {
                WiFi.mode(WIFI_STA);
                WiFi.scanNetworks(true);
                wifi_scanning = true;
                Serial.println("[WLAN] Scan gestartet");
            }
            break;
        case 'i':
            print_info();
            break;
        default:
            Serial.println("Befehle: b<0..100> Helligkeit | f<hz> PWM | p Seite | t Lasttest | n NVS-Last | w WLAN-Scan | d WLAN aus | x Panel-Restart | i Infos");
            break;
    }
}

static void serial_tick()
{
    while (Serial.available()) {
        char c = (char)Serial.read();
        if (c == '\n' || c == '\r') {
            if (cmd_len > 0) {
                cmd_buf[cmd_len] = '\0';
                handle_command(cmd_buf);
                cmd_len = 0;
            }
        } else if (cmd_len < sizeof(cmd_buf) - 1) {
            cmd_buf[cmd_len++] = c;
        }
    }

    if (wifi_scanning) {
        int n = WiFi.scanComplete();
        if (n >= 0) {
            Serial.printf("[WLAN] %d Netze gefunden\n", n);
            WiFi.scanDelete();
            wifi_scanning = false;
        } else if (n == WIFI_SCAN_FAILED) {
            Serial.println("[WLAN] Scan fehlgeschlagen");
            wifi_scanning = false;
        }
    }
}

// ============================================================
// Setup / Loop
// ============================================================
void setup()
{
    Serial.begin(115200);
    delay(300);
    Serial.println();
    Serial.println("Hardware-Test ESP32-S3-4848S040");

    // Backlight aus, bis das Panel initialisiert ist — kein Pixelmuell beim Start.
    ledcAttach(PIN_BL, bl_freq_hz, BL_RES_BITS);
    ledcWrite(PIN_BL, 0);

    print_info();
    if (!psramFound()) {
        Serial.println("[FEHLER] Kein PSRAM gefunden — Framebuffer kann nicht angelegt werden");
    }

    if (!gfx->begin()) {
        Serial.println("[FEHLER] gfx->begin() fehlgeschlagen");
    } else {
        Serial.println("[Display] ST7701S initialisiert");
    }
    Serial.printf("[System] PSRAM frei nach Framebuffer: %u KB\n", (unsigned)(ESP.getFreePsram() / 1024));

    esp_lcd_rgb_panel_event_callbacks_t cbs = {};
    cbs.on_vsync = on_vsync;
    esp_err_t cb_err = esp_lcd_rgb_panel_register_event_callbacks(rgbpanel->_panel_handle, &cbs, nullptr);
    Serial.printf("[Panel] Bildanfang-Meldung: %s, Nennwert %lld us pro Bild\n",
                  esp_err_to_name(cb_err), FRAME_US_NOMINAL);

    gt_init();
    prefs.begin("hwtest", false);

    draw_page();
    backlight_set(bl_pct);
    Serial.println("Bereit. Befehle: t Lasttest | b<0..100> f<hz> p n w d x i");
}

void loop()
{
    static unsigned long last_touch_ms = 0;
    static bool was_down = false;

    serial_tick();

    unsigned long now = millis();
    if (now - last_touch_ms >= 20) {
        last_touch_ms = now;
        gt_poll();

        if (touch_down) {
            bool on_button = touch_x >= BTN_X && touch_x < BTN_X + BTN_W &&
                             touch_y >= BTN_Y && touch_y < BTN_Y + BTN_H;
            if (!was_down) {
                Serial.printf("[Touch] x=%d y=%d\n", touch_x, touch_y);
            }
            if (!was_down && on_button) {
                next_page();
            } else if (page == PAGE_DRIFT && !on_button && !was_down) {
                seq_mark();
            } else if (page == PAGE_TOUCH && !on_button) {
                if (touch_y >= STRIP_Y && touch_y < STRIP_Y + STRIP_H) {
                    int32_t pct = (int32_t)(touch_x - STRIP_X) * 100 / STRIP_W;
                    backlight_set((uint8_t)constrain(pct, 5, 100));
                    draw_brightness_strip();
                } else if (touch_y >= 62 && touch_y < 388) {
                    gfx->fillCircle(touch_x, touch_y, 5, C_ACCENT);
                    gfx->setTextSize(2);
                    gfx->setTextColor(C_WHITE, C_BLACK);
                    gfx->setCursor(200, 24);
                    gfx->printf("%3d,%3d ", touch_x, touch_y);
                }
            }
        }
        was_down = touch_down;
    }

    // Lagebericht alle 10 s: Bildrate, Aussetzer, laengster Bildabstand
    static unsigned long last_report_ms = 0;
    static uint32_t last_frames = 0, last_glitches = 0;
    if (millis() - last_report_ms >= 10000) {
        unsigned long span = millis() - last_report_ms;
        last_report_ms = millis();
        uint32_t f = vsync_frames, g = vsync_glitches;
        Serial.printf("[Bild] %.1f Bilder/s | Aussetzer: %lu neu, %lu gesamt | laengster Abstand %.1f ms (Nennwert %.1f ms)\n",
                      (f - last_frames) * 1000.0 / (double)span,
                      (unsigned long)(g - last_glitches), (unsigned long)g,
                      vsync_worst_us / 1000.0, FRAME_US_NOMINAL / 1000.0);
        last_frames = f;
        last_glitches = g;
    }

    nvs_tick();
    burst_tick();
    seq_tick();
    if (page == PAGE_DRIFT) {
        drift_tick();
    }

    delay(2);
}
