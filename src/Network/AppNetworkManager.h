#ifndef APP_NETWORK_MANAGER_H
#define APP_NETWORK_MANAGER_H

#include <Arduino.h>
#include <ESPWiFiManager.h>
#include <ESPAsyncWebServer.h>
#include <WiFiUdp.h>

class AppNetworkManager {
public:
    static AppNetworkManager& getInstance();

    // Initializes WiFi manager, AsyncWebServer, NTP, and UDP listeners
    bool begin();
    
    // Pump state machines (MUST be called inside TaskCore0 loop)
    void process();

    // Checked if STA is connected to an Access Point
    bool isConnected() const;

    // Thread-safe Unix timestamp getter
    unsigned long getUnixTimestamp();
    
    // Wraps WiFi credentials management over serial commands
    void executeWifiCommand(const String& cmd, Stream& io = Serial);

private:
    AppNetworkManager();
    ~AppNetworkManager() = default;
    AppNetworkManager(const AppNetworkManager&) = delete;
    AppNetworkManager& operator=(const AppNetworkManager&) = delete;

    // Callbacks for ESPWiFiManager
    void onWiFiConnected(const String& ssid, IPAddress ip);
    void onWiFiDisconnected(int reason);
    void onAPStarted(const String& ssid, IPAddress ip);
    void onAPStopped();

    // UDP discovery managers
    void checkUDPDiscovery();
    void sendDiscoveryBeacon();

    AsyncWebServer _server;
    AsyncWebSocket _ws;
    WiFiManager _wm;
    WiFiUDP _udp;

    unsigned long _lastUDPBroadcastTime;
    bool _timeSynced;
    unsigned long _lastNTPCheckTime;
};

#endif // APP_NETWORK_MANAGER_H
