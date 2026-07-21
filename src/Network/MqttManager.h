#ifndef MQTT_MANAGER_H
#define MQTT_MANAGER_H

#include <Arduino.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>

class MqttManager {
public:
    static MqttManager& getInstance();

    // Initialize MQTTS client and load CA cert
    bool begin();
    
    // Pump loop for MQTT connection and message loops (pinned to TaskMQTT on Core 1)
    void process();

    // Generic publish method using dynamic topic structure with retain flag
    bool publish(const char* subTopic, const char* payloadStr, bool retain = true);

    // Dynamic logging helper for MQTT logs topic
    bool publishLog(const char* logMsg);

private:
    MqttManager();
    ~MqttManager() = default;
    MqttManager(const MqttManager&) = delete;
    MqttManager& operator=(const MqttManager&) = delete;

    // Connects to HiveMQ Cloud Broker using TLS 8883
    void connect();
    
    // Callback routine for incoming MQTT payloads
    void onMessageReceived(char* topic, uint8_t* payload, unsigned int length);

    WiFiClientSecure _secureClient;
    PubSubClient _mqttClient;
    String _caCert;
    unsigned long _lastReconnectAttempt;
    
    #define OFFLINE_QUEUE_SIZE 32

    // Memory-bounded Offline Command Queue
    struct OfflineMessage {
        char payload[128];
    };
    OfflineMessage _offlineQueue[OFFLINE_QUEUE_SIZE];
    uint8_t _head = 0;
    uint8_t _tail = 0;
    uint8_t _queueCount = 0;
    class SystemMutex* _mutex = nullptr;
};

#endif // MQTT_MANAGER_H
