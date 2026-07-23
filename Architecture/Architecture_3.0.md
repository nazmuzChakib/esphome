# ESPHome Architecture v3.0 — Connection-First, Security-First

> [!NOTE]
> **সংস্করণ:** v3.0 | **তারিখ:** 2026-07-23
> এই ডকুমেন্টটি v2.1 এর আর্কাইভের পরে নতুনভাবে তৈরি। পূর্ববর্তী ডকুমেন্ট `Architecture/.archive/Architecture_2.1.md` এ সংরক্ষিত।
>
> **মূল পরিবর্তন:** "Firmware-First" থেকে "Connection-First" প্যারাডাইমে shift। প্রথম দিনেই real encrypted WebSocket round-trip verify করা হবে। Dummy data নিষিদ্ধ।

> [!IMPORTANT]
> **Open Question Resolutions (2026-07-23):**
> - **api_key provisioning:** Serial command (`WIFI:SET_API_KEY:<key>`) দিয়ে set করা হবে। না করলে `/system.json`-এর default key ব্যবহার হবে।
> - **MQTT Credentials:** Dev environment এ সবার জন্য shared একই credentials থাকবে। Per-device rotation পরে।
> - **Branch Strategy:** Phase 0 fresh Git branch এ করা হবে (`feature/v3-connection-first`)।
> - **MQTT Timing:** MQTT (HiveMQ) Phase 3-এ। Phase 0–2 শুধুমাত্র WebSocket + HTTP fallback।
> - **Sensors:** BME280 (I2C) + MQ2 (Gas) — I2C sensors প্রাধান্য পাবে। আরও sensor পরে যুক্ত হবে।

---

## ১. Dual-Core Task Allocation (অপরিবর্তিত v2.1 থেকে)

### Core 0 — Network Stack
- WiFi Manager, TCP/IP Stack, AsyncWebServer background thread
- WebSocket connection handling
- MQTT Client Task (HiveMQ) — Phase 3 থেকে active

### Core 1 — Application Core
- Central Event Bus, Physical Switch ISR, Sensor Task
- Dynamic Rule Engine, Crypto Operations (HMAC/AES)
- Flash Write Task

### FreeRTOS Priority Matrix

| Priority | Task | Core | কাজ |
|:---:|:---|:---:|:---|
| 1 (Highest) | Switch ISR / Debounce | Core 1 | Physical switch interrupt |
| 2 (High) | Master Coordinator | Core 1 | Event queue processing |
| 3 (Medium) | Sensor & Rule Engine | Core 1 | BME280/MQ2 read + rule eval |
| 3 (Medium) | MQTT Task | Core 1 | HiveMQ pub/sub (Phase 3+) |
| 4 (Low) | Delayed Flash Save | Core 1 | LittleFS write coalescing |

---

## ২. Security Layer (v3.0 — EtM যোগ করা হয়েছে)

> [!IMPORTANT]
> **v3.0 Security Upgrade (2026-07-23):** AES-CBC একা unauthenticated — ciphertext bit-flip করে JSON payload predictable ভাবে modify করা সম্ভব (CBC bit-flipping attack)। যেহেতু relay ও gas alarm কন্ট্রোল করা হচ্ছে, এটা critical। **Encrypt-then-MAC (EtM)** pattern বাধ্যতামূলক করা হয়েছে।

### স্তর ১ — Key Derivation (Two Keys from One KDF)

একটিমাত্র HMAC call থেকে দুটি আলাদা key derive করা হবে — key reuse এড়াতে:

```
K_enc = HMAC-SHA256(api_key, timestamp_string)[:16]   → AES-128 Encryption Key
K_mac = HMAC-SHA256(api_key, timestamp_string)[16:32]  → HMAC-SHA256 MAC Key
```

> `mbedtls_md_hmac()` একটিমাত্র call এ 32-byte output দেয়। প্রথম 16 byte → K_enc, শেষ 16 byte → K_mac। কোনো extra HMAC call দরকার নেই।

- `api_key` কখনো wire এ যাবে না
- ±30 second replay protection window
- NTP sync mandatory on boot

### স্তর ২ — Encrypt-then-MAC (EtM) Protocol

**Encryption Flow:**
```
1. random_iv  = esp_random() × 16 bytes (TRNG)
2. ciphertext = AES-128-CBC(K_enc, random_iv, PKCS7_pad(plaintext))
3. mac        = HMAC-SHA256(K_mac, iv || ciphertext)[:16]   ← MAC over IV+Ciphertext
4. packet     = Base64(iv[16] || ciphertext[N] || mac[16])
```

**Decryption + Verification Flow:**
```
1. raw       = Base64_decode(packet)
2. iv        = raw[0:16]
3. ciphertext= raw[16 : len-16]
4. mac_recv  = raw[len-16 : len]
5. mac_calc  = HMAC-SHA256(K_mac, iv || ciphertext)[:16]
6. if mac_calc ≠ mac_recv → REJECT (return error, no decryption attempted)
7. plaintext = AES-128-CBC_decrypt(K_enc, iv, ciphertext)
```

> [!WARNING]
> MAC মেলানো **সবার আগে** করতে হবে, decrypt এর আগে নয়। এটাই EtM এর মূল নিরাপত্তা: decryption oracle হওয়ার সুযোগ নেই। MAC mismatch → `403 Forbidden` return, padding oracle attack অসম্ভব।

**Updated Packet / Frame Format:**

| ক্ষেত্র | পুরনো (v2.1) | নতুন (v3.0) |
|:---|:---|:---|
| Packet | `Base64(IV[16] \| Ciphertext[N])` | `Base64(IV[16] \| Ciphertext[N] \| MAC[16])` |
| WS Frame | `[Timestamp]:[Base64]` | `[Timestamp]:[Base64]` (unchanged, payload longer) |
| Min packet size | 32 bytes decoded | 48 bytes decoded |
| MAC coverage | নেই | IV + Ciphertext উভয়ই |

### Firmware Implementation (CryptoHelper)

**ফাইল:** `src/Security/CryptoHelper.h/.cpp`

```cpp
// Key derivation — একটি HMAC call, দুটি key
bool CryptoHelper::deriveKeys(const String& timestamp,
                               uint8_t k_enc[16], uint8_t k_mac[16]) {
    uint8_t fullHmac[32];
    // mbedtls_md_hmac returns 32 bytes for SHA256
    const mbedtls_md_info_t* md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(md,
        (const uint8_t*)_apiKey.c_str(), _apiKey.length(),
        (const uint8_t*)timestamp.c_str(), timestamp.length(),
        fullHmac);
    memcpy(k_enc, fullHmac,      16); // First  16 bytes → AES key
    memcpy(k_mac, fullHmac + 16, 16); // Second 16 bytes → MAC key
    return true;
}

// Encrypt-then-MAC
String CryptoHelper::encryptAndMac(const String& plaintext,
                                    const uint8_t k_enc[16],
                                    const uint8_t k_mac[16]) {
    // 1. Random IV
    uint8_t iv[16];
    esp_fill_random(iv, 16);

    // 2. PKCS7 pad + AES-CBC encrypt
    // ... (existing AES logic) ...
    // uint8_t* ciphertext; size_t cipherLen;

    // 3. MAC = HMAC-SHA256(k_mac, iv || ciphertext)[:16]
    uint8_t macBuf[32];
    // compute HMAC over iv+ciphertext concatenated
    // ...

    // 4. Pack: iv[16] || ciphertext[N] || mac[16]
    // Base64 encode and return
}

// Verify-then-Decrypt
bool CryptoHelper::verifyAndDecrypt(const String& base64Packet,
                                     const uint8_t k_enc[16],
                                     const uint8_t k_mac[16],
                                     String& outPlaintext) {
    // 1. Base64 decode
    // 2. Extract: iv, ciphertext, mac_recv
    // 3. Compute mac_calc = HMAC-SHA256(k_mac, iv||ciphertext)[:16]
    // 4. Constant-time compare: if mismatch → return false (DO NOT DECRYPT)
    // 5. AES-CBC decrypt → outPlaintext
    return true;
}
```

### App Implementation (NodeSecurityService)

**ফাইল:** `frontend/lib/core/security/node_security_service.dart`

```dart
// Key derivation — same logic as firmware
static (List<int> kEnc, List<int> kMac) deriveKeys(String apiKey, String timestamp) {
  final keyBytes = utf8.encode(apiKey);
  final msgBytes = utf8.encode(timestamp);
  final hmac = Hmac(sha256, keyBytes);
  final digest = hmac.convert(msgBytes).bytes; // 32 bytes
  return (digest.sublist(0, 16), digest.sublist(16, 32));
}

// Encrypt-then-MAC
static String encryptAndMac(String plaintext, List<int> kEnc, List<int> kMac) {
  final key = encrypt.Key(Uint8List.fromList(kEnc));
  final ivBytes = Uint8List(16);
  Random.secure().nextBytes(ivBytes); // random IV
  final iv = encrypt.IV(ivBytes);

  final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'));
  final encrypted = encrypter.encrypt(plaintext, iv: iv);

  // MAC = HMAC-SHA256(kMac, iv || ciphertext)[:16]
  final macInput = Uint8List(16 + encrypted.bytes.length)
    ..setRange(0, 16, ivBytes)
    ..setRange(16, 16 + encrypted.bytes.length, encrypted.bytes);
  final mac = Hmac(sha256, kMac).convert(macInput).bytes.sublist(0, 16);

  // Pack: iv[16] || ciphertext[N] || mac[16]
  final combined = Uint8List(16 + encrypted.bytes.length + 16)
    ..setRange(0, 16, ivBytes)
    ..setRange(16, 16 + encrypted.bytes.length, encrypted.bytes)
    ..setRange(16 + encrypted.bytes.length, combined.length, mac);

  return base64.encode(combined);
}

// Verify-then-Decrypt
static String? verifyAndDecrypt(String base64Packet, List<int> kEnc, List<int> kMac) {
  final raw = base64.decode(base64Packet);
  if (raw.length < 48) return null; // IV(16) + min cipher(16) + MAC(16)

  final ivBytes   = raw.sublist(0, 16);
  final cipherBytes = raw.sublist(16, raw.length - 16);
  final macRecv   = raw.sublist(raw.length - 16);

  // Verify MAC first — before any decryption
  final macInput = Uint8List(16 + cipherBytes.length)
    ..setRange(0, 16, ivBytes)
    ..setRange(16, macInput.length, cipherBytes);
  final macCalc = Hmac(sha256, kMac).convert(macInput).bytes.sublist(0, 16);

  // Constant-time comparison
  if (!_constantTimeEqual(macCalc, macRecv)) return null; // MAC mismatch

  // Decrypt only after MAC verified
  final key = encrypt.Key(Uint8List.fromList(kEnc));
  final iv  = encrypt.IV(Uint8List.fromList(ivBytes));
  final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'));
  return encrypter.decrypt(encrypt.Encrypted(cipherBytes), iv: iv);
}

static bool _constantTimeEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff == 0; // timing-safe compare
}
```

### api_key Provisioning (v3.0)
```
Serial Command: WIFI:SET_API_KEY:<your_key>
Response: [SYS] API key updated and saved to /system.json

Fallback: যদি কোনো key set না থাকে, /system.json এর default_api_key ব্যবহার হবে।
```

---

## ৩. Memory Management ও Safety Standards (Firmware-Wide, v3.0)

> [!CAUTION]
> এই section এর প্রতিটি rule বাধ্যতামূলক। যেকোনো ফার্মওয়্যার কোডে লেখা কোড এই rules follow করে না লিখলে reject করতে হবে। ESP32 এ 512KB SRAM — প্রতিটি byte হিসাব রাখতে হবে।

### ৩.১ — String ক্লাস সম্পূর্ণ নিষিদ্ধ (Arduino String Banned)

Arduino `String` class heap fragmentation এর সবচেয়ে বড় কারণ। প্রতিটি `+` concat একটি temporary heap allocation করে যা প্রায়ই leak বা fragment হয়ে যায়।

```cpp
// BANNED (নিষিদ্ধ):
String msg = "Node: " + nodeName + " online";  // heap alloc + fragmentation
String result = CryptoHelper::encrypt(payload);  // returns String = heap

// CORRECT (বাধ্যতামূলক):
char msg[64];
snprintf(msg, sizeof(msg), "Node: %s online", nodeName); // stack-allocated

// ফাংশন signatures:
// BANNED:  String encryptAndMac(const String& plaintext, ...)
// CORRECT: bool encryptAndMac(const char* plaintext, size_t plaintextLen,
//                              char* outBase64, size_t outBase64Size, ...);
```

**প্রতিটি String-returning function হয় হয়:**
- Caller-provided `char*` buffer + `size_t bufSize` parameter ব্যবহার করুন
- Return type: `bool` (success/fail) অথবা `int` (bytes written, -1 on error)
- `snprintf()` দিয়ে লেখুন, শেষে `\0` নিশ্চিত হয়
- `strlcpy()` / `strlcat()` ব্যান: শুধু `strncpy(dst, src, sizeof(dst)-1); dst[sizeof(dst)-1]='\0';`

**Allowed Types:**
```cpp
const char*   // string literal (PROGMEM or .rodata)
char[]        // stack-allocated fixed buffer
char*         // caller-provided buffer
uint8_t[]     // binary buffers
```

---

### ৩.২ — F() Macro — সব ধরনের Serial.print এ বাধ্যতামূলক

String literal সরাসরি RAM এ থাকে — F() macro Flash এ (PROGMEM) রাখে। প্রতি স্ট্রিং লিটারাল থেকে ২–৫0 byte RAM বাঁচে।

```cpp
// BANNED:
Serial.println("[NET] WiFi connected");          // RAM cost!
Serial.print("[BOOT] StorageManager OK");        // RAM cost!

// CORRECT:
Serial.println(F("[NET] WiFi connected"));        // PROGMEM
Serial.print(F("[BOOT] StorageManager OK"));      // PROGMEM

// Dynamic values এ printf-style:
Serial.printf_P(PSTR("[HEAP] Free: %lu bytes\n"), ESP.getFreeHeap());
Serial.printf_P(PSTR("[BOOT] MAC: %s IP: %s\n"), macStr, ipStr);

// snprintf + F-style static print:
char buf[80];
snprintf_P(buf, sizeof(buf), PSTR("[CRYPTO] K_enc derived at ts=%lu"), ts);
Serial.println(buf);
```

**Rule:** নিচের কোনটিই কোনো literal string directly pass করা যাবে না:
- `Serial.print("...")` → সবসময় `Serial.print(F("..."))` বা `Serial.print_P(PSTR("..."))`
- `log("...")` custom function → `log_P(PSTR("..."))` version রাখতে হবে

---

### ৩.৩ — Fixed Buffer Definitions (No Dynamic Alloc)

সব বাফার **static** অথবা **stack** এ, heap থেকে নয়। overflow হলে buffer এর মধ্যেই থাকে (ring buffer pattern), বাইরে যায় না।

#### Log Ring Buffer
```cpp
// src/Core/Logger.h
#define LOG_RING_SIZE     512    // মোট ring buffer size (bytes)
#define LOG_ENTRY_MAX_LEN  80    // একটি entry র max length

struct Logger {
private:
    char     _ring[LOG_RING_SIZE];
    uint16_t _head = 0; // write pointer
    uint16_t _tail = 0; // read pointer
    bool     _full = false;

public:
    // নতুন log entry write — overflow হলে oldest entry ওভাররাইট (drop-oldest)
    void log_P(const char* fmt_P, ...);
    // USB Serial ও (optionally) WebSocket log push
    void flush();
};
```

**Buffer Overflow Rule:** Ring buffer full হলে oldest entry overwrite (নতুন data lose নয়)। Overwrite count `crash_logs.json` এ counter হিসেবে track করা হবে।

#### Sensor History Buffer (Ring)
```cpp
// src/Core/SensorTask.h
#define SENSOR_HISTORY_SIZE  12  // 12 samples = 2 minutes at 10s interval

struct SensorSample {
    uint32_t timestamp;   // Unix epoch (4 bytes)
    int16_t  tempX100;    // temperature * 100 (e.g., 2850 = 28.50C)  (2 bytes)
    uint16_t humX100;     // humidity * 100                            (2 bytes)
    uint16_t pressX10;    // pressure * 10 (hPa)                       (2 bytes)
    uint16_t gasRaw;      // MQ2 raw ADC 0-4095                        (2 bytes)
};                        // Total: 12 bytes per sample
// Total buffer: 12 * 12 = 144 bytes (stack-allocated)

static SensorSample sensorHistory[SENSOR_HISTORY_SIZE]; // static, global scope
static uint8_t      sensorHistoryIdx = 0;               // ring write head

// Write new sample (ring, overflow = overwrite oldest):
void pushSensorSample(const SensorSample& s) {
    sensorHistory[sensorHistoryIdx] = s;
    sensorHistoryIdx = (sensorHistoryIdx + 1) % SENSOR_HISTORY_SIZE;
}
```

> integer-scale encoding (`int16_t tempX100`) ব্যবহার করা হয়েছে float (4 bytes) এর বদলে। দুটি byte per field বাঁচে।

#### WebSocket Receive Buffer
```cpp
// src/Network/AppNetworkManager.h
#define WS_RX_BUF_SIZE   512   // max incoming WS frame size
// Frame format: [Timestamp]:[Base64(IV+CT+MAC)] — typ. 100-350 bytes
// 512 gives safe headroom

static char wsRxBuf[WS_RX_BUF_SIZE];
// In WS onData callback:
void onWsData(AsyncWebSocketClient* client, uint8_t* data, size_t len) {
    if (len >= WS_RX_BUF_SIZE) {
        Serial.println(F("[WS] Frame too large, dropped"));
        return; // overflow guard
    }
    memcpy(wsRxBuf, data, len);
    wsRxBuf[len] = '\0'; // null-terminate
    // post to EventBus...
}
```

#### Crypto Working Buffer
```cpp
// src/Security/CryptoHelper.h
// AES output হলে PKCS7 padding যুক্ত, max payload + 16 bytes
#define CRYPTO_PLAINTEXT_MAX   384  // max plaintext input (bytes)
#define CRYPTO_CIPHERTEXT_MAX  400  // PKCS7 padded output
#define CRYPTO_BASE64_OUT_MAX  560  // Base64(IV[16]+CT[400]+MAC[16]) ≈ 576 chars
// Note: Base64 overhead = ceil(raw_bytes * 4/3)

// All working buffers static to CryptoHelper instance:
static uint8_t _ivBuf[16];
static uint8_t _cipherBuf[CRYPTO_CIPHERTEXT_MAX];
static uint8_t _macBuf[32];
static char    _base64Out[CRYPTO_BASE64_OUT_MAX];
```

---

### ৩.৪ — Real-Time Heap Monitoring Task

```cpp
// src/Core/TaskManager.cpp এ HeapMonitor task
#define HEAP_WARN_THRESHOLD      30000U  // 30KB — warning log
#define HEAP_LATCH_THRESHOLD     25000U  // 25KB — MQTT/cloud publish disable
#define HEAP_CRITICAL_THRESHOLD  15000U  // 15KB — restart warning, core dump
#define HEAP_RECOVER_THRESHOLD   32000U  // 32KB — latch release
#define HEAP_MONITOR_INTERVAL_MS 10000   // check every 10 seconds

// Global flag (volatile, read by MqttManager, Logger)
volatile bool g_heapLatchActive = false;

void heapMonitorTask(void* pvParams) {
    uint32_t minFreeEver = UINT32_MAX;

    for (;;) {
        const uint32_t freeHeap  = ESP.getFreeHeap();
        const uint32_t maxAlloc  = ESP.getMaxAllocHeap();
        const uint32_t minFree   = ESP.getMinFreeHeap();

        // Track all-time minimum
        if (minFree < minFreeEver) minFreeEver = minFree;

        // Print periodic health status
        Serial.printf_P(PSTR("[HEAP] free=%lu maxAlloc=%lu minEver=%lu latch=%d\n"),
                         freeHeap, maxAlloc, minFreeEver,
                         (int)g_heapLatchActive);

        if (freeHeap < HEAP_CRITICAL_THRESHOLD) {
            Serial.println(F("[HEAP] CRITICAL — restarting in 3s"));
            // Try to flush crash log before restart
            StorageManager::getInstance().appendCrashLog(F("heap_critical"));
            vTaskDelay(pdMS_TO_TICKS(3000));
            esp_restart();

        } else if (freeHeap < HEAP_LATCH_THRESHOLD) {
            if (!g_heapLatchActive) {
                g_heapLatchActive = true;
                Serial.println(F("[HEAP] LATCH ON — cloud publish suspended"));
            }

        } else if (freeHeap > HEAP_RECOVER_THRESHOLD && g_heapLatchActive) {
            g_heapLatchActive = false;
            Serial.println(F("[HEAP] LATCH OFF — cloud publish resumed"));
        }

        vTaskDelay(pdMS_TO_TICKS(HEAP_MONITOR_INTERVAL_MS));
    }
}
```

**Heap Monitor এর Priority ও Stack:**
```cpp
// TaskManager.cpp এ:
xTaskCreatePinnedToCore(
    heapMonitorTask,
    "HeapMon",
    1024,          // 1KB stack — only logging, no heavy work
    NULL,
    1,             // Low priority (below everything)
    &heapMonitorHandle,
    1              // Core 1
);
```

---

### ৩.৫ — Task Stack Size Guidelines

| Task | Stack Size | Core | যুক্তি |
|:---|:---|:---|:---|
| Master Coordinator | 4096 | 1 | JSON parse + crypto decode |
| SensorTask | 2048 | 1 | I2C read + ADC, no JSON |
| HeapMonitor | 1024 | 1 | Only printf, no alloc |
| SwitchHandler ISR | N/A (IRAM) | 1 | `IRAM_ATTR`, no stack alloc |
| AppNetworkManager | 4096 | 0 | WiFi + WS + HTTP handling |
| MqttManager (Phase 3) | 6144 | 1 | TLS overhead needs extra |

ফার্মওয়্যার প্রতি release রুন করার আগে `uxTaskGetStackHighWaterMark()` দিয়ে প্রতি task এর হাইওয়াটারমার্ক log করুন এবং stack আরো optimize করুন।

---

### ৩.৬ — Memory Budget (Static Allocation Map)

| Region | Allocation | Size | কোথায় |
|:---|:---|:---|:---|
| EventBus Pool | Static | `16 × sizeof(AppEvent)` ≈ 256B | `EventBus.cpp` |
| Log Ring Buffer | Static | 512B | `Logger.cpp` |
| Sensor History | Static | `12 × 12` = 144B | `SensorTask.cpp` |
| WS Receive Buffer | Static | 512B | `AppNetworkManager.cpp` |
| Crypto Working Bufs | Static | ~1KB | `CryptoHelper.cpp` |
| JSON Scratch Buffer | Stack (temp) | 256B | Coordinator task stack |
| **মোট Static** | | **প্রায় 2.5KB** | |

> [!TIP]
> রানটাইম heap alloc শুধুমাত্র `mbedtls` internal buffers ও WebServer response এর জন্য। এগুলো `MALLOC_CAP_INTERNAL` থেকে `heap_caps_malloc()` দিয়ে নিতে হবে, সাধারণ `malloc()` নয়।

---

## ৪. Sensor Integration (v3.0 নতুন)


### সক্রিয় Sensors
| Sensor | Protocol | Data | Phase |
|:---|:---|:---|:---|
| BME280 | I2C (SDA/SCL) | Temperature, Humidity, Pressure | Phase 3.4 |
| MQ2 | Analog (ADC) | Gas (LPG, Smoke, CO) | Phase 3.4 |

### BME280 I2C Config
```cpp
// Default I2C pins for ESP32:
// SDA: GPIO 21, SCL: GPIO 22
// I2C Address: 0x76 (default) or 0x77 (SDO pulled HIGH)
#include <Wire.h>
#include <Adafruit_BME280.h>
Adafruit_BME280 bme;
bme.begin(0x76, &Wire); // Init in SensorTask
```

### MQ2 Analog Config
```cpp
// ADC pin: GPIO 34 (input only pin, good for analog)
// Warm-up time: 20-30 seconds after power on
#define MQ2_PIN 34
int gasRaw = analogRead(MQ2_PIN); // 0–4095
float gasVoltage = gasRaw * (3.3 / 4095.0);
```

---

## ৫. MQTT Topic Architecture (অপরিবর্তিত v2.1 থেকে)

### Firmware (Node) Subscribe
```
ESPHome/nodes/[OWN_MAC]/commands/#
```

### Firmware (Node) Publish (Retain = true)
```
ESPHome/nodes/[MAC]/config          → Online status, IP, uptime, heap
ESPHome/nodes/[MAC]/loads/[id]      → Load pin/mode config
ESPHome/nodes/[MAC]/states/[id]     → Load ON/OFF state
ESPHome/nodes/[MAC]/sensors/temperature
ESPHome/nodes/[MAC]/sensors/humidity
ESPHome/nodes/[MAC]/sensors/pressure
ESPHome/nodes/[MAC]/sensors/gas
ESPHome/nodes/[MAC]/logs            → Encrypted log messages
```

### App Subscribe
```
ESPHome/nodes/+/config
ESPHome/nodes/+/loads/#
ESPHome/nodes/+/states/#
ESPHome/nodes/+/sensors/#
```

### MQTT Credentials & Connection Registry
```
Broker Host: 494f4376e75a419193b3ddbd54f2338d.s1.eu.hivemq.cloud
Port:        8883 (TLS / MQTTS)
Username:    @esp_home
Password:    password@esp_Home
CA Cert:     ISRG Root X1 (embedded in StorageManager.cpp system.json init)
Client ID:   ESPHome_[OWN_MAC] (unique per device)
```

---

## ৬. Connection Fallback Pipeline

```
WebSocket (Local Primary, <2ms latency)
    ↓ fail
HTTP POST /api/set-state (Local Secondary)
    ↓ fail  [Phase 3 থেকে]
MQTT via HiveMQ (Cloud Fallback)
    ↓ fail
Offline Queue (Hive DB, auto-replay on reconnect)
```

---

## ৭. Phase-by-Phase Roadmap (v3.0)

---

### ═══ PHASE 0: Foundation Reset & Live Crypto Handshake ═══
**Branch:** `feature/v3-connection-first` (fresh branch)
**সময়:** ২–৩ দিন
**Exit Criteria:** Real hardware তে encrypted WS message round-trip verified

---

#### Sub-phase 0.1: Firmware Minimal Boot Skeleton

**লক্ষ্য:** ESP32 boot → WiFi connect → WebSocket listen। শুধু এটুকু।

##### 0.1.1 — `ESPHome.ino` Minimal Cleanup
**ফাইল:** `ESPHome.ino`
**পরিবর্তন:**
```cpp
// REMOVE: RuleEngine boot hooks
// REMOVE: SensorTask init (Phase 3 এ যাবে)
// REMOVE: MqttManager init (Phase 3 এ যাবে)
// REMOVE: stress test code (runEventBusStressTest)
// KEEP:   StorageManager::getInstance().begin()
// KEEP:   TaskManager::getInstance().begin()
// KEEP:   AppNetworkManager::getInstance().begin()
// KEEP:   CryptoHelper::getInstance().begin()
```

**Expected Serial Output:**
```
[BOOT] StorageManager OK
[BOOT] CryptoHelper OK — api_key loaded
[NET]  WiFi connecting...
[NET]  WiFi connected: 192.168.x.x
[NET]  NTP synced: 1719876543
[NET]  WebSocket server ready on :80/ws
[UDP]  Discovery beacon started (port 4210)
```

##### 0.1.2 — Serial Command: api_key Set
**ফাইল:** `src/Network/AppNetworkManager.cpp`
**পরিবর্তন:** `WIFI:` prefix handler এ নতুন command যোগ করা
```cpp
// EXISTING handler এ যোগ করুন:
else if (cmd.startsWith("SET_API_KEY:")) {
    String newKey = cmd.substring(12);
    newKey.trim();
    StorageManager::getInstance().setApiKey(newKey);
    Serial.println("[SYS] API key updated and saved to /system.json");
}
```
**ফাইল:** `src/Storage/StorageManager.h/.cpp`
**পরিবর্তন:** `setApiKey(String key)` method যোগ করা

##### 0.1.3 — Boot Verification Checklist (Serial Output)
**ফাইল:** `ESPHome.ino`
- `api_key` length print (শুধু length, content নয়)
- MAC address print
- Free heap print
- NTP sync status print

---

#### Sub-phase 0.2: App Minimal Connection Skeleton

**লক্ষ্য:** App → UDP discover node → WebSocket connect। UI পরে।

##### 0.2.1 — Debug Connection Screen
**ফাইল:** `frontend/lib/features/setup/` (new file)
```dart
// lib/features/setup/debug_connection_screen.dart
// একটি simple screen:
// - "Scan for Nodes" button → UdpDiscoveryService.startScan()
// - Found nodes list (MAC, IP)
// - "Connect" button → ConnectionManager.connect(ip)
// - Connection status text: "Connecting... / Connected / Failed"
// এটি production UI নয়, debug only screen
```

##### 0.2.2 — UdpDiscoveryService Verify
**ফাইল:** `frontend/lib/core/network/udp_discovery_service.dart`
**পরিবর্তন:** কোনো পরিবর্তন নেই, শুধু verify করতে হবে:
- Default api_key দিয়ে beacon decrypt হচ্ছে কিনা
- Extracted IP ও MAC সঠিক কিনা

##### 0.2.3 — ConnectionManager Verify
**ফাইল:** `frontend/lib/core/network/connection_manager.dart`
**পরিবর্তন:** কোনো পরিবর্তন নেই, শুধু verify:
- `connect(ip)` call করলে WebSocket session establish হচ্ছে কিনা
- Console output: connection state, latency

---

#### Sub-phase 0.3: ⭐ Crypto Handshake + EtM Verification (Critical Gate)

> [!IMPORTANT]
> এই sub-phase এ **Encrypt-then-MAC (EtM)** বাধ্যতামূলকভাবে implement ও verify করতে হবে। শুধু AES-CBC নয় — MAC verification ছাড়া Phase 1 শুরু করা যাবে না।

##### 0.3.0 — EtM Implementation (Firmware)
**ফাইল:** `src/Security/CryptoHelper.h/.cpp`
**পরিবর্তন:** নতুন method যোগ করুন:
```cpp
// OLD method (deprecated): encryptPayload(plaintext, k1[16]) — শুধু AES, কোনো MAC নেই
// NEW methods (mandatory):
bool deriveKeys(const String& timestamp, uint8_t k_enc[16], uint8_t k_mac[16]);
String encryptAndMac(const String& plaintext, const uint8_t k_enc[16], const uint8_t k_mac[16]);
bool verifyAndDecrypt(const String& base64Packet, const uint8_t k_enc[16],
                      const uint8_t k_mac[16], String& outPlaintext);
```
- `encryptAndMac`: IV(16) || Ciphertext(N) || MAC(16) → Base64
- `verifyAndDecrypt`: MAC check আগে, decrypt পরে — MAC mismatch → false, no decrypt
- `deriveKeys`: একটি HMAC-SHA256 call থেকে k_enc ([:16]) এবং k_mac ([16:32]) আলাদা করা

**ফাইল:** `src/Core/TaskManager.cpp` / Coordinator loop
**পরিবর্তন:** সমস্ত `encryptPayload()`/`decryptPayload()` call বদলে `encryptAndMac()`/`verifyAndDecrypt()` ব্যবহার করুন

##### 0.3.1 — EtM Implementation (App)
**ফাইল:** `frontend/lib/core/security/node_security_service.dart`
**পরিবর্তন:**
```dart
// OLD: encryptPayload(plaintext, kEnc) — AES only
// NEW:
static (List<int>, List<int>) deriveKeys(String apiKey, String timestamp)
static String encryptAndMac(String plaintext, List<int> kEnc, List<int> kMac)
static String? verifyAndDecrypt(String base64, List<int> kEnc, List<int> kMac)
static bool _constantTimeEqual(List<int> a, List<int> b) // timing-safe compare
```
- `verifyAndDecrypt` returns `null` on MAC mismatch (never decrypts tampered data)
- Constant-time compare: `int diff = 0; for i: diff |= a[i] ^ b[i]; return diff == 0`

**ফাইল:** `frontend/lib/core/network/connection_manager.dart`
**পরিবর্তন:** `_onMessage()` এ `decryptPayload()` → `verifyAndDecrypt()`, null check যোগ

##### 0.3.2 — Firmware Manual Crypto Test (Serial)
**ফাইল:** `ESPHome.ino`
**পরিবর্তন (temporary test code, `#if CRYPTO_LOOPBACK_TEST` guard):**
```cpp
#if CRYPTO_LOOPBACK_TEST
  Serial.println("\n--- EtM CRYPTO TEST ---");
  uint32_t ts = AppNetworkManager::getInstance().getUnixTimestamp();
  String tsStr = String(ts);

  uint8_t k_enc[16], k_mac[16];
  CryptoHelper::getInstance().deriveKeys(tsStr, k_enc, k_mac);

  String testPayload = "{\"action\":\"PING\",\"mac4\":\"ABCD\"}";
  String packet = CryptoHelper::getInstance().encryptAndMac(testPayload, k_enc, k_mac);

  Serial.print("[CRYPTO] Timestamp: "); Serial.println(tsStr);
  Serial.print("[CRYPTO] EtM Packet: "); Serial.println(packet);
  Serial.println("Packet = Base64(IV[16] || Ciphertext[N] || MAC[16])");
  Serial.println("--- COPY THE ABOVE AND PASTE INTO APP DECRYPT TEST ---");

  // Self-verify:
  String decrypted;
  bool ok = CryptoHelper::getInstance().verifyAndDecrypt(packet, k_enc, k_mac, decrypted);
  Serial.print("[CRYPTO] Self-verify: "); Serial.println(ok ? "PASS" : "FAIL");
  Serial.print("[CRYPTO] Decrypted:  "); Serial.println(decrypted);
#endif
```

##### 0.3.3 — App Side Decrypt Test (Debug Screen)
**ফাইল:** `frontend/lib/features/setup/debug_connection_screen.dart`
```dart
// Debug screen এ test widget:
// TextFormField: firmware EtM packet paste করুন
// TextFormField: timestamp input
// Button: "Verify & Decrypt"
// Output:
//   - "MAC OK — Decrypted: {action:PING,...}" → green
//   - "MAC MISMATCH — rejected" → red
// Expected success: {"action":"PING","mac4":"ABCD"}
```
**ফাইল:** `frontend/lib/core/security/node_security_service.dart`
**ব্যবহার:** `verifyAndDecrypt(packet, kEnc, kMac)` → null হলে tamper detected

##### 0.3.4 — Live EtM Round-Trip Test
**ফার্মওয়্যার → App → ফার্মওয়্যার:**
1. App `encryptAndMac(PING_JSON)` → WS send
2. Firmware `verifyAndDecrypt()` → MAC OK → process → Serial print
3. Firmware `encryptAndMac(PONG_JSON)` → WS send to app
4. App `verifyAndDecrypt()` → "PONG" display

**Success criteria:** Round-trip < 50ms, zero MAC failures, zero decryption errors

##### 0.3.5 — MAC Tamper Test (Mandatory)
```
Test A — Bit-flip attack:
  1. Firmware থেকে একটি valid EtM packet নিন
  2. Base64 decode করুন
  3. Ciphertext এর একটি byte manually flip করুন
  4. Re-encode করে App এ পাঠান
  5. Expected: verifyAndDecrypt() returns null — MAC mismatch
  6. NO decryption attempt, NO 200 OK

Test B — MAC strip attack:
  1. Valid packet থেকে শেষ 16 byte (MAC) কেটে দিন
  2. পাঠান
  3. Expected: packet too short → reject immediately

Test C — Replay test:
  1. একটি valid packet record করুন
  2. 31 seconds পরে পাঠান
  3. Expected: timestamp check → 401 Unauthorized (outer check, before MAC)
```

##### 0.3.6 — Timestamp Window + mac4 Tests
- 31s old timestamp → `401 Unauthorized`
- Wrong mac4 (after MAC verified) → `409 Conflict`

---

#### Sub-phase 0.4: UDP Discovery End-to-End

##### 0.4.1 — Beacon Format Verify
**ফাইল:** `src/Network/AppNetworkManager.cpp`
**Verify করুন:** UDP beacon payload:
```
Format: [Timestamp]:[Base64(IV||Cipher("ESPHOME_DISCOVERY:IP:MAC:UPTIME"))]
Port: 4210
Interval: 15s (no clients), 60s (clients connected)
```

##### 0.4.2 — App Auto-Connect Flow
**ফাইল:** `frontend/lib/core/network/udp_discovery_service.dart`
**পরিবর্তন:** `onNodeDiscovered` callback এ:
```dart
// Discovered node → automatically call ConnectionManager.connect(ip)
// Log: "Auto-connecting to [MAC] at [IP]..."
```

---

### ═══ PHASE 1: Firmware Core Integration Layer ═══
**সময়:** ৩–৪ দিন
**Pre-condition:** Phase 0 exit criteria সম্পন্ন

---

#### Sub-phase 1.1: EventBus → Coordinator Live Wiring

##### 1.1.1 — WebSocket Frame → EventBus
**ফাইল:** `src/Network/AppNetworkManager.cpp`
**Verify করুন:** WS text frame → `EventBus::getInstance().postEvent()` call হচ্ছে কিনা
**ফাইল:** `src/Core/TaskManager.cpp`
**Verify করুন:** Coordinator task `EventBus` থেকে event pop করে process করছে কিনা

##### 1.1.2 — HTTP POST Fallback
**ফাইল:** `src/Network/AppNetworkManager.cpp`
**Existing:** `/api/set-state` endpoint already আছে
**Verify:** HTTP POST → EventBus → Coordinator → GPIO change chain

##### 1.1.3 — Event Pool Stress Test
**ফাইল:** `ESPHome.ino`
```cpp
// Test: 30 rapid events fire করুন
// Expected: drop policy সঠিক কাজ করছে
// Expected: crash_logs.json এ drop count লগ হচ্ছে
```

##### 1.1.4 — Core 0 → Core 1 Latency Measurement
**ফাইল:** `src/Core/TaskManager.cpp`
```cpp
// Queue post timestamp vs process timestamp difference log করুন
// Target: < 5ms inter-core handoff
```

---

#### Sub-phase 1.2: HardwareManager + GPIO Control Live Test

##### 1.2.1 — Load Config Load from JSON
**ফাইল:** `src/Core/HardwareManager.cpp`
**Verify করুন:** `/loads.json` থেকে pin definitions load হচ্ছে কিনা boot এ
**Test:** Load add via app → `/loads.json` update → reboot → load সঠিকভাবে restore

##### 1.2.2 — App Command → GPIO Toggle
**App ফাইল:** `frontend/lib/core/network/connection_manager.dart`
**Firmware ফাইল:** `src/Core/HardwareManager.cpp`

**Command JSON format:**
```json
{
  "action": "TURN_ON",
  "load_id": "light1",
  "mac4": "ABCD"
}
```
**Expected flow:** App send → WS → EventBus → Coordinator → HardwareManager.setState() → GPIO HIGH

##### 1.2.3 — State Persistence Verify
**ফাইল:** `src/Storage/StorageManager.cpp`
- Load state change → 3-second coalesced write verify
- Power cycle → RTC_DATA_ATTR state restore verify

##### 1.2.4 — Delete Safety Check
**ফাইল:** `src/Core/HardwareManager.cpp`
**Rule (existing):** Active/ON load delete করতে গেলে block করুন
**Verify:** `canDeleteLoad()` → return false if load is ON

---

#### Sub-phase 1.3: SwitchHandler ISR → App Real-Time Sync

##### 1.3.1 — ISR Chain Verify
**ফাইল:** `src/Core/SwitchHandler.cpp`
Physical switch toggle → `xQueueSendFromISR()` → EventBus → Coordinator → GPIO change

##### 1.3.2 — Physical Switch → WebSocket Push → App UI
**ফাইল:** `src/Core/TaskManager.cpp` (Coordinator loop)
**পরিবর্তন:** Physical switch event এ App কে notify করার encrypted WS push:
```cpp
// After GPIO state change from physical switch:
String stateJson = buildStateJson(loadId, newState);
String encrypted = CryptoHelper::getInstance().encryptAndPack(stateJson);
webSocket.textAll(getCurrentTimestamp() + ":" + encrypted);
```

**App ফাইল:** `frontend/lib/core/network/connection_manager.dart`
**পরিবর্তন:** incoming WS message → decrypt → parse → `NodesProvider.updateLoadState()`

##### 1.3.3 — Debounce Test
- 10ms rapid toggle → single event (no oscillation)
- 50ms debounce window verify

---

#### Sub-phase 1.4: StorageManager Live R/W

##### 1.4.1 — Dynamic Load Add/Remove via App
**App ফাইল:** `frontend/lib/features/control/` screens
**Command JSON (add load):**
```json
{
  "action": "ADD_LOAD",
  "load_id": "fan1",
  "pin": 25,
  "mode": "relay",
  "mac4": "ABCD"
}
```
**Firmware ফাইল:** `src/Core/HardwareManager.cpp`
**পরিবর্তন:** `ADD_LOAD` action handler → validate → save to `/loads.json`

##### 1.4.2 — Coalesced Write Verify
3 rapid state changes → single write after 3s inactivity (not 3 separate writes)

##### 1.4.3 — LittleFS Corruption Recovery
Power cut simulation during write → fallback format → default config restore

---

#### Sub-phase 1.5: Memory Stability Baseline

##### 1.5.1 — TWDT (Task Watchdog Timer)
**ফাইল:** `src/Core/TaskManager.cpp`
```cpp
// Coordinator task এ TWDT যোগ করুন:
esp_task_wdt_add(NULL); // current task register
esp_task_wdt_reset();   // loop এর মধ্যে প্রতিবার call করুন
```

##### 1.5.2 — Heap Monitor Baseline
**ফাইল:** `src/Core/TaskManager.cpp`
```cpp
// SensorTask loop এ প্রতি 10s:
Serial.printf("[HEAP] Free: %d, MaxAlloc: %d\n",
    ESP.getFreeHeap(), ESP.getMaxAllocHeap());
```

##### 1.5.3 — 25KB Heap Guard Latch
**ফাইল:** `src/Network/MqttManager.cpp` বা `src/Core/TaskManager.cpp`
```cpp
// প্রতি loop iteration:
if (ESP.getMaxAllocHeap() < 25000) {
    // Disable MQTT publish, log heartbeat
    heapLatchActive = true;
} else if (heapLatchActive && ESP.getMaxAllocHeap() > 30000) {
    heapLatchActive = false;
}
```

---

### ═══ PHASE 2: App Real Data Binding ═══
**সময়:** ৩–৪ দিন
**Exit Criteria:** Zero dummy data, 100% real firmware data in UI

---

#### Sub-phase 2.1: NodesProvider — Dummy Data সরানো

##### 2.1.1 — Mock Node সরানো
**ফাইল:** `frontend/lib/core/cache/` বা `features/dashboard/` এ `nodes_provider.dart`
```dart
// REMOVE: hardcoded mock node list
// REMOVE: simulated temperature timer (Timer.periodic)
// REMOVE: mock load state maps
// KEEP:   Hive box listener
// KEEP:   LocalCacheService bindings
```

> [!CAUTION]
> `nodes_provider.dart` এর minification map ও comments কখনো delete করবেন না।

##### 2.1.2 — Real State Update Pipe
**ফাইল:** `frontend/lib/core/network/connection_manager.dart`
**পরিবর্তন:** `onMessage` callback:
```dart
void _onMessage(String rawFrame) {
  // Parse [timestamp]:[base64]
  final parts = rawFrame.split(':');
  final timestamp = int.parse(parts[0]);
  final base64 = parts[1];

  // Decrypt
  final k1 = NodeSecurityService.deriveSessionKey(apiKey, timestamp.toString());
  final plaintext = NodeSecurityService.decryptPayload(base64, k1);

  // Parse JSON → update provider
  final json = jsonDecode(plaintext);
  ref.read(nodesProvider.notifier).updateFromFirmware(json);
}
```

##### 2.1.3 — Load Toggle → Real Command
**ফাইল:** `frontend/lib/features/control/` load toggle widget
**পরিবর্তন:** Button press → `ConnectionManager.sendCommand(action, loadId, mac4)` → real WS

##### 2.1.4 — Online/Offline Indicator
**ফাইল:** `frontend/lib/features/dashboard/` node card widget
- WebSocket disconnect → node card এ "offline" badge
- Reconnect → "online" badge

---

#### Sub-phase 2.2: LocalCacheService Real Data

##### 2.2.1 — Real Node Cache
**ফাইল:** `frontend/lib/core/cache/local_cache_service.dart`
- Real node MAC, IP, loads list Hive এ store
- Hardcoded mock data বাদ

##### 2.2.2 — App Restart State Restore
- App restart → Hive load → UI render (without re-fetching)
- Stale data indicator: last-seen timestamp দেখানো

##### 2.2.3 — Offline Queue Test
WebSocket offline → command Hive এ queue → reconnect → auto-replay verify

---

#### Sub-phase 2.3: UDP Discovery → Auto Pairing

##### 2.3.1 — Pairing Dialog
**ফাইল:** `frontend/lib/features/setup/` (নতুন ফাইল)
```dart
// PairingDialog:
// - Node MAC দেখানো
// - api_key input field
// - "Pair" button → SecureStorageProvider.saveApiKey(mac, key)
// - GlassDialog wrapper use করতে হবে (Glassmorphic standard)
```

##### 2.3.2 — IP Change Auto-Reconnect
**ফাইল:** `frontend/lib/core/network/udp_discovery_service.dart`
- Paired node এ নতুন IP beacon → auto reconnect to new IP

##### 2.3.3 — Multi-Node
- ২+ ESP32 nodes simultaneously discover ও connect করার test

---

#### Sub-phase 2.4: Firebase Auth (Real Users)

##### 2.4.1 — Firebase Auth Login
**ফাইল:** `frontend/lib/features/auth/`
- Real Firebase UID দিয়ে login verify
- `approved_nodes` collection check

##### 2.4.2 — Node Approval Flow
- `pending_requests` write → Admin notification
- Admin approve → `approved_nodes` → User dashboard update

##### 2.4.3 — Multi-User Test
Admin + User account → same node → permission level verify

---

#### Sub-phase 2.5: Connection Fallback — Real Test

##### 2.5.1 — WS → HTTP Fallback
**ফাইল:** `frontend/lib/core/network/connection_manager.dart`
**Verify:** WebSocket kill → auto HTTP POST attempt

##### 2.5.2 — HTTP → Offline Queue
**ফাইল:** `frontend/lib/core/cache/local_cache_service.dart`
HTTP unreachable → `enqueueOfflineCommand()` → queue in Hive

##### 2.5.3 — Reconnect Auto-Drain
WiFi restore → offline queue drain → firmware state sync

---

### ═══ PHASE 3: MQTT + Sensors + Rules ═══
**সময়:** ৪–৫ দিন

---

#### Sub-phase 3.1: HiveMQ Firmware Verify

##### 3.1.1 — MQTT Connect & Verify
**ফাইল:** `src/Network/MqttManager.cpp`
**পরিবর্তন:** `ESPHome.ino` তে MqttManager init পুনরায় enable করুন
```cpp
// Phase 0 এ REMOVE করা হয়েছিল, এখন re-enable:
MqttManager::getInstance().begin();
```
**Test:** MQTT Explorer দিয়ে broker এ `ESPHome/nodes/[MAC]/config` retained message verify

##### 3.1.2 — MQTT Credentials Config
**ফাইল:** `src/Storage/StorageManager.cpp`
- `/system.json` থেকে `mqtt_user`, `mqtt_pass`, `mqtt_host` load করা
- Serial command: `SYS:SET_MQTT_CREDS:<user>:<pass>` (development এ)

##### 3.1.3 — MQTT Subscribe → Command Receive
Topic: `ESPHome/nodes/[MAC]/commands/#`
**Test:** MQTT Explorer থেকে manually encrypted command publish → firmware execute verify

---

#### Sub-phase 3.2: App HiveMQ Integration

##### 3.2.1 — MQTT Package Add
**ফাইল:** `frontend/pubspec.yaml`
```yaml
# যোগ করুন:
mqtt_client: ^10.x.x
```

##### 3.2.2 — MqttConnectionService (নতুন ফাইল)
**ফাইল:** `frontend/lib/core/network/mqtt_connection_service.dart` (নতুন)
```dart
class MqttConnectionService {
  // HiveMQ TLS connect on port 8883
  // Subscribe: ESPHome/nodes/+/states/#
  // Subscribe: ESPHome/nodes/+/sensors/#
  // Publish: ESPHome/nodes/[MAC]/commands/state
}
```

##### 3.2.3 — Retained Message Sync
App cold open → broker pushes all retained messages → Hive update → dashboard populated

---

#### Sub-phase 3.3: Full Fallback Pipeline Test
WS → HTTP → MQTT → Offline queue — প্রতিটি leg individually kill করে test

---

#### Sub-phase 3.4: Sensor Integration (BME280 + MQ2)

##### 3.4.1 — SensorTask Enable
**ফাইল:** `ESPHome.ino`
```cpp
// Phase 0 এ REMOVE করা হয়েছিল, এখন re-enable:
// SensorTask এ BME280 + MQ2 reader initialize করুন
```

##### 3.4.2 — BME280 Driver
**ফাইল:** `src/Core/SensorTask.h/.cpp` (নতুন, বা RuleEngine এ integrate)
```cpp
// Dependencies: Adafruit_BME280 library
// Read every 10 seconds
// Publish: temperature, humidity, pressure via EventBus → MQTT
```

##### 3.4.3 — MQ2 Driver
```cpp
// ADC pin: GPIO 34
// Warm-up: 30 seconds after boot (flag: sensorReady)
// Read every 10 seconds after warm-up
// Publish: gas_level via EventBus → MQTT
```

##### 3.4.4 — Mock Flag Remove
**ফাইল:** যেখানে debug mock temperature wave আছে
```cpp
// REMOVE: #define SENSOR_DEBUG_MOCK 1
// ENABLE: real sensor read
```

---

#### Sub-phase 3.5: RuleEngine Live Automation

##### 3.5.1 — RuleEngine Re-enable
**ফাইল:** `ESPHome.ino`
```cpp
// Phase 0 এ disabled ছিল, এখন re-enable:
RuleEngine::getInstance().loadRules();
```

##### 3.5.2 — BME280 Temperature Rule Test
```json
// rules.json example:
{
  "rules": [
    {
      "id": 1,
      "trigger_type": "sensor",
      "source": "temperature",
      "operator": ">",
      "threshold": 30.0,
      "action_target": "fan1",
      "action_value": 1
    }
  ]
}
```

##### 3.5.3 — MQ2 Gas Alert Rule Test
```json
{
  "id": 2,
  "trigger_type": "sensor",
  "source": "gas_level",
  "operator": ">",
  "threshold": 500,
  "action_target": "alarm_relay",
  "action_value": 1
}
```

##### 3.5.4 — App Rule Builder → Firmware Sync
App rule create → encrypted command → `/rules.json` update → RuleEngine reload

---

### ═══ PHASE 4: UI Polish — Glassmorphic + Real Data ═══
**সময়:** ৩–৪ দিন

---

#### Sub-phase 4.1: Dashboard Real Node Cards

##### 4.1.1 — Real Data Binding
**ফাইল:** `frontend/lib/features/dashboard/`
- Real IP, MAC, uptime, heap from firmware
- Live online/offline indicator
- Connection path badge: WS / HTTP / MQTT

##### 4.1.2 — Multi-Node Grid
- ২+ nodes simultaneously controllable

---

#### Sub-phase 4.2: Node Control Screen

##### 4.2.1 — Real Load Toggle
- GPIO ON/OFF with firmware ack animation
- Optimistic update: UI toggle immediately, revert if ack fails

##### 4.2.2 — Sensor Chart Real Data
**ফাইল:** `frontend/lib/features/control/` chart widget
```dart
// REMOVE: simulated tempHistory values
// REPLACE: real BME280 temperature history from LocalCacheService
// ADD: MQ2 gas level widget
// ADD: BME280 pressure widget
```

##### 4.2.3 — Load Add/Delete Flow
- Add load → GPIO assignment → Save → Firmware apply
- Delete load → Safety check (ON? → block) → Confirm dialog → Remove

---

#### Sub-phase 4.3: Settings Screen

##### 4.3.1 — Security Settings
- API key masked display + reveal toggle → SecureStorage bind
- MQTT broker status indicator (connected / reconnecting)

##### 4.3.2 — Time Format
- 12h/24h toggle → rule display update
- Under-the-hood: 24h processing always

---

#### Sub-phase 4.4: Glassmorphic Design Full Polish

##### 4.4.1 — Node Cards
```dart
BackdropFilter(
  filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
  child: Container(
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.08),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withOpacity(0.15)),
    ),
  ),
)
```

##### 4.4.2 — GlassDialog Wrapper
**ফাইল:** `frontend/lib/core/widgets/glass_dialog.dart` (নতুন)
- সব dialogs এ ব্যবহার: delete confirm, pair, rule create
- blur sigma: 16+, translucent border, soft shadow

##### 4.4.3 — Connection Status Banner
Glassmorphic offline/reconnecting banner: screen top এ slide-down animation

---

#### Sub-phase 4.5: OTA Update Flow

##### 4.5.1 — Local OTA
**App:** file picker → `.bin` select → HTTP multipart upload to `/api/ota`
**Firmware:** OTA handler in `AppNetworkManager.cpp`

---

### ═══ PHASE 5: Hardening, Testing & Deploy ═══
**সময়:** ৪–৫ দিন

---

#### Sub-phase 5.1: Crypto Unit Tests (EtM Included)

##### 5.1.1 — Cross-Platform Key Derivation Parity
Same `api_key` + same `timestamp` → identical `k_enc` (first 16B) AND `k_mac` (second 16B) on both Firmware (Serial print) and App (Dart print). Both keys must match byte-for-byte.

##### 5.1.2 — EtM Round-Trip (Multiple Payload Sizes)
For each size in [10, 100, 500, 1000] bytes:
- `encryptAndMac()` → transmit → `verifyAndDecrypt()` → plaintext identical
- Packet structure verify: `decoded.length == 16 + ceil(payloadLen/16)*16 + 16`

##### 5.1.3 — MAC Tamper Tests
- **Bit-flip:** ciphertext 1 byte flip → `verifyAndDecrypt()` returns null/false
- **MAC strip:** remove last 16 bytes → packet too short → reject
- **IV tamper:** first 16 bytes change → MAC mismatch → reject
- **Truncated packet:** 47 bytes (< 48 min) → reject before any processing

##### 5.1.4 — Constant-Time MAC Compare
Verify `_constantTimeEqual()` takes same time regardless of where mismatch occurs (timing side-channel prevention).

##### 5.1.5 — Replay Window
31s old timestamp → `401`. Fresh timestamp → `200`.

##### 5.1.6 — mac4 Mismatch
Wrong mac4 (after MAC passes) → `409 Conflict`.

---

#### Sub-phase 5.2: Memory & Stability

##### 5.2.1 — 50-Event Burst Pool Test
50 rapid events → drop policy verify → `crash_logs.json` entry verify

##### 5.2.2 — ISR Stress
1000 rapid switch toggles → no crash, heap stable

##### 5.2.3 — 24-Hour Soak
Continuous WS + MQTT + sensor + rule → heap flat (no leak)

##### 5.2.4 — Power Cycle × 10
State restore correct every time

---

#### Sub-phase 5.3: Network Resilience

##### 5.3.1 — WiFi Dropout
Core 1 uninterrupted during Core 0 WiFi recovery

##### 5.3.2 — Full Cascade Test
WS → HTTP → MQTT → Queue — each leg individually killed and recovered

---

#### Sub-phase 5.4: App Tests & Build

##### 5.4.1 — Flutter Tests
```bash
flutter test
flutter analyze
```

##### 5.4.2 — Obfuscated Build
```bash
flutter build apk --release --obfuscate --split-debug-info=build/symbols \
  --dart-define=MQTT_BROKER_HOST=<host> \
  --dart-define=MQTT_PORT=8883
```

---

#### Sub-phase 5.5: CI/CD

##### 5.5.1 — GitHub Actions
- PR: `flutter analyze` + `flutter test`
- Tag `v*.*.*`: build APK + IPA → Fastlane deploy

---

## ৮. Phase Summary Table

| Phase | নাম | সময় | Exit Criteria |
|:---|:---|:---|:---|
| **Phase 0** | Live Crypto Handshake | 2–3 দিন | Real encrypted WS round-trip ✓ |
| **Phase 1** | Firmware Core Wiring | 3–4 দিন | GPIO + ISR + Storage live ✓ |
| **Phase 2** | App Real Data Binding | 3–4 দিন | Zero dummy data ✓ |
| **Phase 3** | MQTT + Sensors + Rules | 4–5 দিন | BME280, MQ2, HiveMQ live ✓ |
| **Phase 4** | Glassmorphic UI Polish | 3–4 দিন | Full glassmorphic design ✓ |
| **Phase 5** | Hardening & Deploy | 4–5 দিন | 24h soak pass, app published ✓ |
| **মোট** | | **~19–25 দিন** | |

---

## ৯. Key Design Decisions Log

| বিষয় | v2.1 | v3.0 |
|:---|:---|:---|
| Build Order | Firmware → App → Connect | Connect → Firmware Wire → App Bind |
| Dummy Data | Allowed throughout | Banned from Phase 2 |
| MQTT Timing | Phase 4 | Phase 3 |
| Sensors | DHT22 (placeholder) | BME280 I2C + MQ2 Analog |
| api_key Setup | Pre-flashed only | Serial command OR default |
| MQTT Credentials | Per-device (planned) | Shared dev credentials |
| Branch | main | `feature/v3-connection-first` |
| **Payload Auth** | **None (AES-CBC only)** | **EtM: HMAC-SHA256 over IV+Ciphertext** |
| **Key Count** | 1 key (K1 for AES) | 2 keys (k_enc + k_mac) |
| **Tamper Response** | Silent decrypt | MAC mismatch → reject, `403 Forbidden` |
| **Timing Safety** | Not specified | Constant-time MAC compare |
| **String Class** | Used everywhere | **Completely banned** — `char[]` + `snprintf()` |
| **Serial Strings** | `Serial.print("...")` | **`Serial.print(F("..."))`** mandatory |
| **Sensor Buffers** | Dynamic / none | Static ring buffer `SensorSample[12]` |
| **Log Buffers** | Serial only | Static ring buffer `char[512]` + overflow-safe |
| **Heap Monitor** | Latch only | Real-time task: WARN/LATCH/CRITICAL/RESTART |
| **Heap Critical** | Not defined | < 15KB → auto `esp_restart()` |

---

## ১০. Critical Credentials & System Configuration Registry

> [!IMPORTANT]
> এই সেকশনে প্রকল্পের সমস্ত সক্রিয় ও ডিফাল্ট ক্রিপ্টোগ্রাফিক কি, ব্রোকার ক্রেডেনশিয়াল, ফায়ারবেস কনফিগারেশন এবং নেটওয়ার্ক প্যারামিটার সংরক্ষিত হলো। কোনো কারণে লোকাল কনফিগ ফাইল পরিবর্তন বা মেমরি ফ্ল্যাশ ক্লিয়ার হলেও এই মানসমূহ রেফারেন্স হিসেবে ব্যবহার করা যাবে।

### ১০.১ — ESP32 Firmware & Network Credentials
| Parameter | Value | Location / Usage |
|:---|:---|:---|
| Default API Key | `ESPHome_sec_node` | `StorageManager.cpp` (`/system.json` default) |
| UDP Discovery Port | `4210` | `AppNetworkManager.cpp` |
| WebSocket Port | `80` (`/ws` endpoint) | `AppNetworkManager.cpp` |
| HTTP Fallback Endpoint | `POST /api/set-state` | `AppNetworkManager.cpp` |
| Serial Config Command | `WIFI:SET_API_KEY:<key>` | Serial Monitor @ 115200 baud |
| Dynamic Encryption Secret | `CypherNodeSecretX` | Standalone utility tests |

### ১০.২ — HiveMQ Cloud MQTT Credentials (Shared Dev)
| Parameter | Value | Location / Usage |
|:---|:---|:---|
| Broker Host | `494f4376e75a419193b3ddbd54f2338d.s1.eu.hivemq.cloud` | `MqttManager.cpp` |
| Port | `8883` (MQTTS with TLS) | `MqttManager.cpp` |
| Default Username | `@esp_home` | Encrypted in `/system.json` via `StorageManager.cpp` |
| Default Password | `password@esp_Home` | Encrypted in `/system.json` via `StorageManager.cpp` |
| CA Certificate | ISRG Root X1 | Hardcoded X.509 PEM in `StorageManager.cpp` |
| Client ID Format | `ESPHome_[MAC_ADDRESS]` | Unique per ESP32 node |

### ১০.৩ — Google Firebase Config (Flutter App)
| Parameter | Value | Location / Usage |
|:---|:---|:---|
| Package Name | `com.adacode.esphome` | Android `build.gradle` & `pubspec.yaml` |
| Firebase DB URL | `https://esphome-adacodec-default-rtdb.asia-southeast1.firebasedatabase.app` | `google-services.json` & `firebase_options.dart` |
| Storage Bucket | `esphome-adacodec.firebasestorage.app` | `google-services.json` & `firebase_options.dart` |
| Auth Domain | `esphome-adacodec.firebaseapp.com` | `firebase_options.dart` |
| Firebase Secret Key | `default_firebase_sec_key_123456` | `frontend/scripts/encrypt_role.dart` |

---

*এই ডকুমেন্ট v3.0 এর living specification। পরিবর্তন হলে `Architecture/tracking.md` এ লগ করতে হবে।*
