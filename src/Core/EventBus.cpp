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
                    AppEvent oldestEvent = _eventPool[oldestIdx];
                    if (oldestEvent.type == EVENT_SYSTEM_ALERT || oldestEvent.type == EVENT_NETWORK_COMMAND) {
                        // Put it back to front of eventQueue
                        xQueueSendToFrontFromISR(_eventQueue, &oldestIdx, &pxHigherPriorityTaskWoken);
                        _switchDropCount++;
                        if (pxHigherPriorityTaskWoken == pdTRUE) {
                            portYIELD_FROM_ISR();
                        }
                        return false;
                    }
                    
                    if (oldestEvent.type == EVENT_PHYSICAL_SWITCH_TOGGLED) {
                        _switchDropCount++;
                    } else if (oldestEvent.type == EVENT_SENSOR_TELEMETRY) {
                        _sensorDropCount++;
                    }
                    _eventPool[oldestIdx] = event; // Overwrite data
                    xQueueSendToBackFromISR(_eventQueue, &oldestIdx, &pxHigherPriorityTaskWoken);
                    if (pxHigherPriorityTaskWoken == pdTRUE) {
                        portYIELD_FROM_ISR();
                    }
                    return true;
                }
            } else if (event.type == EVENT_SYSTEM_ALERT || event.type == EVENT_NETWORK_COMMAND) {
                int oldestIdx = -1;
                if (xQueueReceiveFromISR(_eventQueue, &oldestIdx, &pxHigherPriorityTaskWoken) == pdTRUE) {
                    AppEvent oldestEvent = _eventPool[oldestIdx];
                    if (oldestEvent.type == EVENT_SYSTEM_ALERT || oldestEvent.type == EVENT_NETWORK_COMMAND) {
                        // Put it back to front of eventQueue, drop incoming critical event
                        xQueueSendToFrontFromISR(_eventQueue, &oldestIdx, &pxHigherPriorityTaskWoken);
                        if (pxHigherPriorityTaskWoken == pdTRUE) {
                            portYIELD_FROM_ISR();
                        }
                        return false;
                    }
                    
                    if (oldestEvent.type == EVENT_PHYSICAL_SWITCH_TOGGLED) {
                        _switchDropCount++;
                    } else if (oldestEvent.type == EVENT_SENSOR_TELEMETRY) {
                        _sensorDropCount++;
                    }
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
                    AppEvent oldestEvent = _eventPool[oldestIdx];
                    if (oldestEvent.type == EVENT_SYSTEM_ALERT || oldestEvent.type == EVENT_NETWORK_COMMAND) {
                        xQueueSendToFront(_eventQueue, &oldestIdx, portMAX_DELAY);
                        _switchDropCount++; // Drop incoming switch event
                        Serial.println(F("[EVENT_BUS] Pool exhausted! Dropped incoming switch event to protect critical event."));
                        return false;
                    }
                    
                    if (oldestEvent.type == EVENT_PHYSICAL_SWITCH_TOGGLED) {
                        _switchDropCount++;
                    } else if (oldestEvent.type == EVENT_SENSOR_TELEMETRY) {
                        _sensorDropCount++;
                    }
                    Serial.printf("[EVENT_BUS] Pool exhausted! Evicted non-critical event at slot %d.\n", oldestIdx);
                    _eventPool[oldestIdx] = event; // Overwrite data
                    xQueueSendToBack(_eventQueue, &oldestIdx, portMAX_DELAY);
                    return true;
                }
            } else if (event.type == EVENT_SYSTEM_ALERT || event.type == EVENT_NETWORK_COMMAND) {
                int oldestIdx = -1;
                if (xQueueReceive(_eventQueue, &oldestIdx, 0) == pdTRUE) {
                    AppEvent oldestEvent = _eventPool[oldestIdx];
                    if (oldestEvent.type == EVENT_SYSTEM_ALERT || oldestEvent.type == EVENT_NETWORK_COMMAND) {
                        xQueueSendToFront(_eventQueue, &oldestIdx, portMAX_DELAY);
                        Serial.println(F("[EVENT_BUS] Pool exhausted! Dropped incoming critical event because oldest is also critical."));
                        return false;
                    }
                    
                    if (oldestEvent.type == EVENT_PHYSICAL_SWITCH_TOGGLED) {
                        _switchDropCount++;
                    } else if (oldestEvent.type == EVENT_SENSOR_TELEMETRY) {
                        _sensorDropCount++;
                    }
                    Serial.printf("[EVENT_BUS] Pool exhausted! Evicted non-critical slot %d for critical event.\n", oldestIdx);
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
