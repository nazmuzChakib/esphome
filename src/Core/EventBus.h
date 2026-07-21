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
