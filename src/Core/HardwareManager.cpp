#include "HardwareManager.h"
#include "../Network/MqttManager.h"

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

    // 2. Blacklist boot strap strapping pin GPIO 0
    if (pin == 0) {
        Serial.println(F("[HW_MGR] Error: Pin 0 is a boot strapping pin and cannot be registered!"));
        return false;
    }

    // 3. Blacklist flash SPI pins (GPIO 6-11)
    if (pin >= 6 && pin <= 11) {
        Serial.printf("[HW_MGR] Error: Pin %d is used by SPI flash memory and cannot be re-assigned!\n", pin);
        return false;
    }

    // 4. Input-only pins check (GPIO 34-39 are input only and lack pullup/pulldown capability)
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

    // Publish configuration to MQTT topic: ESPHome/nodes/[own_mac]/loads/[owner]
    char loadPayload[64];
    snprintf(loadPayload, sizeof(loadPayload), "{\"pin\":%d,\"mode\":%d}", pin, mode);
    
    char subTopic[64];
    snprintf(subTopic, sizeof(subTopic), "loads/%s", owner);
    MqttManager::getInstance().publish(subTopic, loadPayload, true);

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
        char ownerStr[32];
        strncpy(ownerStr, _registrations[foundIdx].owner, sizeof(ownerStr) - 1);
        ownerStr[sizeof(ownerStr) - 1] = '\0';
        Serial.printf("[HW_MGR] Unregistered Pin %d (formerly owned by '%s').\n", 
                      pin, ownerStr);
        
        // Shift remaining elements left
        for (int i = foundIdx; i < _registrationCount - 1; i++) {
            _registrations[i] = _registrations[i + 1];
        }
        
        _registrationCount--;
        // Clean trailing slot
        _registrations[_registrationCount].pin = 255;
        _registrations[_registrationCount].mode = 0;
        _registrations[_registrationCount].owner[0] = '\0';

        // Clear dynamic retained loads MQTT config
        char subTopic[64];
        snprintf(subTopic, sizeof(subTopic), "loads/%s", ownerStr);
        MqttManager::getInstance().publish(subTopic, "", true);
    }
}

void HardwareManager::syncHardwareState() {
    for (int i = 0; i < _registrationCount; i++) {
        if (_registrations[i].pin != 255) {
            // 1. Re-publish dynamic load configurations
            char loadPayload[64];
            snprintf(loadPayload, sizeof(loadPayload), "{\"pin\":%d,\"mode\":%d}", 
                     _registrations[i].pin, _registrations[i].mode);
            
            char loadTopic[64];
            snprintf(loadTopic, sizeof(loadTopic), "loads/%s", _registrations[i].owner);
            MqttManager::getInstance().publish(loadTopic, loadPayload, true);
            
            // 2. Re-publish active load states
            int pinVal = digitalRead(_registrations[i].pin);
            char statePayload[64];
            snprintf(statePayload, sizeof(statePayload), "{\"relay_state\":\"%s\"}", 
                     (pinVal == HIGH) ? "ON" : "OFF");
            
            char stateTopic[64];
            snprintf(stateTopic, sizeof(stateTopic), "states/%s", _registrations[i].owner);
            MqttManager::getInstance().publish(stateTopic, statePayload, true);
        }
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
