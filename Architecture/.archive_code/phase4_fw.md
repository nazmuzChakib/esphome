<files>
<file name="ESPHome.ino">
<![CDATA[
#include <Arduino.h>
#include "src/Storage/StorageManager.h"
#include "src/Core/EventBus.h"
#include "src/Core/TaskManager.h"
#include "src/Core/HardwareManager.h"
#include "src/Core/SwitchHandler.h"
#include "src/Core/RuleEngine.h"
#include "src/Network/AppNetworkManager.h"
#include "src/Security/CryptoHelper.h"

// Timing variables
unsigned long lastHeapPrintTime = 0;
const unsigned long HEAP_PRINT_INTERVAL = 10000; // 10 seconds

// Test switch instance
SwitchHandler* switchRoom = NULL;

void runCryptoParityTest() {
    Serial.println(F("\n--- [CRYPTO_TEST] Starting Crypto Parity Validation ---"));
    
    String timestamp = "1716900000";
    String plainText = "{\"data\":\"HelloWorld\",\"mac4\":\"" + CryptoHelper::getInstance().getDeviceMac4() + "\"}";
    
    Serial.printf("[CRYPTO_TEST] Plaintext: %s\n", plainText.c_str());
    
    // 1. Encrypt plain text using session key derived from timestamp
    String encrypted = CryptoHelper::getInstance().encrypt(plainText, timestamp);
    Serial.printf("[CRYPTO_TEST] Encrypted Base64 (IV||Ciphertext): %s\n", encrypted.c_str());
    
    // 2. Decrypt and check time window / mac4
    String decrypted;
    if (CryptoHelper::getInstance().verifyAndDecrypt(encrypted, timestamp, decrypted)) {
        Serial.printf("[CRYPTO_TEST] Decryption successful! Output: %s\n", decrypted.c_str());
        Serial.println(F("[CRYPTO_TEST] Status: SUCCESS"));
    } else {
        Serial.println(F("[CRYPTO_TEST] Status: FAILED"));
    }
    
    Serial.println(F("--- [CRYPTO_TEST] Crypto Parity Validation Finished ---\n"));
}

void runEventBusStressTest() {
    Serial.println(F("\n--- [STRESS_TEST] Starting Event Bus Overflow Test ---"));
    delay(1000); // Allow startup task logs to finish printing

    // Warm up CryptoHelper/mbedtls to trigger first-use persistent allocations
    uint8_t dummyKey[16];
    CryptoHelper::getInstance().deriveSessionKey("1716900000", dummyKey);
    CryptoHelper::getInstance().encrypt("warmup", "1716900000");

    size_t initialHeap = ESP.getFreeHeap();
    Serial.printf("[STRESS_TEST] Initial Free Heap: %d Bytes\n", initialHeap);

    // 1. Push 10 Sensor events
    Serial.println(F("[STRESS_TEST] Pushing 10 Sensor Telemetry events..."));
    for (int i = 1; i <= 10; i++) {
        AppEvent ev;
        ev.type = EVENT_SENSOR_TELEMETRY;
        ev.timestamp = millis();
        ev.payload.sensor.temperature = 22.5f + i;
        ev.payload.sensor.humidity = 45.0f + i;
        EventBus::getInstance().pushEvent(ev, false);
    }

    // 2. Push 20 Switch events (triggers overflow)
    Serial.println(F("[STRESS_TEST] Pushing 20 Switch Toggled events (Drop-Oldest)..."));
    for (int i = 1; i <= 20; i++) {
        AppEvent ev;
        ev.type = EVENT_PHYSICAL_SWITCH_TOGGLED;
        ev.timestamp = millis();
        ev.payload.physicalSwitch.pin = 4;
        ev.payload.physicalSwitch.state = (i % 2 == 0);
        EventBus::getInstance().pushEvent(ev, false);
    }

    EventBus& eb = EventBus::getInstance();
    Serial.printf("[STRESS_TEST] Burst completed. Current drops in memory -> Switch: %d, Sensor: %d\n", 
                  eb.getSwitchDropCount(), eb.getSensorDropCount());
    
    // Save drop count to flash
    eb.saveCrashLogs();

    // 3. Wait for TaskCore1 (Coordinator) to process all elements and release slots
    Serial.println(F("[STRESS_TEST] Waiting 3 seconds for Coordinator to empty the queue..."));
    delay(3000);

    size_t finalHeap = ESP.getFreeHeap();
    Serial.printf("[STRESS_TEST] Final Free Heap (after processing completes): %d Bytes\n", finalHeap);
    Serial.printf("[STRESS_TEST] Heap Leakage/Delta: %d Bytes (Should be 0, proving heap-safety & OOM-prevention)\n", 
                  (int)initialHeap - (int)finalHeap);
    
    Serial.println(F("--- [STRESS_TEST] Event Bus Overflow Test Completed ---\n"));
}

void handleSystemSerialCommand(const String& cmd) {
    String command = cmd;
    command.trim();

    if (command == "STATUS") {
        Serial.println(F("\n=== System Status ==="));
        Serial.printf("Free Heap: %d Bytes | Max Alloc Block: %d Bytes\n", ESP.getFreeHeap(), ESP.getMaxAllocHeap());
        Serial.printf("Uptime: %lu seconds\n", millis() / 1000);
        Serial.printf("NTP Synced: %s\n", time(nullptr) > 1000000 ? "YES" : "NO");
        Serial.printf("WiFi Connected: %s\n", AppNetworkManager::getInstance().isConnected() ? "YES" : "NO");
        HardwareManager::getInstance().printRegistrations();
    } 
    else if (command.startsWith("DELETELOAD ")) {
        String pinStr = command.substring(11);
        uint8_t pin = pinStr.toInt();
        if (HardwareManager::getInstance().canDeleteLoad(pin)) {
            HardwareManager::getInstance().unregisterPin(pin);
        }
    } 
    else if (command == "TESTCRYPTO") {
        runCryptoParityTest();
    }
    else if (command.startsWith("SET_HYSTERESIS ")) {
        String valStr = command.substring(15);
        float val = valStr.toFloat();
        RuleEngine::getInstance().setHysteresis(val);
    }
    else {
        Serial.printf("[SYS] Error: Unknown system command '%s'\n", command.c_str());
    }
}

void processSerialInput() {
    static char serialBuffer[256];
    static int bufferIndex = 0;

    while (Serial.available() > 0) {
        char incomingChar = Serial.read();

        // Detect end of line
        if (incomingChar == '\n' || incomingChar == '\r') {
            if (bufferIndex > 0) {
                serialBuffer[bufferIndex] = '\0';
                String inputStr(serialBuffer);
                inputStr.trim();

                // Route prefix
                if (inputStr.startsWith("WIFI:")) {
                    String wifiCmd = inputStr.substring(5);
                    AppNetworkManager::getInstance().executeWifiCommand(wifiCmd);
                } 
                else if (inputStr.startsWith("SYS:")) {
                    String sysCmd = inputStr.substring(4);
                    handleSystemSerialCommand(sysCmd);
                } 
                else {
                    Serial.println(F("[MAIN] Error: Commands must be prefixed with 'WIFI:' or 'SYS:'!"));
                }

                bufferIndex = 0; // Reset buffer
            }
        } else {
            // Buffer overflow protection
            if (bufferIndex < sizeof(serialBuffer) - 1) {
                serialBuffer[bufferIndex++] = incomingChar;
            } else {
                bufferIndex = 0;
                Serial.println(F("[MAIN] Error: Serial input buffer overflow!"));
            }
        }
    }
}

void setup() {
    Serial.begin(115200);
    delay(1000); // Allow hardware serial port to initialize
    Serial.println(F("\n=== ESPHome Firmware v2.1 Basic Structure Booting ==="));

    // 1. Initialize Storage Subsystem (LittleFS)
    if (!StorageManager::getInstance().begin()) {
        Serial.println(F("[MAIN] Fatal: StorageManager initialization failed!"));
        return;
    }

    // 2. Initialize Event Bus (Pre-allocated pool & queues)
    if (!EventBus::getInstance().begin()) {
        Serial.println(F("[MAIN] Fatal: EventBus initialization failed!"));
        return;
    }

    // 3. Initialize Rule Engine configurations
    if (!RuleEngine::getInstance().begin()) {
        Serial.println(F("[MAIN] Warning: RuleEngine initialization failed!"));
    }

    // 4. Spawn Dual-Core Tasks (Core 0 and Core 1)
    if (!TaskManager::getInstance().begin()) {
        Serial.println(F("[MAIN] Fatal: TaskManager initialization failed!"));
        return;
    }

    // 5. Hardware Pin and ID Validation check
    Serial.println(F("\n[MAIN] Starting Pin Registration Validations..."));
    
    // Register the dummy "fan_relay" actuator on GPIO 13 for Rule Engine control
    HardwareManager::getInstance().registerPin(13, OUTPUT, "fan_relay");
    pinMode(13, OUTPUT);
    digitalWrite(13, LOW);

    // Test case A: Valid toggle switch registration
    switchRoom = new SwitchHandler(4, false, "Reading_Room_Light");
    switchRoom->begin(); // Registers GPIO 4 as INPUT_PULLUP, scans boot state, attaches interrupt
 
    // Test case B: Pin Conflict (Attempting to register GPIO 4 to another switch)
    Serial.println(F("[MAIN] Testing Pin Conflict Validation (Expecting Error)..."));
    SwitchHandler switchConflict(4, true, "Critical_Pump");
    if (!switchConflict.begin()) {
        Serial.println(F("[MAIN] Conflict detected successfully: Registration rejected."));
    }

    // Test case C: Blacklisted Pin (Attempting to register SPI Flash pin GPIO 6)
    Serial.println(F("[MAIN] Testing Blacklisted Pin Validation (Expecting Error)..."));
    SwitchHandler switchSPIFlash(6, false, "SPI_Flash_Reserved");
    if (!switchSPIFlash.begin()) {
        Serial.println(F("[MAIN] Blacklisted pin detected successfully: Registration rejected."));
    }

    // Test case D: Critical Load deletion validation
    Serial.println(F("[MAIN] Testing Load Deletion Safety Checks..."));
    
    // Normal load deletion validation (should be allowed)
    HardwareManager::getInstance().registerPin(15, OUTPUT, "Normal_Fan");
    if (HardwareManager::getInstance().canDeleteLoad(15)) {
        HardwareManager::getInstance().unregisterPin(15);
    }

    // Critical load deletion validation (should be blocked)
    HardwareManager::getInstance().registerPin(15, OUTPUT, "Critical_Core_Cooler");
    if (!HardwareManager::getInstance().canDeleteLoad(15)) {
        Serial.println(F("[MAIN] Safety validator successfully blocked deletion of Critical_Core_Cooler."));
    }
    // Clean up
    HardwareManager::getInstance().unregisterPin(15);

    // Print active registrations list
    HardwareManager::getInstance().printRegistrations();

    // 6. Run Event Bus Stress Test (overflow check)
    runEventBusStressTest();

    // 7. Test Coalesced Delayed Saves (scheduling saves)
    Serial.println(F("[MAIN] Triggering coalesced writes for loads.json and states.json..."));
    StorageManager::getInstance().scheduleDelayedWrite(false, true /* loads.json */, true /* states.json */);

    Serial.println(F("[MAIN] Boot sequence completed successfully."));
}

void loop() {
    unsigned long currentMillis = millis();

    // Process serial inputs (WIFI: and SYS: commands)
    processSerialInput();

    // Process any scheduled delayed flash writes (coalesced 3s check)
    StorageManager::getInstance().processDelayedSave();

    // Periodically print heap statistics and event bus drop counts
    if (currentMillis - lastHeapPrintTime >= HEAP_PRINT_INTERVAL) {
        lastHeapPrintTime = currentMillis;
        
        size_t freeHeap = ESP.getFreeHeap();
        size_t maxAllocHeap = ESP.getMaxAllocHeap();
        
        Serial.printf("[SYSTEM LOG] Free Heap: %d Bytes | Max Alloc Block: %d Bytes\n", freeHeap, maxAllocHeap);
        
        EventBus& eb = EventBus::getInstance();
        Serial.printf("[SYSTEM LOG] Event Bus Drop Stats -> Switch Drops: %d | Sensor Drops: %d\n", 
                      eb.getSwitchDropCount(), eb.getSensorDropCount());
    }

    // Yield control to let low-priority FreeRTOS idle tasks clean up deleted resources
    delay(100);
}

]]>
</file>
<file name="src\Core\EventBus.cpp">
<![CDATA[
#include "EventBus.h"
#include "../Storage/StorageManager.h"

EventBus& EventBus::getInstance() {
    static EventBus instance;
    return instance;
}

EventBus::EventBus() 
    : _freeSlotQueue(NULL), _eventQueue(NULL), _switchDropCount(0), _sensorDropCount(0) {
}

bool EventBus::begin() {
    Serial.println(F("[EVENT_BUS] Initializing Event Bus..."));
    
    _freeSlotQueue = xQueueCreate(EVENT_POOL_SIZE, sizeof(int));
    _eventQueue = xQueueCreate(EVENT_POOL_SIZE, sizeof(int));
    
    if (_freeSlotQueue == NULL || _eventQueue == NULL) {
        Serial.println(F("[EVENT_BUS] Error: Failed to create FreeRTOS queues!"));
        return false;
    }
    
    // Initialize pool slots and populate the freeSlotQueue
    for (int i = 0; i < EVENT_POOL_SIZE; i++) {
        _eventPool[i].type = EVENT_NONE;
        _eventPool[i].timestamp = 0;
        
        if (xQueueSend(_freeSlotQueue, &i, portMAX_DELAY) != pdTRUE) {
            Serial.printf("[EVENT_BUS] Error: Failed to populate free slot queue at index %d!\n", i);
            return false;
        }
    }
    
    Serial.println(F("[EVENT_BUS] Event Bus initialized successfully with 16 pre-allocated slots."));
    return true;
}

bool EventBus::pushEvent(const AppEvent& event, bool fromISR) {
    int freeIdx = -1;
    
    if (fromISR) {
        BaseType_t pxHigherPriorityTaskWoken = pdFALSE;
        
        // Non-blocking attempt to get a free slot
        if (xQueueReceiveFromISR(_freeSlotQueue, &freeIdx, &pxHigherPriorityTaskWoken) == pdTRUE) {
            _eventPool[freeIdx] = event;
            if (xQueueSendToBackFromISR(_eventQueue, &freeIdx, &pxHigherPriorityTaskWoken) == pdTRUE) {
                if (pxHigherPriorityTaskWoken == pdTRUE) {
                    portYIELD_FROM_ISR();
                }
                return true;
            }
            // If pushing to eventQueue failed (should not happen if size matches), return to free list
            xQueueSendToBackFromISR(_freeSlotQueue, &freeIdx, &pxHigherPriorityTaskWoken);
            return false;
        } else {
            // Pool Exhausted in ISR context
            if (event.type == EVENT_PHYSICAL_SWITCH_TOGGLED) {
                // Drop-oldest: pop oldest active event index
                int oldestIdx = -1;
                if (xQueueReceiveFromISR(_eventQueue, &oldestIdx, &pxHigherPriorityTaskWoken) == pdTRUE) {
                    _switchDropCount++;
                    _eventPool[oldestIdx] = event; // Overwrite data
                    xQueueSendToBackFromISR(_eventQueue, &oldestIdx, &pxHigherPriorityTaskWoken);
                    if (pxHigherPriorityTaskWoken == pdTRUE) {
                        portYIELD_FROM_ISR();
                    }
                    return true;
                }
            } else {
                _sensorDropCount++;
            }
            return false;
        }
    } else {
        // Non-ISR context
        if (xQueueReceive(_freeSlotQueue, &freeIdx, 0) == pdTRUE) {
            _eventPool[freeIdx] = event;
            if (xQueueSendToBack(_eventQueue, &freeIdx, portMAX_DELAY) == pdTRUE) {
                return true;
            }
            xQueueSendToBack(_freeSlotQueue, &freeIdx, portMAX_DELAY);
            return false;
        } else {
            // Pool Exhausted in task context
            if (event.type == EVENT_PHYSICAL_SWITCH_TOGGLED) {
                // Drop-oldest
                int oldestIdx = -1;
                if (xQueueReceive(_eventQueue, &oldestIdx, 0) == pdTRUE) {
                    _switchDropCount++;
                    Serial.printf("[EVENT_BUS] Pool exhausted! Drop-oldest switch event at slot %d.\n", oldestIdx);
                    _eventPool[oldestIdx] = event; // Overwrite data
                    xQueueSendToBack(_eventQueue, &oldestIdx, portMAX_DELAY);
                    return true;
                }
            }
            
            // Drop-newest for sensor or other events
            if (event.type == EVENT_SENSOR_TELEMETRY) {
                _sensorDropCount++;
                Serial.println(F("[EVENT_BUS] Pool exhausted! Drop-newest sensor telemetry event."));
            } else {
                Serial.println(F("[EVENT_BUS] Pool exhausted! Drop-newest event."));
            }
            return false;
        }
    }
}

bool EventBus::popEvent(AppEvent& outEvent, int& outIdx, TickType_t timeout) {
    int idx = -1;
    if (xQueueReceive(_eventQueue, &idx, timeout) == pdTRUE) {
        outEvent = _eventPool[idx];
        outIdx = idx;
        return true;
    }
    return false;
}

void EventBus::releaseSlot(int idx) {
    if (idx >= 0 && idx < EVENT_POOL_SIZE) {
        // Clear slot data to avoid dangling references
        _eventPool[idx].type = EVENT_NONE;
        _eventPool[idx].timestamp = 0;
        
        // Return slot index to free list
        xQueueSendToBack(_freeSlotQueue, &idx, portMAX_DELAY);
    }
}

uint32_t EventBus::getSwitchDropCount() const {
    return _switchDropCount;
}

uint32_t EventBus::getSensorDropCount() const {
    return _sensorDropCount;
}

void EventBus::saveCrashLogs() {
    String logPayload = "{\"switch_drop_count\":" + String(_switchDropCount) + 
                        ",\"sensor_drop_count\":" + String(_sensorDropCount) + "}";
    if (StorageManager::getInstance().writeFile("/crash_logs.json", logPayload)) {
        Serial.println(F("[EVENT_BUS] Crash logs updated in LittleFS."));
    }
}

]]>
</file>
<file name="src\Core\EventBus.h">
<![CDATA[
#ifndef EVENT_BUS_H
#define EVENT_BUS_H

#include <Arduino.h>

#define EVENT_POOL_SIZE 32

enum EventType {
    EVENT_NONE = 0,
    EVENT_PHYSICAL_SWITCH_TOGGLED,
    EVENT_SENSOR_TELEMETRY,
    EVENT_NETWORK_COMMAND,
    EVENT_SYSTEM_ALERT
};

struct AppEvent {
    EventType type;
    unsigned long timestamp;
    union {
        struct {
            uint8_t pin;
            uint8_t state;
        } physicalSwitch;
        struct {
            float temperature;
            float humidity;
        } sensor;
        struct {
            char command[128];
        } network;
        struct {
            char message[64];
            uint8_t code;
        } system;
    } payload;
};

class EventBus {
public:
    static EventBus& getInstance();

    bool begin();
    
    // Pushes an event to the bus.
    // Handles static pool slot allocation and drop policies.
    bool pushEvent(const AppEvent& event, bool fromISR = false);
    
    // Retrieves an event from the bus. Puts the event details in outEvent and slot index in outIdx.
    bool popEvent(AppEvent& outEvent, int& outIdx, TickType_t timeout = portMAX_DELAY);
    
    // Releases the processed slot index back to the free list.
    void releaseSlot(int idx);

    // Getters for dropped event counters
    uint32_t getSwitchDropCount() const;
    uint32_t getSensorDropCount() const;
    
    // Thread-safe crash logging to LittleFS
    void saveCrashLogs();

private:
    EventBus();
    ~EventBus() = default;
    EventBus(const EventBus&) = delete;
    EventBus& operator=(const EventBus&) = delete;

    AppEvent _eventPool[EVENT_POOL_SIZE];
    QueueHandle_t _freeSlotQueue = NULL;
    QueueHandle_t _eventQueue = NULL;

    volatile uint32_t _switchDropCount = 0;
    volatile uint32_t _sensorDropCount = 0;
};

#endif // EVENT_BUS_H

]]>
</file>
<file name="src\Core\HardwareManager.cpp">
<![CDATA[
#include "HardwareManager.h"

HardwareManager::HardwareManager() : _registrationCount(0) {
    for (int i = 0; i < MAX_PIN_REGISTRATIONS; i++) {
        _registrations[i].pin = 255; // Sentinel value indicating unassigned
        _registrations[i].mode = 0;
        _registrations[i].owner[0] = '\0';
    }
}

HardwareManager& HardwareManager::getInstance() {
    static HardwareManager instance;
    return instance;
}

bool HardwareManager::isGPIOValid(uint8_t pin, uint8_t mode) const {
    // 1. Out of range check (ESP32 has pins 0 to 39)
    if (pin >= 40) {
        Serial.printf("[HW_MGR] Error: Pin %d is out of valid ESP32 GPIO range (0-39)!\n", pin);
        return false;
    }

    // 2. Blacklist flash SPI pins (GPIO 6-11)
    if (pin >= 6 && pin <= 11) {
        Serial.printf("[HW_MGR] Error: Pin %d is used by SPI flash memory and cannot be re-assigned!\n", pin);
        return false;
    }

    // 3. Input-only pins check (GPIO 34-39 are input only and lack pullup/pulldown capability)
    if (pin >= 34 && pin <= 39) {
        if (mode == OUTPUT) {
            Serial.printf("[HW_MGR] Error: Pins 34-39 are input-only. Pin %d cannot be set as OUTPUT!\n", pin);
            return false;
        }
    }

    return true;
}

bool HardwareManager::isPinRegistered(uint8_t pin) const {
    for (int i = 0; i < _registrationCount; i++) {
        if (_registrations[i].pin == pin) {
            return true;
        }
    }
    return false;
}

bool HardwareManager::registerPin(uint8_t pin, uint8_t mode, const char* owner) {
    // 1. Verify if GPIO is compatible
    if (!isGPIOValid(pin, mode)) {
        return false;
    }

    // 2. Check for duplicate registration conflict
    for (int i = 0; i < _registrationCount; i++) {
        if (_registrations[i].pin == pin) {
            Serial.printf("[HW_MGR] Conflict Error: Pin %d is already registered by '%s'!\n", 
                          pin, _registrations[i].owner);
            return false;
        }
    }

    // 3. Check registration array bounds
    if (_registrationCount >= MAX_PIN_REGISTRATIONS) {
        Serial.println(F("[HW_MGR] Error: Maximum pin registrations exceeded!"));
        return false;
    }

    // 4. Save registration
    _registrations[_registrationCount].pin = pin;
    _registrations[_registrationCount].mode = mode;
    strncpy(_registrations[_registrationCount].owner, owner, sizeof(_registrations[_registrationCount].owner) - 1);
    _registrations[_registrationCount].owner[sizeof(_registrations[_registrationCount].owner) - 1] = '\0';
    
    _registrationCount++;
    Serial.printf("[HW_MGR] Registered Pin %d (Mode: %d) to owner '%s'.\n", pin, mode, owner);
    return true;
}

void HardwareManager::unregisterPin(uint8_t pin) {
    int foundIdx = -1;
    for (int i = 0; i < _registrationCount; i++) {
        if (_registrations[i].pin == pin) {
            foundIdx = i;
            break;
        }
    }

    if (foundIdx != -1) {
        Serial.printf("[HW_MGR] Unregistered Pin %d (formerly owned by '%s').\n", 
                      pin, _registrations[foundIdx].owner);
        
        // Shift remaining elements left
        for (int i = foundIdx; i < _registrationCount - 1; i++) {
            _registrations[i] = _registrations[i + 1];
        }
        
        _registrationCount--;
        // Clean trailing slot
        _registrations[_registrationCount].pin = 255;
        _registrations[_registrationCount].mode = 0;
        _registrations[_registrationCount].owner[0] = '\0';
    }
}

bool HardwareManager::canDeleteLoad(uint8_t pin) {
    int foundIdx = -1;
    for (int i = 0; i < _registrationCount; i++) {
        if (_registrations[i].pin == pin) {
            foundIdx = i;
            break;
        }
    }

    if (foundIdx == -1) {
        Serial.printf("[HW_MGR] Deletion validation: Pin %d is not registered. Safe to delete.\n", pin);
        return true;
    }

    // If it is registered as an output load, check if it has critical constraints
    // (In Phase 4, we will check the Rule Engine configuration here)
    Serial.printf("[HW_MGR] Validating delete request for load '%s' on Pin %d. Checking constraints...\n", 
                  _registrations[foundIdx].owner, pin);

    // For safety, we reject deletion if the owner name starts with "Critical_"
    if (strncmp(_registrations[foundIdx].owner, "Critical_", 9) == 0) {
        Serial.printf("[HW_MGR] Deletion Rejected: '%s' is a critical safety load!\n", 
                      _registrations[foundIdx].owner);
        return false;
    }

    Serial.printf("[HW_MGR] Deletion Allowed for load '%s'.\n", _registrations[foundIdx].owner);
    return true;
}

void HardwareManager::printRegistrations() const {
    Serial.println(F("\n--- Current Active Pin Registrations ---"));
    for (int i = 0; i < _registrationCount; i++) {
        Serial.printf("Slot %d: GPIO %d | Mode: %d | Owner: %s\n", 
                      i, _registrations[i].pin, _registrations[i].mode, _registrations[i].owner);
    }
    Serial.println(F("----------------------------------------\n"));
}

]]>
</file>
<file name="src\Core\HardwareManager.h">
<![CDATA[
#ifndef HARDWARE_MANAGER_H
#define HARDWARE_MANAGER_H

#include <Arduino.h>

#define MAX_PIN_REGISTRATIONS 32

struct PinRegistration {
    uint8_t pin;
    uint8_t mode; // e.g., INPUT, OUTPUT, INPUT_PULLUP
    char owner[32]; // Name or ID of module registering the pin
};

class HardwareManager {
public:
    static HardwareManager& getInstance();

    // Validates and registers a GPIO pin. Returns true if successful.
    bool registerPin(uint8_t pin, uint8_t mode, const char* owner);

    // Unregisters a registered GPIO pin.
    void unregisterPin(uint8_t pin);

    // Checks if a GPIO pin is currently registered.
    bool isPinRegistered(uint8_t pin) const;

    // Checks if a GPIO pin is hardware-compatible on ESP32 for the specified mode.
    bool isGPIOValid(uint8_t pin, uint8_t mode) const;

    // Validator checking if a load (actuator/relay pin) can be safely deleted.
    // Returns true if no active configurations or safety limits prevent deletion.
    bool canDeleteLoad(uint8_t pin);

    // Debug helper to print all currently active registrations to the Serial interface.
    void printRegistrations() const;

private:
    HardwareManager();
    ~HardwareManager() = default;
    HardwareManager(const HardwareManager&) = delete;
    HardwareManager& operator=(const HardwareManager&) = delete;

    PinRegistration _registrations[MAX_PIN_REGISTRATIONS];
    int _registrationCount = 0;
};

#endif // HARDWARE_MANAGER_H

]]>
</file>
<file name="src\Core\RuleEngine.cpp">
<![CDATA[
#include "RuleEngine.h"
#include "../Storage/StorageManager.h"
#include "HardwareManager.h"
#include "EventBus.h"

RuleEngine::RuleEngine() : _hysteresis(0.5f), _relayState(false) {
}

RuleEngine& RuleEngine::getInstance() {
    static RuleEngine instance;
    return instance;
}

bool RuleEngine::begin() {
    Serial.println(F("[RULE_ENGINE] Initializing Rule Engine..."));

    // Check rules.json config
    if (!StorageManager::getInstance().fileExists("/rules.json")) {
        Serial.println(F("[RULE_ENGINE] rules.json not found. Initializing with empty state."));
        StorageManager::getInstance().writeStaticFile("/rules.json", "null");
    } else {
        Serial.println(F("[RULE_ENGINE] rules.json loaded successfully."));
    }

    return true;
}

void RuleEngine::evaluateRules(float temperature, float humidity) {
    // We target a dummy load "fan_relay" registered on GPIO 13
    if (HardwareManager::getInstance().isPinRegistered(13)) {
        float threshold = 30.0f;
        bool targetState = _relayState;

        // Cooling rule with dynamic hysteresis check
        if (temperature >= threshold && !_relayState) {
            targetState = true;
            Serial.printf("[RULE_ENGINE] Temp (%.2fC) >= Threshold (%.2fC). Triggering Relay ON.\n", 
                          temperature, threshold);
        } 
        else if (temperature < (threshold - _hysteresis) && _relayState) {
            targetState = false;
            Serial.printf("[RULE_ENGINE] Temp (%.2fC) < Cut-off (%.2fC) (Hysteresis: %.2fC). Triggering Relay OFF.\n", 
                          temperature, threshold - _hysteresis, _hysteresis);
        }

        // If relay state changed, apply output and dispatch alert to EventBus
        if (targetState != _relayState) {
            _relayState = targetState;
            digitalWrite(13, _relayState ? HIGH : LOW);

            AppEvent alertEvent;
            alertEvent.type = EVENT_SYSTEM_ALERT;
            alertEvent.timestamp = millis();
            alertEvent.payload.system.code = 200; // Relay change event code
            snprintf(alertEvent.payload.system.message, sizeof(alertEvent.payload.system.message), 
                     "Actuator GPIO 13 state changed to %s", _relayState ? "ON" : "OFF");

            EventBus::getInstance().pushEvent(alertEvent, false);
        }
    }
}

void RuleEngine::setHysteresis(float val) {
    if (val >= 0.0f) {
        _hysteresis = val;
        Serial.printf("[RULE_ENGINE] Hysteresis updated dynamically to %.2fC.\n", _hysteresis);
    }
}

float RuleEngine::getHysteresis() const {
    return _hysteresis;
}

]]>
</file>
<file name="src\Core\RuleEngine.h">
<![CDATA[
#ifndef RULE_ENGINE_H
#define RULE_ENGINE_H

#include <Arduino.h>

class RuleEngine {
public:
    static RuleEngine& getInstance();

    // Initialized rule configurations from rules.json
    bool begin();
    
    // Core 1 Evaluation: Process sensor values and toggle relay outputs under hysteresis limits
    void evaluateRules(float temperature, float humidity);

    // Getters/Setters for dynamic user-defined hysteresis bands
    void setHysteresis(float val);
    float getHysteresis() const;

private:
    RuleEngine();
    ~RuleEngine() = default;
    RuleEngine(const RuleEngine&) = delete;
    RuleEngine& operator=(const RuleEngine&) = delete;

    float _hysteresis;
    bool _relayState; 
};

#endif // RULE_ENGINE_H

]]>
</file>
<file name="src\Core\SwitchHandler.cpp">
<![CDATA[
#include "SwitchHandler.h"
#include "HardwareManager.h"

SwitchHandler::SwitchHandler(uint8_t pin, bool isPushButton, const char* owner)
    : _pin(pin), _isPushButton(isPushButton), _lastInterruptTime(0), _logicalState(false), _initialized(false) {
    strncpy(_owner, owner, sizeof(_owner) - 1);
    _owner[sizeof(_owner) - 1] = '\0';
}

SwitchHandler::~SwitchHandler() {
    if (_initialized) {
        detachInterrupt(_pin);
        HardwareManager::getInstance().unregisterPin(_pin);
    }
}

bool SwitchHandler::begin() {
    // 1. Register pin through HardwareManager to prevent configuration conflicts
    if (!HardwareManager::getInstance().registerPin(_pin, INPUT_PULLUP, _owner)) {
        Serial.printf("[SWITCH] Error: Failed to register GPIO %d for '%s'!\n", _pin, _owner);
        return false;
    }

    // 2. Configure physical pin mode
    pinMode(_pin, INPUT_PULLUP);

    // 3. Scan physical state on startup (boot-time scan)
    uint8_t physicalVal = digitalRead(_pin);
    if (_isPushButton) {
        // Momentary button starts off logically
        _logicalState = false;
    } else {
        // Toggle switches map directly (LOW = switch ON, due to INPUT_PULLUP config)
        _logicalState = (physicalVal == LOW);
    }

    Serial.printf("[SWITCH] Initialized '%s' on GPIO %d. Boot-time physical state: %s. Logical State: %s\n", 
                  _owner, _pin, (physicalVal == LOW) ? "LOW" : "HIGH", _logicalState ? "ON" : "OFF");

    // 4. Send initial state to the EventBus (normal task context)
    AppEvent bootEvent;
    bootEvent.type = EVENT_PHYSICAL_SWITCH_TOGGLED;
    bootEvent.timestamp = millis();
    bootEvent.payload.physicalSwitch.pin = _pin;
    bootEvent.payload.physicalSwitch.state = _logicalState;
    
    if (!EventBus::getInstance().pushEvent(bootEvent, false)) {
        Serial.println(F("[SWITCH] Warning: Failed to send boot-time event to event bus!"));
    }

    // 5. Attach hardware interrupt with changing edge triggers
    // Pass instance pointer 'this' as argument to static handler
    attachInterruptArg(_pin, SwitchHandler::handleInterrupt, this, CHANGE);

    _initialized = true;
    return true;
}

void IRAM_ATTR SwitchHandler::handleInterrupt(void* arg) {
    SwitchHandler* handler = static_cast<SwitchHandler*>(arg);
    
    // Get uptime in milliseconds in a fast, ISR-safe manner
    uint32_t now = esp_timer_get_time() / 1000;
    
    // Software debouncing check (50ms gap)
    if (now - handler->_lastInterruptTime >= 50) {
        handler->_lastInterruptTime = now;
        
        uint8_t physicalState = digitalRead(handler->_pin);
        bool stateChanged = false;

        if (handler->_isPushButton) {
            // Push button (momentary): only toggle state on active press edge (transition to LOW)
            if (physicalState == LOW) {
                handler->_logicalState = !handler->_logicalState;
                stateChanged = true;
            }
        } else {
            // Toggle switch: transition on any physical change
            handler->_logicalState = !handler->_logicalState;
            stateChanged = true;
        }

        if (stateChanged) {
            // Package event and push onto bus from ISR context
            AppEvent event;
            event.type = EVENT_PHYSICAL_SWITCH_TOGGLED;
            event.timestamp = now;
            event.payload.physicalSwitch.pin = handler->_pin;
            event.payload.physicalSwitch.state = handler->_logicalState;

            EventBus::getInstance().pushEvent(event, true /* fromISR = true */);
        }
    }
}

]]>
</file>
<file name="src\Core\SwitchHandler.h">
<![CDATA[
#ifndef SWITCH_HANDLER_H
#define SWITCH_HANDLER_H

#include <Arduino.h>
#include "EventBus.h"

class SwitchHandler {
public:
    SwitchHandler(uint8_t pin, bool isPushButton = false, const char* owner = "Switch");
    ~SwitchHandler();

    // Initializes the switch pin, performs boot-time read, registers ISR
    bool begin();

    uint8_t getPin() const { return _pin; }
    bool getLogicalState() const { return _logicalState; }
    bool isPushButton() const { return _isPushButton; }

private:
    // Interrupt Service Routine (ISR) marked IRAM_ATTR for cache isolation
    static void IRAM_ATTR handleInterrupt(void* arg);

    uint8_t _pin;
    bool _isPushButton;
    char _owner[32];
    
    volatile uint32_t _lastInterruptTime;
    volatile bool _logicalState;
    bool _initialized;
};

#endif // SWITCH_HANDLER_H

]]>
</file>
<file name="src\Core\SystemMutex.h">
<![CDATA[
#ifndef SYSTEM_MUTEX_H
#define SYSTEM_MUTEX_H

#include <Arduino.h>

class SystemMutex {
public:
    SystemMutex() {
        _mutex = xSemaphoreCreateRecursiveMutex();
        if (_mutex == NULL) {
            Serial.println(F("[MUTEX] Error: Failed to create recursive mutex!"));
        }
    }

    ~SystemMutex() {
        if (_mutex != NULL) {
            vSemaphoreDelete(_mutex);
        }
    }

    // Disable copy constructors to avoid accidental copies of synchronization handles
    SystemMutex(const SystemMutex&) = delete;
    SystemMutex& operator=(const SystemMutex&) = delete;

    bool lock(TickType_t waitTime = portMAX_DELAY) {
        if (_mutex == NULL) return false;
        return xSemaphoreTakeRecursive(_mutex, waitTime) == pdTRUE;
    }

    void unlock() {
        if (_mutex != NULL) {
            xSemaphoreGiveRecursive(_mutex);
        }
    }

    SemaphoreHandle_t getHandle() const {
        return _mutex;
    }

private:
    SemaphoreHandle_t _mutex = NULL;
};

class LockGuard {
public:
    explicit LockGuard(SystemMutex& mutex) : _mutex(mutex) {
        _mutex.lock();
    }

    ~LockGuard() {
        _mutex.unlock();
    }

    // Disable copy constructors
    LockGuard(const LockGuard&) = delete;
    LockGuard& operator=(const LockGuard&) = delete;

private:
    SystemMutex& _mutex;
};

#endif // SYSTEM_MUTEX_H

]]>
</file>
<file name="src\Core\TaskManager.cpp">
<![CDATA[
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
// NOTE: STACK_COORDINATOR bumped from 2048 → 3072 for RuleEngine + CryptoHelper + snprintf headroom.
#define STACK_NETWORK 3072      // 12 KB for Web Server / WebSockets
#define STACK_COORDINATOR 3072  // 12 KB for Coordinator (RuleEngine + CryptoHelper + MQTT publish)
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
        vTaskDelay(pdMS_TO_TICKS(10000)); // Sleep 10s

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

                    // 2. Publish encrypted status back to HiveMQ State Topic
                    char statePayload[128];
                    snprintf(statePayload, sizeof(statePayload), 
                             "{\"temp\":%.2f,\"humid\":%.2f,\"mac4\":\"%s\"}", 
                             event.payload.sensor.temperature, 
                             event.payload.sensor.humidity, 
                             CryptoHelper::getInstance().getDeviceMac4().c_str());
                    MqttManager::getInstance().publishState(statePayload);
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
                    
                    // If alert code is 200 (relay state change alert), publish new state to HiveMQ
                    if (event.payload.system.code == 200) {
                        char statePayload[128];
                        snprintf(statePayload, sizeof(statePayload), 
                                 "{\"relay_state\":\"%s\",\"mac4\":\"%s\"}", 
                                 event.payload.system.message, 
                                 CryptoHelper::getInstance().getDeviceMac4().c_str());
                        MqttManager::getInstance().publishState(statePayload);
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

]]>
</file>
<file name="src\Core\TaskManager.h">
<![CDATA[
#ifndef TASK_MANAGER_H
#define TASK_MANAGER_H

#include <Arduino.h>

class TaskManager {
public:
    static TaskManager& getInstance();

    // Spawn all dual-core task structures (WebServer, Coordinator, Sensor, MQTT)
    bool begin();

    TaskHandle_t getCore0TaskHandle() const { return _core0TaskHandle; }
    TaskHandle_t getCore1TaskHandle() const { return _core1TaskHandle; }
    TaskHandle_t getSensorTaskHandle() const { return _sensorTaskHandle; }
    TaskHandle_t getMQTTTaskHandle() const { return _mqttTaskHandle; }

private:
    TaskManager() = default;
    ~TaskManager() = default;
    TaskManager(const TaskManager&) = delete;
    TaskManager& operator=(const TaskManager&) = delete;

    static void runCore0Task(void* parameter);
    static void runCore1Task(void* parameter);
    static void runSensorTask(void* parameter);
    static void runMQTTTask(void* parameter);

    TaskHandle_t _core0TaskHandle = NULL;
    TaskHandle_t _core1TaskHandle = NULL;
    TaskHandle_t _sensorTaskHandle = NULL;
    TaskHandle_t _mqttTaskHandle = NULL;
};

#endif // TASK_MANAGER_H

]]>
</file>
<file name="src\Network\AppNetworkManager.cpp">
<![CDATA[
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

    // 4. Register WiFiManager internal API routes (/api/*)
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
            if (!_timeSynced) {
                timestamp = "1716900000"; // Fallback test timestamp
            }
            
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

]]>
</file>
<file name="src\Network\AppNetworkManager.h">
<![CDATA[
#ifndef APP_NETWORK_MANAGER_H
#define APP_NETWORK_MANAGER_H

#include <Arduino.h>
#include <ESPWiFiManager.h>
#include <ESPAsyncWebServer.h>
#include <WiFiUdp.h>

class AppNetworkManager {
public:
    static AppNetworkManager& getInstance();

    // Initializes WiFi manager, AsyncWebServer, NTP, and UDP listeners
    bool begin();
    
    // Pump state machines (MUST be called inside TaskCore0 loop)
    void process();

    // Checked if STA is connected to an Access Point
    bool isConnected() const;

    // Thread-safe Unix timestamp getter
    unsigned long getUnixTimestamp();
    
    // Wraps WiFi credentials management over serial commands
    void executeWifiCommand(const String& cmd, Stream& io = Serial);

private:
    AppNetworkManager();
    ~AppNetworkManager() = default;
    AppNetworkManager(const AppNetworkManager&) = delete;
    AppNetworkManager& operator=(const AppNetworkManager&) = delete;

    // Callbacks for ESPWiFiManager
    void onWiFiConnected(const String& ssid, IPAddress ip);
    void onWiFiDisconnected(int reason);
    void onAPStarted(const String& ssid, IPAddress ip);
    void onAPStopped();

    // UDP discovery managers
    void checkUDPDiscovery();
    void sendDiscoveryBeacon();

    AsyncWebServer _server;
    AsyncWebSocket _ws;
    WiFiManager _wm;
    WiFiUDP _udp;

    unsigned long _lastUDPBroadcastTime;
    bool _timeSynced;
    unsigned long _lastNTPCheckTime;
};

#endif // APP_NETWORK_MANAGER_H

]]>
</file>
<file name="src\Network\MqttManager.cpp">
<![CDATA[
#include "MqttManager.h"
#include "../Storage/StorageManager.h"
#include "../Security/CryptoHelper.h"
#include "../Core/EventBus.h"
#include "AppNetworkManager.h"
#include <WiFi.h>

MqttManager::MqttManager() 
    : _mqttClient(_secureClient), _lastReconnectAttempt(0), _queueCount(0) {
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
    
    String clientId = "ESPHome-" + CryptoHelper::getInstance().getDeviceMac4();
    
    const char* user = "@esp_home";
    const char* password = "password@esp_Home"; // pass: password@esp_Home

    if (_mqttClient.connect(clientId.c_str(), user, password)) {
        Serial.printf("[MQTT] Connection SUCCESS with username '%s'! Subscribing to command topic...\n", user);

        String cmdTopic = "nodes/" + CryptoHelper::getInstance().getDeviceMac4() + "/command";
        _mqttClient.subscribe(cmdTopic.c_str());

        Serial.printf("[MQTT] Subscribed to topic: %s\n", cmdTopic.c_str());

        // Flush offline queue on successful connection
        if (_queueCount > 0) {
            Serial.printf("[MQTT] Restored connection. Flushing %d cached offline messages...\n", _queueCount);
            while (_queueCount > 0) {
                _queueCount--;
                String cachedPayload(_offlineQueue[_queueCount].payload);
                
                String stateTopic = "nodes/" + CryptoHelper::getInstance().getDeviceMac4() + "/state";
                _mqttClient.publish(stateTopic.c_str(), cachedPayload.c_str());
            }
        }
    } else {
        Serial.printf("[MQTT] Connection FAILED with username '%s'. state = %d\n", user, _mqttClient.state());
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

bool MqttManager::publishState(const String& payloadStr) {
    String timestamp = String(AppNetworkManager::getInstance().getUnixTimestamp());
    if (timestamp == "0" || timestamp.length() == 0) {
        timestamp = "1716900000"; // Fallback test timestamp
    }

    // Encrypt payload via session key K1 derived from timestamp
    String encryptedPayload = CryptoHelper::getInstance().encrypt(payloadStr, timestamp);
    String msgPacket = timestamp + ":" + encryptedPayload;

    if (_mqttClient.connected()) {
        String stateTopic = "nodes/" + CryptoHelper::getInstance().getDeviceMac4() + "/state";
        bool result = _mqttClient.publish(stateTopic.c_str(), msgPacket.c_str());
        if (result) {
            Serial.printf("[MQTT] Successfully published encrypted state payload to %s\n", stateTopic.c_str());
        }
        return result;
    } else {
        // Queue message locally if offline
        if (_queueCount < OFFLINE_QUEUE_SIZE) {
            strncpy(_offlineQueue[_queueCount].payload, msgPacket.c_str(), sizeof(_offlineQueue[_queueCount].payload) - 1);
            _offlineQueue[_queueCount].payload[sizeof(_offlineQueue[_queueCount].payload) - 1] = '\0';
            _queueCount++;
            Serial.printf("[MQTT] Client offline. Telemetry cached in local queue (size: %d/%d).\n", _queueCount, OFFLINE_QUEUE_SIZE);
        } else {
            // Drop-oldest: Shift all elements left (drops index 0)
            for (int i = 0; i < OFFLINE_QUEUE_SIZE - 1; i++) {
                memcpy(_offlineQueue[i].payload, _offlineQueue[i + 1].payload, sizeof(_offlineQueue[i].payload));
            }
            // Append the newest telemetry to the last slot
            strncpy(_offlineQueue[OFFLINE_QUEUE_SIZE - 1].payload, msgPacket.c_str(), sizeof(_offlineQueue[OFFLINE_QUEUE_SIZE - 1].payload) - 1);
            _offlineQueue[OFFLINE_QUEUE_SIZE - 1].payload[sizeof(_offlineQueue[OFFLINE_QUEUE_SIZE - 1].payload) - 1] = '\0';
            Serial.println(F("[MQTT] Offline queue full! Dropped oldest cached packet to retain latest telemetry state."));
        }
        return false;
    }
}

void MqttManager::onMessageReceived(char* topic, uint8_t* payload, unsigned int length) {
    // Safety check: ensure payload fits inside command buffer
    if (length > 0) {
        char* msg = (char*)malloc(length + 1);
        if (msg != nullptr) {
            memcpy(msg, payload, length);
            msg[length] = '\0';
            
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

]]>
</file>
<file name="src\Network\MqttManager.h">
<![CDATA[
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

    // Encrypts and publishes status payload back to HiveMQ State Topic
    bool publishState(const String& payloadStr);

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
    int _queueCount;
};

#endif // MQTT_MANAGER_H

]]>
</file>
<file name="src\Security\CryptoHelper.cpp">
<![CDATA[
#include "CryptoHelper.h"
#include "../Storage/StorageManager.h"
#include "mbedtls/md.h"
#include "mbedtls/aes.h"
#include "mbedtls/base64.h"
#include <WiFi.h>

CryptoHelper& CryptoHelper::getInstance() {
    static CryptoHelper instance;
    return instance;
}

bool CryptoHelper::deriveSessionKey(const String& timestamp, uint8_t* outKey) {
    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);
    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    
    if (info == NULL) {
        mbedtls_md_free(&ctx);
        return false;
    }

    if (mbedtls_md_setup(&ctx, info, 1) != 0) { // 1 enables HMAC
        mbedtls_md_free(&ctx);
        return false;
    }

    // Retrieve private api_key from StorageManager (system.json)
    String apiKey = StorageManager::getInstance().getPrivateKey();

    mbedtls_md_hmac_starts(&ctx, (const unsigned char*)apiKey.c_str(), apiKey.length());
    mbedtls_md_hmac_update(&ctx, (const unsigned char*)timestamp.c_str(), timestamp.length());
    
    uint8_t hmacResult[32];
    mbedtls_md_hmac_finish(&ctx, hmacResult);
    mbedtls_md_free(&ctx);

    // Truncate SHA256 digest to 128-bits (first 16 bytes) for K1 key
    memcpy(outKey, hmacResult, 16);
    return true;
}

String CryptoHelper::encrypt(const String& plainText, const String& timestamp) {
    uint8_t sessionKey[16];
    if (!deriveSessionKey(timestamp, sessionKey)) {
        return String();
    }

    int plainLen = plainText.length();
    
    // PKCS7 Padding calculation
    int paddingLen = 16 - (plainLen % 16);
    int encryptedLen = plainLen + paddingLen;

    uint8_t* inputBuffer = (uint8_t*)malloc(encryptedLen);
    uint8_t* outputBuffer = (uint8_t*)malloc(encryptedLen);
    
    if (inputBuffer == nullptr || outputBuffer == nullptr) {
        if (inputBuffer) free(inputBuffer);
        if (outputBuffer) free(outputBuffer);
        return String();
    }

    // Fill padding
    memcpy(inputBuffer, plainText.c_str(), plainLen);
    for (int i = plainLen; i < encryptedLen; i++) {
        inputBuffer[i] = paddingLen;
    }

    // Generate random 16-byte IV via ESP32 Hardware TRNG
    uint8_t iv[16];
    for (int i = 0; i < 16; i++) {
        iv[i] = esp_random() % 256;
    }

    // Copy IV as mbedtls mutates the IV buffer during encryption
    uint8_t iv_copy[16];
    memcpy(iv_copy, iv, 16);

    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    // Set 128-bit key for encryption
    mbedtls_aes_setkey_enc(&aes, sessionKey, 128);
    
    // CBC hardware-accelerated encryption
    mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_ENCRYPT, encryptedLen, iv, inputBuffer, outputBuffer);
    mbedtls_aes_free(&aes);

    // Combine: IV[16] + Ciphertext[N]
    int combinedLen = 16 + encryptedLen;
    uint8_t* combinedBuffer = (uint8_t*)malloc(combinedLen);
    if (combinedBuffer == nullptr) {
        free(inputBuffer);
        free(outputBuffer);
        return String();
    }

    memcpy(combinedBuffer, iv_copy, 16);
    memcpy(combinedBuffer + 16, outputBuffer, encryptedLen);

    // Base64 Encode
    size_t base64Len = 0;
    mbedtls_base64_encode(nullptr, 0, &base64Len, combinedBuffer, combinedLen);
    
    char* base64Output = (char*)malloc(base64Len + 1);
    if (base64Output == nullptr) {
        free(inputBuffer);
        free(outputBuffer);
        free(combinedBuffer);
        return String();
    }

    size_t written = 0;
    mbedtls_base64_encode((unsigned char*)base64Output, base64Len, &written, combinedBuffer, combinedLen);
    base64Output[written] = '\0';

    String result(base64Output);

    // Free all allocated heaps
    free(inputBuffer);
    free(outputBuffer);
    free(combinedBuffer);
    free(base64Output);

    return result;
}

String CryptoHelper::decrypt(const String& base64Payload, const String& timestamp) {
    uint8_t sessionKey[16];
    if (!deriveSessionKey(timestamp, sessionKey)) {
        return String();
    }

    // Decode Base64 payload
    size_t maxDecryptedSize = (base64Payload.length() * 3) / 4 + 2;
    uint8_t* combinedBuffer = (uint8_t*)malloc(maxDecryptedSize);
    if (combinedBuffer == nullptr) {
        return String();
    }

    size_t combinedLen = 0;
    int ret = mbedtls_base64_decode(combinedBuffer, maxDecryptedSize, &combinedLen, 
                                    (const unsigned char*)base64Payload.c_str(), base64Payload.length());
    
    if (ret != 0 || combinedLen < 32) { // Minimally 16-byte IV + 16-byte block
        free(combinedBuffer);
        return String();
    }

    // Split IV and Ciphertext
    uint8_t iv[16];
    memcpy(iv, combinedBuffer, 16);

    int cipherLen = combinedLen - 16;
    uint8_t* ciphertext = combinedBuffer + 16;

    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    mbedtls_aes_setkey_dec(&aes, sessionKey, 128);

    uint8_t* decryptedBuffer = (uint8_t*)malloc(cipherLen);
    if (decryptedBuffer == nullptr) {
        mbedtls_aes_free(&aes);
        free(combinedBuffer);
        return String();
    }

    // Decrypt CBC
    mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_DECRYPT, cipherLen, iv, ciphertext, decryptedBuffer);
    mbedtls_aes_free(&aes);

    // Strip PKCS7 padding
    uint8_t paddingVal = decryptedBuffer[cipherLen - 1];
    if (paddingVal < 1 || paddingVal > 16 || paddingVal > cipherLen) {
        free(combinedBuffer);
        free(decryptedBuffer);
        return String(); // Invalid padding
    }

    int plainLen = cipherLen - paddingVal;
    char* plainText = (char*)malloc(plainLen + 1);
    if (plainText == nullptr) {
        free(combinedBuffer);
        free(decryptedBuffer);
        return String();
    }

    memcpy(plainText, decryptedBuffer, plainLen);
    plainText[plainLen] = '\0';

    String result(plainText);

    // Free buffers
    free(combinedBuffer);
    free(decryptedBuffer);
    free(plainText);

    return result;
}

bool CryptoHelper::verifyAndDecrypt(const String& base64Payload, const String& timestamp, String& outPlainText) {
    // 1. Replay Protection (time-window verification)
    unsigned long reqTime = strtoul(timestamp.c_str(), nullptr, 10);
    if (reqTime == 0) {
        return false;
    }

    time_t now = time(nullptr);
    // Year 1970 represents unsynced clock
    if (now > 1000000) { 
        long diff = (long)now - (long)reqTime;
        if (abs(diff) > 30) {
            Serial.printf("[CRYPTO] Replay Protection: Request is out of ±30s window (Diff: %ld seconds)!\n", diff);
            return false;
        }
    } else {
        // Fallback for tests/setup when time is not synced yet
        if (reqTime == 1716900000) {
            Serial.println(F("[CRYPTO] Clock not synced. Using test timestamp fallback."));
        } else {
            Serial.println(F("[CRYPTO] Warning: Clock not synced. Bypassing time-window check."));
        }
    }

    // 2. Decrypt Payload
    String plainText = decrypt(base64Payload, timestamp);
    if (plainText.length() == 0) {
        Serial.println(F("[CRYPTO] Error: Payload decryption failed!"));
        return false;
    }

    // 3. Identity Verification (mac4 check)
    String expectedMac4 = getDeviceMac4();
    String expectedMac4Upper = expectedMac4;
    expectedMac4Upper.toUpperCase();
    String expectedMac4Lower = expectedMac4;
    expectedMac4Lower.toLowerCase();

    String matchStrUpper = "\"mac4\":\"" + expectedMac4Upper + "\"";
    String matchStrLower = "\"mac4\":\"" + expectedMac4Lower + "\"";

    if (plainText.indexOf(matchStrUpper) == -1 && plainText.indexOf(matchStrLower) == -1) {
        Serial.printf("[CRYPTO] Identity Rejected: Payload mac4 does not target this node (%s)!\n", expectedMac4Upper.c_str());
        return false;
    }

    outPlainText = plainText;
    return true;
}

String CryptoHelper::getDeviceMac4() {
    String mac = WiFi.macAddress();
    mac.replace(":", "");
    if (mac.length() >= 4) {
        return mac.substring(mac.length() - 4);
    }
    return String("0000");
}

]]>
</file>
<file name="src\Security\CryptoHelper.h">
<![CDATA[
#ifndef CRYPTO_HELPER_H
#define CRYPTO_HELPER_H

#include <Arduino.h>

class CryptoHelper {
public:
    static CryptoHelper& getInstance();

    // Derives 16-byte K1 = HMAC-SHA256(api_key, timestamp_str)[:16]
    bool deriveSessionKey(const String& timestamp, uint8_t* outKey);

    // Encrypts plainText using session key K1 derived from timestamp.
    // Generates a random 16-byte IV.
    // Returns: Base64( IV[16] || Ciphertext[N] )
    String encrypt(const String& plainText, const String& timestamp);

    // Decrypts base64Payload using session key K1 derived from timestamp and extracted IV.
    // Returns decrypted plaintext, or empty String on failure.
    String decrypt(const String& base64Payload, const String& timestamp);

    // Validates time window (±30 seconds) and decrypts the payload.
    // Checks if the decrypted payload contains valid mac4 of the current device.
    // Returns true on success.
    bool verifyAndDecrypt(const String& base64Payload, const String& timestamp, String& outPlainText);

    // Helper to get mac4 of this device (last 4 characters of physical MAC, e.g. "ABCD")
    String getDeviceMac4();

private:
    CryptoHelper() = default;
    ~CryptoHelper() = default;
    CryptoHelper(const CryptoHelper&) = delete;
    CryptoHelper& operator=(const CryptoHelper&) = delete;
};

#endif // CRYPTO_HELPER_H

]]>
</file>
<file name="src\Storage\StorageManager.cpp">
<![CDATA[
#include "StorageManager.h"

StorageManager::StorageManager() 
    : _systemDirty(false), _loadsDirty(false), _statesDirty(false), _lastChangeTime(0) {
}

StorageManager& StorageManager::getInstance() {
    static StorageManager instance;
    return instance;
}

bool StorageManager::begin() {
    Serial.println(F("[STORAGE] Mounting LittleFS..."));
    if (!LittleFS.begin(true)) {
        Serial.println(F("[STORAGE] Error: LittleFS mount failed!"));
        return false;
    }
    Serial.println(F("[STORAGE] LittleFS mounted successfully."));
    initDefaultFiles();

    // Cache private key and MQTT CA cert
    _cachedPrivateKey = getPrivateKey();
    _cachedMqttCA = getMqttCA();

    return true;
}

bool StorageManager::fileExists(const char* path) {
    return LittleFS.exists(path);
}

String StorageManager::readFile(const char* path) {
    if (!fileExists(path)) {
        Serial.printf("[STORAGE] Warning: File %s does not exist!\n", path);
        return String();
    }

    File file = LittleFS.open(path, "r");
    if (!file) {
        Serial.printf("[STORAGE] Error: Failed to open %s for reading!\n", path);
        return String();
    }

    String content;
    content.reserve(file.size());
    while (file.available()) {
        content += (char)file.read();
    }
    file.close();
    return content;
}

bool StorageManager::writeFile(const char* path, const String& content) {
    File file = LittleFS.open(path, "w");
    if (!file) {
        Serial.printf("[STORAGE] Error: Failed to open %s for writing!\n", path);
        return false;
    }

    size_t written = file.print(content);
    file.close();

    if (written != content.length()) {
        Serial.printf("[STORAGE] Error: Write mismatch for %s. Written %d of %d bytes.\n", path, written, content.length());
        return false;
    }

    if (strcmp(path, "/system.json") == 0) {
        _cachedPrivateKey = "";
        _cachedMqttCA = "";
    }

    return true;
}

bool StorageManager::writeStaticFile(const char* path, const char* content) {
    File file = LittleFS.open(path, "w");
    if (!file) {
        Serial.printf("[STORAGE] Error: Failed to open %s for writing (static)!\n", path);
        return false;
    }

    size_t length = strlen(content);
    size_t written = file.print(content);
    file.close();

    if (written != length) {
        Serial.printf("[STORAGE] Error: Static write mismatch for %s. Written %d of %d bytes.\n", path, written, length);
        return false;
    }
    return true;
}

bool StorageManager::deleteFile(const char* path) {
    if (!fileExists(path)) {
        return false;
    }
    return LittleFS.remove(path);
}

void StorageManager::initDefaultFiles() {
    // 1. Initialize system config (system.json) containing private api_key and mqtt_ca
    bool updateSys = false;
    if (!fileExists("/system.json")) {
        updateSys = true;
    } else {
        String content = readFile("/system.json");
        if (content.indexOf("\"mqtt_ca\":\"") == -1) {
            updateSys = true;
        }
    }

    if (updateSys) {
        Serial.println(F("[STORAGE] system.json needs initialization/update. Writing default system keys & root CA."));
        // Root CA is stored directly inside system.json
        const char* defaultSys = "{\"api_key\":\"AdaCodecSecretKey\",\"mqtt_ca\":\"-----BEGIN CERTIFICATE-----\\nMIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\\nTzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\\ncmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\\nWhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\\nZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY\\nMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc\\nh77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+\\n0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U\\nA5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW\\nT8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH\\nB5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC\\nB5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv\\nKBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn\\nOlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn\\njh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw\\nqHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI\\nrU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV\nHRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq\nhkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL\nubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ\\n3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK\\nNFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5\nORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur\nTkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC\njNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc\noyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq\n4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA\nmRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d\nemyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=\\n-----END CERTIFICATE-----\\n\"}";
        if (writeStaticFile("/system.json", defaultSys)) {
            Serial.println(F("[STORAGE] system.json initialized successfully."));
        }
    } else {
        Serial.printf("[STORAGE] Existing system.json size: %d bytes\n", LittleFS.open("/system.json", "r").size());
    }

    // 2. Initialize loads config (loads.json)
    if (!fileExists("/loads.json")) {
        Serial.println(F("[STORAGE] loads.json not found. Initializing with default 'null' value."));
        if (writeStaticFile("/loads.json", "null")) {
            Serial.println(F("[STORAGE] loads.json initialized successfully."));
        }
    } else {
        Serial.printf("[STORAGE] Existing loads.json size: %d bytes\n", LittleFS.open("/loads.json", "r").size());
    }

    // 3. Initialize active states config (states.json)
    if (!fileExists("/states.json")) {
        Serial.println(F("[STORAGE] states.json not found. Initializing with default 'null' value."));
        if (writeStaticFile("/states.json", "null")) {
            Serial.println(F("[STORAGE] states.json initialized successfully."));
        }
    } else {
        Serial.printf("[STORAGE] Existing states.json size: %d bytes\n", LittleFS.open("/states.json", "r").size());
    }
}

String StorageManager::getPrivateKey() {
    if (_cachedPrivateKey.length() > 0) {
        return _cachedPrivateKey;
    }
    String content = readFile("/system.json");
    int keyPos = content.indexOf("\"api_key\":\"");
    if (keyPos == -1) {
        return String("AdaCodecSecretKey"); // Fallback private key
    }
    int start = keyPos + 11;
    int end = content.indexOf("\"", start);
    if (end == -1) {
        return String("AdaCodecSecretKey"); // Fallback
    }
    _cachedPrivateKey = content.substring(start, end);
    return _cachedPrivateKey;
}

String StorageManager::getMqttCA() {
    if (_cachedMqttCA.length() > 0) {
        return _cachedMqttCA;
    }
    String content = readFile("/system.json");
    int keyPos = content.indexOf("\"mqtt_ca\":\"");
    if (keyPos == -1) {
        return String();
    }
    int start = keyPos + 11;
    int end = content.indexOf("\"", start);
    if (end == -1) {
        return String();
    }
    String cert = content.substring(start, end);
    // Unescape newlines
    cert.replace("\\n", "\n");
    _cachedMqttCA = cert;
    return _cachedMqttCA;
}

void StorageManager::scheduleDelayedWrite(bool isSystem, bool isLoads, bool isStates) {
    if (isSystem) {
        _systemDirty = true;
    }
    if (isLoads) {
        _loadsDirty = true;
    }
    if (isStates) {
        _statesDirty = true;
    }
    _lastChangeTime = millis();
    Serial.printf("[STORAGE] Coalesced write scheduled (System: %s, Loads: %s, States: %s)\n", 
                  isSystem ? "YES" : "NO", isLoads ? "YES" : "NO", isStates ? "YES" : "NO");
}

void StorageManager::processDelayedSave() {
    if (!_systemDirty && !_loadsDirty && !_statesDirty) {
        return;
    }

    if (millis() - _lastChangeTime >= 3000) {
        if (_systemDirty) {
            Serial.println(F("[STORAGE] Delayed Flash Save: Writing system.json to LittleFS (coalesced, zero-heap)..."));
            // Maintain API key structure inside system.json
            String privateKey = getPrivateKey();
            String ca = getMqttCA();
            ca.replace("\n", "\\n"); // Escape newlines
            String payload = "{\"api_key\":\"" + privateKey + "\",\"mqtt_ca\":\"" + ca + "\"}";
            if (writeFile("/system.json", payload)) {
                _systemDirty = false;
            }
        }
        if (_loadsDirty) {
            Serial.println(F("[STORAGE] Delayed Flash Save: Writing loads.json to LittleFS (coalesced, zero-heap)..."));
            if (writeStaticFile("/loads.json", "null")) {
                _loadsDirty = false;
            }
        }
        if (_statesDirty) {
            Serial.println(F("[STORAGE] Delayed Flash Save: Writing states.json to LittleFS (coalesced, zero-heap)..."));
            if (writeStaticFile("/states.json", "null")) {
                _statesDirty = false;
            }
        }
        Serial.println(F("[STORAGE] Delayed Flash Save sequence completed successfully."));
    }
}

]]>
</file>
<file name="src\Storage\StorageManager.h">
<![CDATA[
#ifndef STORAGE_MANAGER_H
#define STORAGE_MANAGER_H

#include <Arduino.h>
#include <FS.h>
#include <LittleFS.h>

class StorageManager {
public:
    static StorageManager& getInstance();

    bool begin();
    bool fileExists(const char* path);
    String readFile(const char* path);
    
    // Dynamic string write
    bool writeFile(const char* path, const String& content);
    
    // Zero-heap static write to avoid heap fragmentation
    bool writeStaticFile(const char* path, const char* content);
    
    bool deleteFile(const char* path);

    // Delayed Flash Save interfaces
    void scheduleDelayedWrite(bool isSystem, bool isLoads, bool isStates);
    void processDelayedSave();
    bool hasPendingWrites() const { return _systemDirty || _loadsDirty || _statesDirty; }

    // Secure internal API key retriever
    String getPrivateKey();
    String getMqttCA();

private:
    StorageManager();
    ~StorageManager() = default;
    StorageManager(const StorageManager&) = delete;
    StorageManager& operator=(const StorageManager&) = delete;

    void initDefaultFiles();

    volatile bool _systemDirty;
    volatile bool _loadsDirty;
    volatile bool _statesDirty;
    volatile unsigned long _lastChangeTime;

    String _cachedPrivateKey;
    String _cachedMqttCA;
};

#endif // STORAGE_MANAGER_H

]]>
</file>
</files>