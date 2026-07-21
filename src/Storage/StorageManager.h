#ifndef STORAGE_MANAGER_H
#define STORAGE_MANAGER_H

#include <Arduino.h>
#include <FS.h>
#include <LittleFS.h>

class StorageManager {
public:
    static StorageManager& getInstance();

    bool begin();
    bool fileExists(const char* path);
    String readFile(const char* path);
    
    // Dynamic string write
    bool writeFile(const char* path, const String& content);
    
    // Zero-heap static write to avoid heap fragmentation
    bool writeStaticFile(const char* path, const char* content);
    
    bool deleteFile(const char* path);

    // Delayed Flash Save interfaces
    void scheduleDelayedWrite(bool isSystem, bool isLoads, bool isStates);
    void processDelayedSave();
    bool hasPendingWrites() const { return _systemDirty || _loadsDirty || _statesDirty; }

    // Secure internal API key retriever
    String getPrivateKey();
    String getMqttCA();
    String getMqttUser();
    String getMqttPass();

private:
    StorageManager();
    ~StorageManager() = default;
    StorageManager(const StorageManager&) = delete;
    StorageManager& operator=(const StorageManager&) = delete;

    void initDefaultFiles();

    volatile bool _systemDirty;
    volatile bool _loadsDirty;
    volatile bool _statesDirty;
    volatile unsigned long _lastChangeTime;

    String _cachedPrivateKey;
    String _cachedMqttCA;
    
    class SystemMutex* _mutex = nullptr; // forward declaration or pointer to avoid inclusion loop if any, or include SystemMutex.h
};

#endif // STORAGE_MANAGER_H
