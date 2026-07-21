#ifndef CRYPTO_HELPER_H
#define CRYPTO_HELPER_H

#include <Arduino.h>

class CryptoHelper {
public:
    static CryptoHelper& getInstance();

    // Derives 16-byte K1 = HMAC-SHA256(api_key, timestamp_str)[:16]
    bool deriveSessionKey(const String& timestamp, uint8_t* outKey);

    // Encrypts plainText using session key K1 derived from timestamp.
    // Generates a random 16-byte IV.
    // Returns: Base64( IV[16] || Ciphertext[N] )
    String encrypt(const String& plainText, const String& timestamp);

    // Decrypts base64Payload using session key K1 derived from timestamp and extracted IV.
    // Returns decrypted plaintext, or empty String on failure.
    String decrypt(const String& base64Payload, const String& timestamp);

    // Validates time window (±30 seconds) and decrypts the payload.
    // Checks if the decrypted payload contains valid mac4 of the current device.
    // Returns true on success.
    bool verifyAndDecrypt(const String& base64Payload, const String& timestamp, String& outPlainText);

    // Helpers to get MAC identifications of this device
    const char* getDeviceMac();
    const char* getDeviceMac4();

private:
    CryptoHelper() = default;
    ~CryptoHelper() = default;
    CryptoHelper(const CryptoHelper&) = delete;
    CryptoHelper& operator=(const CryptoHelper&) = delete;
};

#endif // CRYPTO_HELPER_H
