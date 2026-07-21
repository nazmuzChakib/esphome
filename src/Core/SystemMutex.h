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
