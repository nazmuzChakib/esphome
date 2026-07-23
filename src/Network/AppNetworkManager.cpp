#include "AppNetworkManager.h"
#include "../Security/CryptoHelper.h"
#include "../Core/EventBus.h"
#include <time.h>

AppNetworkManager::AppNetworkManager() 
    : _server(80), _ws("/ws"), _wm("ESPHome", "esp_home"), _lastUDPBroadcastTime(0), _timeSynced(false), _lastNTPCheckTime(0) {
}

AppNetworkManager& AppNetworkManager::getInstance() {
    static AppNetworkManager instance;
    return instance;
}

bool AppNetworkManager::begin() {
    Serial.println(F("[NETWORK] Initializing AppNetworkManager..."));

    // 1. Setup ESPWiFiManager Callbacks
    _wm.onStationConnected([this](const String& ssid, IPAddress ip) {
        this->onWiFiConnected(ssid, ip);
    });
    _wm.onStationDisconnected([this](int reason) {
        this->onWiFiDisconnected(reason);
    });
    _wm.onAPModeStarted([this](const String& ssid, IPAddress ip) {
        this->onAPStarted(ssid, ip);
    });
    _wm.onAPModeStopped([this]() {
        this->onAPStopped();
    });

    // 2. Configure AP Fallback Server
    _wm.setAutoAPFallback(true, &_server);

    // 3. Register WebSocket Event Callback
    _ws.onEvent([this](AsyncWebSocket* server, AsyncWebSocketClient* client, AwsEventType type, void* arg, uint8_t* data, size_t len) {
        if (type == WS_EVT_DATA) {
            AwsFrameInfo* info = (AwsFrameInfo*)arg;
            if (info->final && info->index == 0 && info->len == len && info->opcode == WS_TEXT) {
                // Buffer raw text safely
                char* msg = (char*)malloc(len + 1);
                if (msg != nullptr) {
                    memcpy(msg, data, len);
                    msg[len] = '\0';
                    
                    // Core 0 Check: Ensure syntax follows [Timestamp]:[Base64]
                    if (strchr(msg, ':') != nullptr) {
                        AppEvent ev;
                        ev.type = EVENT_NETWORK_COMMAND;
                        ev.timestamp = millis();
                        strncpy(ev.payload.network.command, msg, sizeof(ev.payload.network.command) - 1);
                        ev.payload.network.command[sizeof(ev.payload.network.command) - 1] = '\0';
                        
                        // Push event to Coordinator queue immediately with no delay/decrypt on Core 0
                        EventBus::getInstance().pushEvent(ev, false);
                    }
                    free(msg);
                }
            }
        }
    });
    _server.addHandler(&_ws);

    // 4. Register HTTP Fallback API Route (/api/set-state)
    _server.on("/api/set-state", HTTP_POST, 
        [](AsyncWebServerRequest* request) {
            request->send(200, "text/plain", "OK");
        },
        nullptr,
        [](AsyncWebServerRequest* request, uint8_t* data, size_t len, size_t index, size_t total) {
            if (len > 0) {
                char* msg = (char*)malloc(len + 1);
                if (msg != nullptr) {
                    memcpy(msg, data, len);
                    msg[len] = '\0';
                    
                    if (strchr(msg, ':') != nullptr) {
                        AppEvent ev;
                        ev.type = EVENT_NETWORK_COMMAND;
                        ev.timestamp = millis();
                        strncpy(ev.payload.network.command, msg, sizeof(ev.payload.network.command) - 1);
                        ev.payload.network.command[sizeof(ev.payload.network.command) - 1] = '\0';
                        
                        EventBus::getInstance().pushEvent(ev, false);
                    }
                    free(msg);
                }
            }
        }
    );

    // 5. Register WiFiManager internal API routes (/api/*)
    _wm.registerApiRoutes(_server);

    // 5. Initialize NTP Sync (GMT+6)
    Serial.println(F("[NETWORK] Starting SNTP sync (pool.ntp.org)..."));
    configTime(6 * 3600, 0, "pool.ntp.org", "time.nist.gov");

    // 6. Initialize UDP Socket
    _udp.begin(4210);
    Serial.println(F("[NETWORK] UDP Socket listening on Port 4210."));

    // 7. Start Async Server
    _server.begin();
    Serial.println(F("[NETWORK] AsyncWebServer started on Port 80."));

    // 8. Start WiFiManager
    _wm.begin();

    return true;
}

void AppNetworkManager::process() {
    // 1. Process WiFi manager state machine (reconnect cycles)
    _wm.process();

    // 2. Periodically check NTP Sync progress
    unsigned long nowMs = millis();
    if (!_timeSynced && (nowMs - _lastNTPCheckTime >= 5000)) {
        _lastNTPCheckTime = nowMs;
        time_t now = time(nullptr);
        struct tm timeinfo;
        if (getLocalTime(&timeinfo, 10)) { // 10ms timeout
            if (timeinfo.tm_year > 120) { // Synced if year is greater than 2020
                _timeSynced = true;
                Serial.printf("[NETWORK] NTP Synchronized. Date/Time: %04d-%02d-%02d %02d:%02d:%02d\n", 
                              timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday,
                              timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);
            }
        }
    }

    // 3. Process UDP discovery requests and periodic broadcast beacons
    checkUDPDiscovery();
    sendDiscoveryBeacon();
}

bool AppNetworkManager::isConnected() const {
    return _wm.isConnected();
}

unsigned long AppNetworkManager::getUnixTimestamp() {
    time_t now;
    time(&now);
    return (unsigned long)now;
}

void AppNetworkManager::executeWifiCommand(const String& cmd, Stream& io) {
    _wm.executeCommand(cmd, io);
}

void AppNetworkManager::onWiFiConnected(const String& ssid, IPAddress ip) {
    Serial.printf("[NETWORK] Callback: Connected to WiFi SSID '%s'. Local IP: %s\n", ssid.c_str(), ip.toString().c_str());
}

void AppNetworkManager::onWiFiDisconnected(int reason) {
    Serial.printf("[NETWORK] Callback: Lost WiFi Connection. Reason code: %d\n", reason);
    _timeSynced = false;
}

void AppNetworkManager::onAPStarted(const String& ssid, IPAddress ip) {
    Serial.printf("[NETWORK] Callback: Soft-AP Captive Portal active. SSID: '%s', IP: %s\n", ssid.c_str(), ip.toString().c_str());
}

void AppNetworkManager::onAPStopped() {
    Serial.println(F("[NETWORK] Callback: Soft-AP Captive Portal stopped."));
}

void AppNetworkManager::checkUDPDiscovery() {
    // if (!_timeSynced) {
    //     return; // Reject discovery queries when time is not synced yet
    // }

    int packetSize = _udp.parsePacket();
    if (packetSize > 0) {
        char buffer[255];
        int len = _udp.read(buffer, 254);
        if (len > 0) {
            buffer[len] = '\0';
            String packet(buffer);
            
            // Format check: [Timestamp]:[Base64]
            int colonPos = packet.indexOf(':');
            if (colonPos != -1) {
                String timestamp = packet.substring(0, colonPos);
                String base64 = packet.substring(colonPos + 1);
                String decrypted;
                
                // Decrypt and verify time-window/mac4
                if (CryptoHelper::getInstance().verifyAndDecrypt(base64, timestamp, decrypted)) {
                    if (decrypted.startsWith("ESPHOME_QUERY")) {
                        IPAddress remoteIP = _udp.remoteIP();
                        uint16_t remotePort = _udp.remotePort();
                        
                        // Construct response: signature:ip:mac:uptime
                        String ipStr = isConnected() ? WiFi.localIP().toString() : WiFi.softAPIP().toString();
                        String replyPlain = "ESPHOME_REPLY:" + ipStr + ":" + WiFi.macAddress() + ":" + String(millis() / 1000);
                        
                        String responseEnc = CryptoHelper::getInstance().encrypt(replyPlain, timestamp);
                        String responsePacket = timestamp + ":" + responseEnc;
                        
                        _udp.beginPacket(remoteIP, remotePort);
                        _udp.print(responsePacket);
                        _udp.endPacket();
                        
                        Serial.printf("[NETWORK] Received encrypted UDP Query from %s. Sent encrypted Reply.\n", remoteIP.toString().c_str());
                    }
                }
            }
        }
    }
}

void AppNetworkManager::sendDiscoveryBeacon() {
    // if (!_timeSynced) {
    //     return; // Skip discovery broadcast to prevent replay window before NTP sync
    // }

    int activeWsClients = _ws.count();
    unsigned long interval = (activeWsClients > 0) ? 60000UL : 15000UL;

    unsigned long nowMs = millis();
    if (nowMs - _lastUDPBroadcastTime >= interval) {
        _lastUDPBroadcastTime = nowMs;
        
        // Active broadcast only when IP exists
        if (isConnected() || WiFi.softAPIP() != IPAddress(0, 0, 0, 0)) {
            String ipStr = isConnected() ? WiFi.localIP().toString() : WiFi.softAPIP().toString();
            String macStr = WiFi.macAddress();
            String uptimeStr = String(millis() / 1000);
            
            String plainText = "ESPHOME_DISCOVERY:" + ipStr + ":" + macStr + ":" + uptimeStr;
            String timestamp = String(getUnixTimestamp());
            
            String encrypted = CryptoHelper::getInstance().encrypt(plainText, timestamp);
            String packet = timestamp + ":" + encrypted;
            
            _udp.beginPacket("255.255.255.255", 4210);
            _udp.print(packet);
            _udp.endPacket();
            
            Serial.printf("[NETWORK] Broadcasted encrypted UDP Discovery. Active WS: %d. Interval: %lu ms.\n", 
                          activeWsClients, interval);
        }
    }
}
