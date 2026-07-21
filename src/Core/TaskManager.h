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
