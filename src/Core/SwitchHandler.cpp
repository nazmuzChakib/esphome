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
