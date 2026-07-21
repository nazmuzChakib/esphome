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
