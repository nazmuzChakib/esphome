#include "CryptoHelper.h"
#include "../Storage/StorageManager.h"
#include "mbedtls/md.h"
#include "mbedtls/aes.h"
#include "mbedtls/base64.h"
#include <WiFi.h>
#include <esp_mac.h>

CryptoHelper& CryptoHelper::getInstance() {
    static CryptoHelper instance;
    return instance;
}

bool CryptoHelper::deriveSessionKey(const String& timestamp, uint8_t* outKey) {
    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);
    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    
    if (info == NULL) {
        mbedtls_md_free(&ctx);
        return false;
    }

    if (mbedtls_md_setup(&ctx, info, 1) != 0) { // 1 enables HMAC
        mbedtls_md_free(&ctx);
        return false;
    }

    // Retrieve private api_key from StorageManager (system.json)
    String apiKey = StorageManager::getInstance().getPrivateKey();

    mbedtls_md_hmac_starts(&ctx, (const unsigned char*)apiKey.c_str(), apiKey.length());
    mbedtls_md_hmac_update(&ctx, (const unsigned char*)timestamp.c_str(), timestamp.length());
    
    uint8_t hmacResult[32];
    mbedtls_md_hmac_finish(&ctx, hmacResult);
    mbedtls_md_free(&ctx);

    // Truncate SHA256 digest to 128-bits (first 16 bytes) for K1 key
    memcpy(outKey, hmacResult, 16);
    return true;
}

String CryptoHelper::encrypt(const String& plainText, const String& timestamp) {
    uint8_t sessionKey[16];
    if (!deriveSessionKey(timestamp, sessionKey)) {
        return String();
    }

    int plainLen = plainText.length();
    
    // PKCS7 Padding calculation
    int paddingLen = 16 - (plainLen % 16);
    int encryptedLen = plainLen + paddingLen;

    uint8_t* inputBuffer = (uint8_t*)malloc(encryptedLen);
    uint8_t* outputBuffer = (uint8_t*)malloc(encryptedLen);
    
    if (inputBuffer == nullptr || outputBuffer == nullptr) {
        if (inputBuffer) free(inputBuffer);
        if (outputBuffer) free(outputBuffer);
        return String();
    }

    // Fill padding
    memcpy(inputBuffer, plainText.c_str(), plainLen);
    for (int i = plainLen; i < encryptedLen; i++) {
        inputBuffer[i] = paddingLen;
    }

    // Generate random 16-byte IV via ESP32 Hardware TRNG
    uint8_t iv[16];
    for (int i = 0; i < 16; i++) {
        iv[i] = esp_random() % 256;
    }

    // Copy IV as mbedtls mutates the IV buffer during encryption
    uint8_t iv_copy[16];
    memcpy(iv_copy, iv, 16);

    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    // Set 128-bit key for encryption
    mbedtls_aes_setkey_enc(&aes, sessionKey, 128);
    
    // CBC hardware-accelerated encryption
    mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_ENCRYPT, encryptedLen, iv, inputBuffer, outputBuffer);
    mbedtls_aes_free(&aes);

    // Combine: IV[16] + Ciphertext[N]
    int combinedLen = 16 + encryptedLen;
    uint8_t* combinedBuffer = (uint8_t*)malloc(combinedLen);
    if (combinedBuffer == nullptr) {
        free(inputBuffer);
        free(outputBuffer);
        return String();
    }

    memcpy(combinedBuffer, iv_copy, 16);
    memcpy(combinedBuffer + 16, outputBuffer, encryptedLen);

    // Base64 Encode
    size_t base64Len = 0;
    mbedtls_base64_encode(nullptr, 0, &base64Len, combinedBuffer, combinedLen);
    
    char* base64Output = (char*)malloc(base64Len + 1);
    if (base64Output == nullptr) {
        free(inputBuffer);
        free(outputBuffer);
        free(combinedBuffer);
        return String();
    }

    size_t written = 0;
    mbedtls_base64_encode((unsigned char*)base64Output, base64Len, &written, combinedBuffer, combinedLen);
    base64Output[written] = '\0';

    String result(base64Output);

    // Free all allocated heaps
    free(inputBuffer);
    free(outputBuffer);
    free(combinedBuffer);
    free(base64Output);

    return result;
}

String CryptoHelper::decrypt(const String& base64Payload, const String& timestamp) {
    uint8_t sessionKey[16];
    if (!deriveSessionKey(timestamp, sessionKey)) {
        return String();
    }

    // Decode Base64 payload
    size_t maxDecryptedSize = (base64Payload.length() * 3) / 4 + 2;
    uint8_t* combinedBuffer = (uint8_t*)malloc(maxDecryptedSize);
    if (combinedBuffer == nullptr) {
        return String();
    }

    size_t combinedLen = 0;
    int ret = mbedtls_base64_decode(combinedBuffer, maxDecryptedSize, &combinedLen, 
                                    (const unsigned char*)base64Payload.c_str(), base64Payload.length());
    
    if (ret != 0 || combinedLen < 32) { // Minimally 16-byte IV + 16-byte block
        free(combinedBuffer);
        return String();
    }

    // Split IV and Ciphertext
    uint8_t iv[16];
    memcpy(iv, combinedBuffer, 16);

    int cipherLen = combinedLen - 16;
    uint8_t* ciphertext = combinedBuffer + 16;

    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    mbedtls_aes_setkey_dec(&aes, sessionKey, 128);

    uint8_t* decryptedBuffer = (uint8_t*)malloc(cipherLen);
    if (decryptedBuffer == nullptr) {
        mbedtls_aes_free(&aes);
        free(combinedBuffer);
        return String();
    }

    // Decrypt CBC
    mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_DECRYPT, cipherLen, iv, ciphertext, decryptedBuffer);
    mbedtls_aes_free(&aes);

    // Strip PKCS7 padding
    uint8_t paddingVal = decryptedBuffer[cipherLen - 1];
    if (paddingVal < 1 || paddingVal > 16 || paddingVal > cipherLen) {
        free(combinedBuffer);
        free(decryptedBuffer);
        return String(); // Invalid padding
    }

    int plainLen = cipherLen - paddingVal;
    char* plainText = (char*)malloc(plainLen + 1);
    if (plainText == nullptr) {
        free(combinedBuffer);
        free(decryptedBuffer);
        return String();
    }

    memcpy(plainText, decryptedBuffer, plainLen);
    plainText[plainLen] = '\0';

    String result(plainText);

    // Free buffers
    free(combinedBuffer);
    free(decryptedBuffer);
    free(plainText);

    return result;
}

bool CryptoHelper::verifyAndDecrypt(const String& base64Payload, const String& timestamp, String& outPlainText) {
    // 1. Replay Protection (time-window verification)
    unsigned long reqTime = strtoul(timestamp.c_str(), nullptr, 10);
    if (reqTime == 0) {
        return false;
    }

    time_t now = time(nullptr);
    // Year 1970 represents unsynced clock
    if (now > 1000000) { 
        long diff = (long)now - (long)reqTime;
        if (abs(diff) > 30) {
            Serial.printf("[CRYPTO] Replay Protection: Request is out of ±30s window (Diff: %ld seconds)!\n", diff);
            return false;
        }
    } else {
        // Fallback for tests/setup when time is not synced yet
        if (reqTime == 1716900000) {
            Serial.println(F("[CRYPTO] Clock not synced. Using test timestamp fallback."));
        } else {
            Serial.println(F("[CRYPTO] Warning: Clock not synced. Bypassing time-window check."));
        }
    }

    // 2. Decrypt Payload
    String plainText = decrypt(base64Payload, timestamp);
    if (plainText.length() == 0) {
        Serial.println(F("[CRYPTO] Error: Payload decryption failed!"));
        return false;
    }

    // 3. Identity Verification (mac4 check - enforced only when mac4 is present in payload)
    if (plainText.indexOf("\"mac4\"") != -1) {
        String expectedMac4 = getDeviceMac4();
        String expectedMac4Upper = expectedMac4;
        expectedMac4Upper.toUpperCase();
        String expectedMac4Lower = expectedMac4;
        expectedMac4Lower.toLowerCase();

        String matchStrUpper = "\"mac4\":\"" + expectedMac4Upper + "\"";
        String matchStrLower = "\"mac4\":\"" + expectedMac4Lower + "\"";

        if (plainText.indexOf(matchStrUpper) == -1 && plainText.indexOf(matchStrLower) == -1) {
            Serial.printf("[CRYPTO] Identity Rejected: Payload mac4 does not target this node (%s)!\n", expectedMac4Upper.c_str());
            return false;
        }
    }

    outPlainText = plainText;
    return true;
}

const char* CryptoHelper::getDeviceMac() {
    static char macStr[13] = {0};
    if (macStr[0] == '\0') {
        uint8_t mac[6];
        if (esp_read_mac(mac, ESP_MAC_WIFI_STA) == ESP_OK) {
            snprintf(macStr, sizeof(macStr), "%02X%02X%02X%02X%02X%02X",
                     mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        } else {
            // Fallback if SDK call fails
            String fallback = WiFi.macAddress();
            fallback.replace(":", "");
            fallback.toUpperCase();
            strncpy(macStr, fallback.c_str(), sizeof(macStr) - 1);
            macStr[sizeof(macStr) - 1] = '\0';
        }
    }
    return macStr;
}

const char* CryptoHelper::getDeviceMac4() {
    static char mac4Str[5] = {0};
    if (mac4Str[0] == '\0') {
        const char* mac = getDeviceMac();
        size_t len = strlen(mac);
        if (len >= 4) {
            strncpy(mac4Str, mac + len - 4, 4);
            mac4Str[4] = '\0';
        } else {
            strcpy(mac4Str, "0000");
        }
    }
    return mac4Str;
}
