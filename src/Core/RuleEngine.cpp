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
