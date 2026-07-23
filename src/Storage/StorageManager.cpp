#include "StorageManager.h"
#include "../Core/SystemMutex.h"
#include "../Security/CryptoHelper.h"

StorageManager::StorageManager() 
    : _systemDirty(false), _loadsDirty(false), _statesDirty(false), _lastChangeTime(0) {
    _mutex = new SystemMutex();
}

StorageManager& StorageManager::getInstance() {
    static StorageManager instance;
    return instance;
}

bool StorageManager::begin() {
    Serial.println(F("[STORAGE] Mounting LittleFS..."));
    if (!LittleFS.begin(true)) {
        Serial.println(F("[STORAGE] Error: LittleFS mount failed!"));
        return false;
    }
    Serial.println(F("[STORAGE] LittleFS mounted successfully."));
    initDefaultFiles();

    // Cache private key and MQTT CA cert
    _cachedPrivateKey = getPrivateKey();
    _cachedMqttCA = getMqttCA();

    return true;
}

#include <memory>

bool StorageManager::fileExists(const char* path) {
    LockGuard lock(*_mutex);
    return LittleFS.exists(path);
}

String StorageManager::readFile(const char* path) {
    LockGuard lock(*_mutex);
    if (!LittleFS.exists(path)) {
        Serial.printf("[STORAGE] Warning: File %s does not exist!\n", path);
        return String();
    }

    File file = LittleFS.open(path, "r");
    if (!file) {
        Serial.printf("[STORAGE] Error: Failed to open %s for reading!\n", path);
        return String();
    }

    size_t size = file.size();
    if (size == 0) {
        file.close();
        return String();
    }

    std::unique_ptr<char[]> buf(new (std::nothrow) char[size + 1]);
    if (!buf) {
        Serial.println(F("[STORAGE] Error: Failed to allocate buffer for file read!"));
        file.close();
        return String();
    }

    file.readBytes(buf.get(), size);
    buf[size] = '\0';
    String content(buf.get());
    file.close();
    return content;
}

bool StorageManager::writeFile(const char* path, const String& content) {
    LockGuard lock(*_mutex);
    File file = LittleFS.open(path, "w");
    if (!file) {
        Serial.printf("[STORAGE] Error: Failed to open %s for writing!\n", path);
        return false;
    }

    size_t written = file.print(content);
    file.close();

    if (written != content.length()) {
        Serial.printf("[STORAGE] Error: Write mismatch for %s. Written %d of %d bytes.\n", path, written, content.length());
        return false;
    }

    if (strcmp(path, "/system.json") == 0) {
        _cachedPrivateKey = "";
        _cachedMqttCA = "";
    }

    return true;
}

bool StorageManager::writeStaticFile(const char* path, const char* content) {
    LockGuard lock(*_mutex);
    File file = LittleFS.open(path, "w");
    if (!file) {
        Serial.printf("[STORAGE] Error: Failed to open %s for writing (static)!\n", path);
        return false;
    }

    size_t length = strlen(content);
    size_t written = file.print(content);
    file.close();

    if (written != length) {
        Serial.printf("[STORAGE] Error: Static write mismatch for %s. Written %d of %d bytes.\n", path, written, length);
        return false;
    }
    return true;
}

bool StorageManager::deleteFile(const char* path) {
    LockGuard lock(*_mutex);
    if (!LittleFS.exists(path)) {
        return false;
    }
    return LittleFS.remove(path);
}

void StorageManager::initDefaultFiles() {
    // 1. Initialize system config (system.json) containing private api_key, credentials, and mqtt_ca
    bool updateSys = false;
    if (!LittleFS.exists("/system.json")) {
        updateSys = true;
    } else {
        String content = readFile("/system.json");
        if (content.indexOf("\"mqtt_ca\":\"") == -1 || content.indexOf("\"mqtt_user\":\"") == -1) {
            updateSys = true;
        }
    }

    if (updateSys) {
        Serial.println(F("[STORAGE] system.json needs initialization/update. Writing default system keys & root CA."));
        
        String apiKey = "ESPHome_sec_node";
        String plainUser = "@esp_home";
        String plainPass = "password@esp_Home";
        
        // Dynamically encrypt default credentials using apiKey as salt
        String encUser = CryptoHelper::getInstance().encrypt(plainUser, apiKey);
        String encPass = CryptoHelper::getInstance().encrypt(plainPass, apiKey);
        
        String caCert = "-----BEGIN CERTIFICATE-----\\nMIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\\nTzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\\ncmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\\nWhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\\nZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY\\nMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc\\nh77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+\\n0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U\\nA5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW\\nT8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH\\nB5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC\\nB5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv\\nKBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn\\nOlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn\\njh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw\\nqHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI\\nrU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV\\nHRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq\\nhkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL\\nubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ\\n3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK\\nNFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5\\nORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur\\nTkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC\\njNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc\\noyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq\\n4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA\\nmRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d\\nemyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=\\n-----END CERTIFICATE-----\\n\"";
        
        String defaultSys = "{\"api_key\":\"" + apiKey + "\",\"mqtt_user\":\"" + encUser + "\",\"mqtt_pass\":\"" + encPass + "\",\"mqtt_ca\":\"" + caCert + "\"}";
        
        if (writeFile("/system.json", defaultSys)) {
            Serial.println(F("[STORAGE] system.json initialized successfully."));
        }
    } else {
        Serial.printf("[STORAGE] Existing system.json size: %d bytes\n", LittleFS.open("/system.json", "r").size());
    }

    // 2. Initialize loads config (loads.json)
    if (!LittleFS.exists("/loads.json")) {
        Serial.println(F("[STORAGE] loads.json not found. Initializing with default 'null' value."));
        if (writeStaticFile("/loads.json", "null")) {
            Serial.println(F("[STORAGE] loads.json initialized successfully."));
        }
    } else {
        Serial.printf("[STORAGE] Existing loads.json size: %d bytes\n", LittleFS.open("/loads.json", "r").size());
    }

    // 3. Initialize active states config (states.json)
    if (!LittleFS.exists("/states.json")) {
        Serial.println(F("[STORAGE] states.json not found. Initializing with default 'null' value."));
        if (writeStaticFile("/states.json", "null")) {
            Serial.println(F("[STORAGE] states.json initialized successfully."));
        }
    } else {
        Serial.printf("[STORAGE] Existing states.json size: %d bytes\n", LittleFS.open("/states.json", "r").size());
    }
}

String StorageManager::getPrivateKey() {
    LockGuard lock(*_mutex);
    if (_cachedPrivateKey.length() > 0) {
        return _cachedPrivateKey;
    }
    String content = readFile("/system.json");
    int keyPos = content.indexOf("\"api_key\":\"");
    if (keyPos == -1) {
        return String("ESPHome_sec_node"); // Fallback private key
    }
    int start = keyPos + 11;
    int end = content.indexOf("\"", start);
    if (end == -1) {
        return String("ESPHome_sec_node"); // Fallback
    }
    _cachedPrivateKey = content.substring(start, end);
    return _cachedPrivateKey;
}

String StorageManager::getMqttCA() {
    LockGuard lock(*_mutex);
    if (_cachedMqttCA.length() > 0) {
        return _cachedMqttCA;
    }
    String content = readFile("/system.json");
    int keyPos = content.indexOf("\"mqtt_ca\":\"");
    if (keyPos == -1) {
        return String();
    }
    int start = keyPos + 11;
    int end = content.indexOf("\"", start);
    if (end == -1) {
        return String();
    }
    String cert = content.substring(start, end);
    // Unescape newlines
    cert.replace("\\n", "\n");
    _cachedMqttCA = cert;
    return _cachedMqttCA;
}

String StorageManager::getMqttUser() {
    LockGuard lock(*_mutex);
    String content = readFile("/system.json");
    int saltPos = content.indexOf("\"api_key\":\"");
    int userPos = content.indexOf("\"mqtt_user\":\"");
    if (saltPos == -1 || userPos == -1) return "";
    
    // Extract salt (api_key)
    int saltStart = saltPos + 11;
    int saltEnd = content.indexOf("\"", saltStart);
    if (saltEnd == -1) return "";
    String salt = content.substring(saltStart, saltEnd);
    
    // Extract user
    int userStart = userPos + 13;
    int userEnd = content.indexOf("\"", userStart);
    if (userEnd == -1) return "";
    String encUser = content.substring(userStart, userEnd);
    
    // Decrypt
    return CryptoHelper::getInstance().decrypt(encUser, salt);
}

String StorageManager::getMqttPass() {
    LockGuard lock(*_mutex);
    String content = readFile("/system.json");
    int saltPos = content.indexOf("\"api_key\":\"");
    int passPos = content.indexOf("\"mqtt_pass\":\"");
    if (saltPos == -1 || passPos == -1) return "";
    
    // Extract salt (api_key)
    int saltStart = saltPos + 11;
    int saltEnd = content.indexOf("\"", saltStart);
    if (saltEnd == -1) return "";
    String salt = content.substring(saltStart, saltEnd);
    
    // Extract pass
    int passStart = passPos + 13;
    int passEnd = content.indexOf("\"", passStart);
    if (passEnd == -1) return "";
    String encPass = content.substring(passStart, passEnd);
    
    // Decrypt
    return CryptoHelper::getInstance().decrypt(encPass, salt);
}

void StorageManager::scheduleDelayedWrite(bool isSystem, bool isLoads, bool isStates) {
    LockGuard lock(*_mutex);
    if (isSystem) {
        _systemDirty = true;
    }
    if (isLoads) {
        _loadsDirty = true;
    }
    if (isStates) {
        _statesDirty = true;
    }
    _lastChangeTime = millis();
    Serial.printf("[STORAGE] Coalesced write scheduled (System: %s, Loads: %s, States: %s)\n", 
                  isSystem ? "YES" : "NO", isLoads ? "YES" : "NO", isStates ? "YES" : "NO");
}

void StorageManager::processDelayedSave() {
    if (!_systemDirty && !_loadsDirty && !_statesDirty) {
        return;
    }

    LockGuard lock(*_mutex);
    if (millis() - _lastChangeTime >= 3000) {
        if (_systemDirty) {
            Serial.println(F("[STORAGE] Delayed Flash Save: Writing system.json to LittleFS (coalesced, zero-heap)..."));
            // Maintain API key structure inside system.json
            String privateKey = getPrivateKey();
            String ca = getMqttCA();
            ca.replace("\n", "\\n"); // Escape newlines
            
            // Decrypt credentials to encrypt them with the current privateKey
            String rawUser = getMqttUser();
            String rawPass = getMqttPass();
            String encUser = CryptoHelper::getInstance().encrypt(rawUser, privateKey);
            String encPass = CryptoHelper::getInstance().encrypt(rawPass, privateKey);
            
            String payload = "{\"api_key\":\"" + privateKey + "\",\"mqtt_user\":\"" + encUser + "\",\"mqtt_pass\":\"" + encPass + "\",\"mqtt_ca\":\"" + ca + "\"}";
            if (writeFile("/system.json", payload)) {
                _systemDirty = false;
            }
        }
        if (_loadsDirty) {
            Serial.println(F("[STORAGE] Delayed Flash Save: Writing loads.json to LittleFS (coalesced, zero-heap)..."));
            if (writeStaticFile("/loads.json", "null")) {
                _loadsDirty = false;
            }
        }
        if (_statesDirty) {
            Serial.println(F("[STORAGE] Delayed Flash Save: Writing states.json to LittleFS (coalesced, zero-heap)..."));
            if (writeStaticFile("/states.json", "null")) {
                _statesDirty = false;
            }
        }
        Serial.println(F("[STORAGE] Delayed Flash Save sequence completed successfully."));
    }
}
