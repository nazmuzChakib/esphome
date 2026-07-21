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

    // Re-publishes all active load configs and their current states to MQTT
    void syncHardwareState();

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
