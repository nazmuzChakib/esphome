#include "TaskManager.h"
#include "EventBus.h"
#include "RuleEngine.h"
#include "../Network/AppNetworkManager.h"
#include "../Network/MqttManager.h"
#include "../Security/CryptoHelper.h"

// Distinct FreeRTOS Stack Allocation Sizes (in words)
// NOTE: STACK_SENSOR was increased from 1024 → 3072 to fix "Stack canary watchpoint triggered (SensorTask)".
//       1024 words (4 KB) was too small: AppEvent construction + EventBus::pushEvent() + Serial.printf()
//       together exceeded the guard page, causing a hard panic on every boot.
// NOTE: STACK_COORDINATOR bumped from 3072 → 6144 for SSL/TLS writes in MqttManager.
#define STACK_NETWORK 3072      // 12 KB for Web Server / WebSockets
#define STACK_COORDINATOR 6144  // 24 KB for Coordinator (RuleEngine + CryptoHelper + MQTT publish SSL/TLS)
#define STACK_SENSOR 3072       // 12 KB for Sensor Telemetry Polls (was 4 KB → stack overflow crash fixed)
#define STACK_MQTT 6144         // 24 KB for MQTTS client TLS handshakes

#define PRIORITY_COORDINATOR 4
#define PRIORITY_NETWORK 3
#define PRIORITY_SENSOR 3
#define PRIORITY_MQTT 1

#define DEBUG_MOCK_SENSOR 1

TaskManager& TaskManager::getInstance() {
    static TaskManager instance;
    return instance;
}

bool TaskManager::begin() {
    Serial.println(F("[TASK_MGR] Spawning dual-core tasks..."));

    // 1. Core 0 Task: Network (WiFi Manager, WebServer, WebSockets)
    BaseType_t result0 = xTaskCreatePinnedToCore(
        TaskManager::runCore0Task,
        "TaskCore0",
        STACK_NETWORK,
        NULL,
        PRIORITY_NETWORK,
        &_core0TaskHandle,
        0 // Pinned to Core 0
    );

    if (result0 != pdPASS) {
        Serial.println(F("[TASK_MGR] Error: Failed to create TaskCore0!"));
        return false;
    }

    // 2. Core 1 Task: Coordinator
    BaseType_t result1 = xTaskCreatePinnedToCore(
        TaskManager::runCore1Task,
        "TaskCore1",
        STACK_COORDINATOR,
        NULL,
        PRIORITY_COORDINATOR,
        &_core1TaskHandle,
        1 // Pinned to Core 1
    );

    if (result1 != pdPASS) {
        Serial.println(F("[TASK_MGR] Error: Failed to create TaskCore1!"));
        if (_core0TaskHandle != NULL) {
            vTaskDelete(_core0TaskHandle);
            _core0TaskHandle = NULL;
        }
        return false;
    }

    // 3. Core 1 Task: Sensor Telemetry Task (Runs every 10s)
    BaseType_t resultSensor = xTaskCreatePinnedToCore(
        TaskManager::runSensorTask,
        "SensorTask",
        STACK_SENSOR,
        NULL,
        PRIORITY_SENSOR,
        &_sensorTaskHandle,
        1 // Pinned to Core 1
    );

    if (resultSensor != pdPASS) {
        Serial.println(F("[TASK_MGR] Error: Failed to create SensorTask!"));
        return false;
    }

    // 4. Core 0 Task: HiveMQ MQTT over TLS Client loop (Low priority, pinned to Core 0 to avoid LwIP multi-core conflicts)
    BaseType_t resultMQTT = xTaskCreatePinnedToCore(
        TaskManager::runMQTTTask,
        "TaskMQTT",
        STACK_MQTT,
        NULL,
        PRIORITY_MQTT,
        &_mqttTaskHandle,
        0 // Pinned to Core 0
    );

    if (resultMQTT != pdPASS) {
        Serial.println(F("[TASK_MGR] Error: Failed to create TaskMQTT!"));
        return false;
    }

    Serial.println(F("[TASK_MGR] Web, Coordinator, Sensor, and MQTT tasks spawned successfully."));
    return true;
}

void TaskManager::runCore0Task(void* parameter) {
    Serial.printf("[TASK_CORE0] Network Task started on Core %d\n", xPortGetCoreID());
    
    if (!AppNetworkManager::getInstance().begin()) {
        Serial.println(F("[TASK_CORE0] Fatal: Failed to initialize AppNetworkManager!"));
    }

    while (true) {
        AppNetworkManager::getInstance().process();
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}

void TaskManager::runMQTTTask(void* parameter) {
    Serial.printf("[TASK_MQTT] MQTTS Client loop started on Core %d\n", xPortGetCoreID());
    
    // Initialize MQTT
    if (!MqttManager::getInstance().begin()) {
        Serial.println(F("[TASK_MQTT] Error: Failed to initialize MqttManager!"));
    }

    while (true) {
        MqttManager::getInstance().process();
        vTaskDelay(pdMS_TO_TICKS(50)); // Yield to other tasks
    }
}

void TaskManager::runSensorTask(void* parameter) {
    Serial.printf("[SENSOR_TASK] Sensor polling task started on Core %d\n", xPortGetCoreID());
    
    // Test parameters for generating a temperature wave crossing the 30C mark
    static float currentTemp = 28.0f;
    static float currentHum = 50.0f;
    static bool waveUp = true;

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(20000)); // Sleep 20s

#if DEBUG_MOCK_SENSOR
        // Dynamic mock drift logic to test threshold and hysteresis cuts
        if (waveUp) {
            currentTemp += 0.5f;
            currentHum += 0.2f;
            if (currentTemp >= 32.5f) waveUp = false;
        } else {
            currentTemp -= 0.5f;
            currentHum -= 0.2f;
            if (currentTemp <= 27.5f) waveUp = true;
        }
#endif

        // Construct event and push to bus
        AppEvent sensorEvent;
        sensorEvent.type = EVENT_SENSOR_TELEMETRY;
        sensorEvent.timestamp = millis();
        sensorEvent.payload.sensor.temperature = currentTemp;
        sensorEvent.payload.sensor.humidity = currentHum;

        EventBus::getInstance().pushEvent(sensorEvent, false);
    }
}

void TaskManager::runCore1Task(void* parameter) {
    Serial.printf("[TASK_CORE1] Application Coordinator Task started on Core %d\n", xPortGetCoreID());
    EventBus& eventBus = EventBus::getInstance();
    AppEvent event;
    int idx = -1;

    while (true) {
        if (eventBus.popEvent(event, idx, portMAX_DELAY)) {
            
            switch (event.type) {
                case EVENT_PHYSICAL_SWITCH_TOGGLED:
                    Serial.printf("[COORDINATOR] Physical Switch Event -> Pin: %d, State: %d\n", 
                                  event.payload.physicalSwitch.pin, 
                                  event.payload.physicalSwitch.state);
                    break;
                case EVENT_SENSOR_TELEMETRY: {
                    Serial.printf("[COORDINATOR] Sensor Telemetry -> Temp: %.2fC, Humid: %.2f%%\n", 
                                  event.payload.sensor.temperature, 
                                  event.payload.sensor.humidity);
                    
                    // 1. Evaluate Rule Engine Hysteresis check
                    RuleEngine::getInstance().evaluateRules(event.payload.sensor.temperature, event.payload.sensor.humidity);

                    // 2. Publish split encrypted sensor status with uptime back to HiveMQ
                    char statePayload[128];
                    unsigned long uptime = millis() / 1000;
                    if (event.payload.sensor.temperature == 0.0 && event.payload.sensor.humidity == 0.0) {
                        snprintf(statePayload, sizeof(statePayload), 
                                 "{\"uptime\":%lu}", uptime);
                        MqttManager::getInstance().publish("sensors/uptime", statePayload, true);
                    } else {
                        // Publish Temperature
                        snprintf(statePayload, sizeof(statePayload), 
                                 "{\"value\":%.2f,\"uptime\":%lu}", 
                                 event.payload.sensor.temperature, uptime);
                        MqttManager::getInstance().publish("sensors/temperature", statePayload, true);
                        
                        // Publish Humidity
                        snprintf(statePayload, sizeof(statePayload), 
                                 "{\"value\":%.2f,\"uptime\":%lu}", 
                                 event.payload.sensor.humidity, uptime);
                        MqttManager::getInstance().publish("sensors/humidity", statePayload, true);
                    }
                    break;
                }
                case EVENT_NETWORK_COMMAND: {
                    Serial.printf("[COORDINATOR] Encrypted Network Command Received: %s\n", event.payload.network.command);
                    
                    String rawMsg(event.payload.network.command);
                    int colonPos = rawMsg.indexOf(':');
                    if (colonPos != -1) {
                        String timestamp = rawMsg.substring(0, colonPos);
                        String base64Payload = rawMsg.substring(colonPos + 1);
                        
                        String plainText;
                        if (CryptoHelper::getInstance().verifyAndDecrypt(base64Payload, timestamp, plainText)) {
                            Serial.printf("[COORDINATOR] Decryption Successful. Plaintext Command: %s\n", plainText.c_str());
                        } else {
                            Serial.println(F("[COORDINATOR] Security Violation: Decryption or time-window validation failed!"));
                        }
                    } else {
                        Serial.println(F("[COORDINATOR] Error: Invalid network command formatting (missing timestamp colon)!"));
                    }
                    break;
                }
                case EVENT_SYSTEM_ALERT: {
                    Serial.printf("[COORDINATOR] System Alert -> Code: %d, Msg: %s\n", 
                                  event.payload.system.code, 
                                  event.payload.system.message);
                     
                    // If alert code is 200 (relay state change alert), publish new state to HiveMQ states/fan_relay
                    if (event.payload.system.code == 200) {
                        char statePayload[128];
                        snprintf(statePayload, sizeof(statePayload), 
                                 "{\"relay_state\":\"%s\"}", 
                                 event.payload.system.message);
                        MqttManager::getInstance().publish("states/fan_relay", statePayload, true);
                    }
                    break;
                }
                default:
                    Serial.println(F("[COORDINATOR] Warning: Unknown Event Type!"));
                    break;
            }

            eventBus.releaseSlot(idx);
        }
    }
}
