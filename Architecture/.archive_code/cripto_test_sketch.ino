#include <Arduino.h>
#include "mbedtls/aes.h"
#include "libb64/cencode.h"

// গ্লোবাল কনফিগারেশন
const char* SECRET_KEY = "CypherNodeSecretX"; // ১৬ বাইটের ফিক্সড কী
const char* HEADER_EC = "EC:";              // ভ্যালিডেশন হেডার
const int SERIAL_BUFFER_SIZE = 256;          // ফিক্সড-সাইজ সিরিয়াল বাফার

// টাইমিং ভেরিয়েবল (Non-blocking)
unsigned long lastHeapPrintTime = 0;
const unsigned long HEAP_PRINT_INTERVAL = 10000; // ১০ সেকেন্ড

// ফাংশন প্রোটোটাইপ
String encryptPayloadToDynamicIV(String plainText);

void setup() {
    Serial.begin(115200);
    delay(1000);
    Serial.println("\n--- CypherNode Security, JSON & Memory Test Client ---");
    Serial.println("Note: Input data on Serial Monitor followed this format 'EC:YourMessage'");
}

void loop() {
    unsigned long currentMillis = millis();

    // ১. ১০ সেকেন্ড পর পর মেমরি স্ট্যাটাস মনিটরিং
    if (currentMillis - lastHeapPrintTime >= HEAP_PRINT_INTERVAL) {
        lastHeapPrintTime = currentMillis;
        
        size_t freeHeap = ESP.getFreeHeap();
        size_t maxAllocHeap = ESP.getMaxAllocHeap();
        
        Serial.printf("[MEMORY LOG] Free Heap: %d Bytes | Max Alloc Block: %d Bytes\n", freeHeap, maxAllocHeap);
    }

    // ২. সিরিয়াল ডাটা হ্যান্ডলিং (Non-blocking & Fixed Allocation)
    if (Serial.available() > 0) {
        static char serialBuffer[SERIAL_BUFFER_SIZE];
        static int bufferIndex = 0;

        while (Serial.available() > 0) {
            char incomingChar = Serial.read();

            // নিউ-লাইন বা ক্যারিজ রিটার্ন পেলে মেসেজ প্রসেস করা হবে
            if (incomingChar == '\n' || incomingChar == '\r') {
                if (bufferIndex > 0) {
                    serialBuffer[bufferIndex] = '\0'; // স্ট্রিং ইন্ডিং মার্কার
                    
                    String rawInput = String(serialBuffer);
                    
                    // হেডার ভেরিফিকেশন (EC:)
                    if (rawInput.startsWith(HEADER_EC)) {
                        // হেডার বাদে আসল মেসেজটুকু আলাদা করা
                        String cleanMessage = rawInput.substring(3);
                        
                        // মেসেজটিকে কাস্টম JSON-এ রূপান্তর করা
                        // ফরম্যাট: {"data":"YourMessage","mac4":"TEST"}
                        String jsonPayload = "{\"data\":\"" + cleanMessage + "\",\"mac4\":\"TEST\"}";
                        
                        // --- JSON এবং ডেটা প্রিন্ট করার সুব্যবস্থা ---
                        Serial.println("\n==================================================");
                        Serial.println("[RAW INPUT]  : " + cleanMessage);
                        Serial.println("[RAW JSON]   : " + jsonPayload); // এখানে JSON প্রিন্ট হচ্ছে
                        
                        // ডাইনামিক IV সহ হার্ডওয়্যার এনক্রিপশন রান করা
                        String encryptedBase64 = encryptPayloadToDynamicIV(jsonPayload);
                        
                        Serial.println("[ENCRYPTED]  : " + encryptedBase64);
                        Serial.println("==================================================");
                    } else {
                        Serial.println("[REJECTED] Error: Missing 'EC:' Header!");
                    }
                    
                    // বাফার রিসেট
                    bufferIndex = 0;
                }
            } else {
                // বাফার ওভারফ্লো প্রটেকশন
                if (bufferIndex < SERIAL_BUFFER_SIZE - 1) {
                    serialBuffer[bufferIndex++] = incomingChar;
                } else {
                    bufferIndex = 0;
                    Serial.println("[ERROR] Serial Buffer Overflow! Data Dropped.");
                }
            }
        }
    }
}

/**
 * ESP32 হার্ডওয়্যার অ্যাক্সিলারেটেড AES-128-CBC এনক্রিপশন ফাংশন
 * আউটপুট ফরম্যাট: Base64([16-Byte Random IV] + [Encrypted Data])
 */
String encryptPayloadToDynamicIV(String plainText) {
    int plainLen = plainText.length();
    
    // ১. PKCS7 প্যাডিং সাইজ হিসাব করা (১৬-বাইটের ব্লকে এলাইনমেন্ট)
    int paddingLen = 16 - (plainLen % 16);
    int encryptedDataLen = plainLen + paddingLen;
    
    // ২. ফিক্সড-সাইজ লোকাল বাফার তৈরি
    uint8_t inputBuffer[encryptedDataLen];
    uint8_t outputBuffer[encryptedDataLen];
    
    // ইনপুট ডাটা কপি এবং প্যাডিং অ্যাপ্লাই করা
    memcpy(inputBuffer, plainText.c_str(), plainLen);
    for (int i = plainLen; i < encryptedDataLen; i++) {
        inputBuffer[i] = paddingLen;
    }
    
    // ৩. প্রতি মেসেজের জন্য ডাইনামিক র্যান্ডম IV জেনারেট করা (True Random Number Generator)
    uint8_t iv_buffer[16];
    for (int i = 0; i < 16; i++) {
        iv_buffer[i] = esp_random() % 256; 
    }
    
    uint8_t iv_copy[16];
    memcpy(iv_copy, iv_buffer, 16);

    // ৪. mbedTLS AES কন্টেক্সট ইনিশিয়েট ও হার্ডওয়্যার এনক্রিপশন
    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    mbedtls_aes_setkey_enc(&aes, (const unsigned char*)SECRET_KEY, 128);
    
    mbedtls_aes_crypt_cbc(&aes, MBEDTLS_AES_ENCRYPT, encryptedDataLen, iv_buffer, inputBuffer, outputBuffer);
    mbedtls_aes_free(&aes);

    // ৫. [IV (16 bytes)] + [Encrypted Data] একসাথে কম্বাইন করা
    int combinedLen = 16 + encryptedDataLen;
    uint8_t combinedBuffer[combinedLen];
    
    memcpy(combinedBuffer, iv_copy, 16);
    memcpy(combinedBuffer + 16, outputBuffer, encryptedDataLen);
    
    // ৬. ফাইনাল কম্বাইন বাফারকে বেস৬৪-এ কনভার্ট করে পাঠানো
    int base64ExpectedLen = base64_encode_expected_len(combinedLen);
    char base64Output[base64ExpectedLen + 1];
    int encodedLen = base64_encode_chars((const char*)combinedBuffer, combinedLen, base64Output);
    base64Output[encodedLen] = '\0';
    
    return String(base64Output);
}