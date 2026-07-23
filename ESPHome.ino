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

// Stress test control flag (0 = disabled on boot, 1 = enabled)
bool g_enableStressTest = false;

void runCryptoParityTest() {
    Serial.println(F("\n--- [CRYPTO_TEST] Starting Crypto Parity Validation ---"));
    
    String timestamp = "1716900000";
    String plainText = String("{\"data\":\"HelloWorld\",\"mac4\":\"") + CryptoHelper::getInstance().getDeviceMac4() + "\"}";
    
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
    else if (command.startsWith("RUN_STRESS_TEST") || command.startsWith("STRESS_TEST") || command.startsWith("run_stress_test")) {
        int flagVal = -1;
        int spaceIdx = command.indexOf(' ');
        if (spaceIdx != -1) {
            flagVal = command.substring(spaceIdx + 1).toInt();
        }
        if (flagVal == 1) {
            g_enableStressTest = true;
            Serial.println(F("[STRESS_TEST] Flag set to 1. Executing Event Bus Stress Test..."));
            runEventBusStressTest();
        } else if (flagVal == 0) {
            g_enableStressTest = false;
            Serial.println(F("[STRESS_TEST] Flag set to 0. Stress test disabled on boot."));
        } else {
            g_enableStressTest = !g_enableStressTest;
            Serial.printf("[STRESS_TEST] Toggled stress test flag to %d.\n", g_enableStressTest ? 1 : 0);
            if (g_enableStressTest) {
                runEventBusStressTest();
            }
        }
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

    // 6. Run Event Bus Stress Test (overflow check if flag enabled)
    if (g_enableStressTest) {
        runEventBusStressTest();
    } else {
        Serial.println(F("[MAIN] Event bus stress test skipped on boot (Flag g_enableStressTest = 0). Use command 'SYS: run_stress_test 1' or 'SYS: STRESS_TEST 1' to enable/run."));
    }

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
