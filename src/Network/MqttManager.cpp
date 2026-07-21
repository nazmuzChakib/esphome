#include "MqttManager.h"
#include "../Storage/StorageManager.h"
#include "../Security/CryptoHelper.h"
#include "../Core/EventBus.h"
#include "AppNetworkManager.h"
#include "../Core/SystemMutex.h"
#include "../Core/HardwareManager.h"
#include <WiFi.h>

MqttManager::MqttManager() 
    : _mqttClient(_secureClient), _lastReconnectAttempt(0), _head(0), _tail(0), _queueCount(0) {
    _mutex = new SystemMutex();
}

MqttManager& MqttManager::getInstance() {
    static MqttManager instance;
    return instance;
}

bool MqttManager::begin() {
    Serial.println(F("[MQTT] Loading Root CA certificate from system.json..."));

    _caCert = StorageManager::getInstance().getMqttCA();
    if (_caCert.length() == 0) {
        Serial.println(F("[MQTT] Error: Root CA certificate not found in system.json!"));
        return false;
    }

    _secureClient.setCACert(_caCert.c_str());
    _secureClient.setHandshakeTimeout(5);
    _secureClient.setTimeout(5);
    
    _mqttClient.setServer("494f4376e75a419193b3ddbd54f2338d.s1.eu.hivemq.cloud", 8883);
    
    // Set callback via lambda
    _mqttClient.setCallback([this](char* topic, uint8_t* payload, unsigned int length) {
        this->onMessageReceived(topic, payload, length);
    });

    Serial.println(F("[MQTT] MQTTS manager initialized. Connection targeted at port 8883."));
    return true;
}

#include <LittleFS.h>

void MqttManager::connect() {
    if (WiFi.status() != WL_CONNECTED) {
        return;
    }

    // Resolve broker hostname to populate the lwIP DNS cache
    IPAddress brokerIP;
    bool resolved = WiFi.hostByName("494f4376e75a419193b3ddbd54f2338d.s1.eu.hivemq.cloud", brokerIP);

    if (!resolved) {
        Serial.println(F("[MQTT] Error: DNS resolution failed for HiveMQ broker!"));
        return;
    }

    Serial.println(F("[MQTT] Attempting to establish TLS connection to HiveMQ Cloud..."));
    
    char clientId[64];
    snprintf(clientId, sizeof(clientId), "ESPHome-%s", CryptoHelper::getInstance().getDeviceMac());
    
    String user = StorageManager::getInstance().getMqttUser();
    String password = StorageManager::getInstance().getMqttPass();
    if (user.length() == 0 || password.length() == 0) {
        Serial.println(F("[MQTT] Error: Decrypted credentials are empty!"));
        return;
    }

    // Set plaintext Last Will and Testament for the broker to publish when connection breaks
    char willTopic[64];
    snprintf(willTopic, sizeof(willTopic), "ESPHome/nodes/%s/config", CryptoHelper::getInstance().getDeviceMac());
    const char* willMessage = "offline";

    if (_mqttClient.connect(clientId, user.c_str(), password.c_str(), 
                            willTopic, 1, true, willMessage)) {
        Serial.printf("[MQTT] Connection SUCCESS with username '%s'! Subscribing to command topic...\n", user.c_str());

        char cmdTopic[64];
        snprintf(cmdTopic, sizeof(cmdTopic), "ESPHome/nodes/%s/commands/#", CryptoHelper::getInstance().getDeviceMac());
        _mqttClient.subscribe(cmdTopic);

        Serial.printf("[MQTT] Subscribed to topic: %s\n", cmdTopic);

        // Flush offline queue on successful connection
        {
            LockGuard lock(*_mutex);
            
            // Publish boot configuration to config topic with status online (encrypted, retain=true)
            char configPayload[128];
            snprintf(configPayload, sizeof(configPayload), 
                     "{\"status\":\"online\",\"ip\":\"%s\",\"uptime\":%lu,\"heap\":%u}", 
                     WiFi.localIP().toString().c_str(),
                     millis() / 1000,
                     ESP.getFreeHeap());
            publish("config", configPayload, true);

            if (_queueCount > 0) {
                Serial.printf("[MQTT] Restored connection. Flushing %d cached offline messages...\n", _queueCount);
                while (_queueCount > 0) {
                    const char* cachedStr = _offlineQueue[_head].payload;
                    _head = (_head + 1) % OFFLINE_QUEUE_SIZE;
                    _queueCount--;
                    
                    const char* sep = strchr(cachedStr, '|');
                    if (sep != nullptr) {
                        size_t subLen = sep - cachedStr;
                        char sub[32];
                        if (subLen < sizeof(sub)) {
                            strncpy(sub, cachedStr, subLen);
                            sub[subLen] = '\0';
                            
                            const char* packet = sep + 1;
                            char topic[128];
                            snprintf(topic, sizeof(topic), "ESPHome/nodes/%s/%s", CryptoHelper::getInstance().getDeviceMac(), sub);
                            _mqttClient.publish(topic, packet, true);
                        }
                    } else {
                        char topic[128];
                        snprintf(topic, sizeof(topic), "ESPHome/nodes/%s/states", CryptoHelper::getInstance().getDeviceMac());
                        _mqttClient.publish(topic, cachedStr, true);
                    }
                }
            }

            // Flush from queue.json (flash storage overflow)
            if (LittleFS.exists("/queue.json")) {
                File file = LittleFS.open("/queue.json", "r");
                if (file) {
                    Serial.println(F("[MQTT] Flushing offline messages from flash /queue.json..."));
                    while (file.available()) {
                        String line = file.readStringUntil('\n');
                        line.trim();
                        if (line.length() > 0) {
                            const char* lineStr = line.c_str();
                            const char* sep = strchr(lineStr, '|');
                            if (sep != nullptr) {
                                size_t subLen = sep - lineStr;
                                char sub[32];
                                if (subLen < sizeof(sub)) {
                                    strncpy(sub, lineStr, subLen);
                                    sub[subLen] = '\0';
                                    
                                    const char* packet = sep + 1;
                                    char topic[128];
                                    snprintf(topic, sizeof(topic), "ESPHome/nodes/%s/%s", CryptoHelper::getInstance().getDeviceMac(), sub);
                                    _mqttClient.publish(topic, packet, true);
                                }
                            } else {
                                char topic[128];
                                snprintf(topic, sizeof(topic), "ESPHome/nodes/%s/states", CryptoHelper::getInstance().getDeviceMac());
                                _mqttClient.publish(topic, lineStr, true);
                            }
                        }
                    }
                    file.close();
                    LittleFS.remove("/queue.json");
                }
            }
        }
    } else {
        Serial.printf("[MQTT] Connection FAILED with username '%s'. state = %d\n", user.c_str(), _mqttClient.state());
    }
}

void MqttManager::process() {
    if (!_mqttClient.connected()) {
        unsigned long now = millis();
        if (now - _lastReconnectAttempt >= 5000) {
            _lastReconnectAttempt = now;
            connect();
        }
    } else {
        _mqttClient.loop();
    }
}

bool MqttManager::publish(const char* subTopic, const char* payloadStr, bool retain) {
    char timestamp[16];
    unsigned long ts = AppNetworkManager::getInstance().getUnixTimestamp();
    if (ts == 0) {
        ts = 1716900000; // Fallback test timestamp
    }
    snprintf(timestamp, sizeof(timestamp), "%lu", ts);

    // Encrypt payload via session key K1 derived from timestamp
    String encryptedPayload = CryptoHelper::getInstance().encrypt(payloadStr, timestamp);
    
    char msgPacket[256];
    snprintf(msgPacket, sizeof(msgPacket), "%s:%s", timestamp, encryptedPayload.c_str());
    
    // Save subTopic inside the queued string to route correctly when connection returns
    char queuePacket[256];
    snprintf(queuePacket, sizeof(queuePacket), "%s|%s", subTopic, msgPacket);

    LockGuard lock(*_mutex);
    if (_mqttClient.connected()) {
        char topic[128];
        snprintf(topic, sizeof(topic), "ESPHome/nodes/%s/%s", CryptoHelper::getInstance().getDeviceMac(), subTopic);
        bool result = _mqttClient.publish(topic, msgPacket, retain);
        if (result) {
            Serial.printf("[MQTT] Successfully published encrypted state payload to %s\n", topic);
        }
        return result;
    } else {
        // Queue message locally if offline
        if (_queueCount < OFFLINE_QUEUE_SIZE) {
            strncpy(_offlineQueue[_tail].payload, queuePacket, sizeof(_offlineQueue[_tail].payload) - 1);
            _offlineQueue[_tail].payload[sizeof(_offlineQueue[_tail].payload) - 1] = '\0';
            _tail = (_tail + 1) % OFFLINE_QUEUE_SIZE;
            _queueCount++;
            Serial.printf("[MQTT] Client offline. Telemetry cached in local queue (size: %d/%d).\n", _queueCount, OFFLINE_QUEUE_SIZE);
        } else {
            // Queue full!
            // If the incoming event is critical (contains relay_state or alert), save to LittleFS file /queue.json
            if (strstr(payloadStr, "relay_state") != nullptr || strstr(payloadStr, "alert") != nullptr) {
                File file = LittleFS.open("/queue.json", "a");
                if (file) {
                    file.println(queuePacket);
                    file.close();
                    Serial.println(F("[MQTT] Offline RAM queue full! Appended critical message to /queue.json."));
                } else {
                    Serial.println(F("[MQTT] Error: Failed to open /queue.json to append critical message!"));
                }
            } else {
                // Otherwise, advance head to overwrite oldest RAM entry (drop-oldest)
                _head = (_head + 1) % OFFLINE_QUEUE_SIZE;
                strncpy(_offlineQueue[_tail].payload, queuePacket, sizeof(_offlineQueue[_tail].payload) - 1);
                _offlineQueue[_tail].payload[sizeof(_offlineQueue[_tail].payload) - 1] = '\0';
                _tail = (_tail + 1) % OFFLINE_QUEUE_SIZE;
                Serial.println(F("[MQTT] Offline RAM queue full! Circular drop oldest packet to retain latest telemetry state."));
            }
        }
        return false;
    }
}

bool MqttManager::publishLog(const char* logMsg) {
    return publish("logs", logMsg, true);
}

void MqttManager::onMessageReceived(char* topic, uint8_t* payload, unsigned int length) {
    // Safety check: ensure payload fits inside command buffer
    if (length > 0) {
        char* msg = (char*)malloc(length + 1);
        if (msg != nullptr) {
            memcpy(msg, payload, length);
            msg[length] = '\0';
            
            // Check for sync command first
            if (strstr(topic, "/commands/sync") != nullptr) {
                Serial.println(F("[MQTT] Received sync request. Re-publishing loads and active states..."));
                HardwareManager::getInstance().syncHardwareState();
                free(msg);
                return;
            }
            
            // Format check: [Timestamp]:[Base64]
            if (strchr(msg, ':') != nullptr) {
                AppEvent ev;
                ev.type = EVENT_NETWORK_COMMAND;
                ev.timestamp = millis();
                strncpy(ev.payload.network.command, msg, sizeof(ev.payload.network.command) - 1);
                ev.payload.network.command[sizeof(ev.payload.network.command) - 1] = '\0';
                
                // Queue directly to Coordinator on Core 1
                EventBus::getInstance().pushEvent(ev, false);
                Serial.println(F("[MQTT] Received command, forwarded to EventBus."));
            }
            free(msg);
        }
    }
}
