# Architecture & Data Flow Documentation: Hybrid IoT System

এটি একটি মাল্টি-নোড, মাল্টি-ক্লায়েন্ট এবং রোল-বেসড (Admin/User) হাইব্রিড আইওটি সিস্টেমের অফিশিয়াল ডকুমেন্টেশন। এই সিস্টেমে লোকাল কানেকশনের জন্য **Websocket (Primary)** এবং দূরবর্তী বা ফাইলব্যাক যোগাযোগের জন্য **MQTT (Secondary)** প্রোটোকল ব্যবহার করা হয়েছে। ইউজার অথেন্টিকেশন এবং পারমিশন ম্যানেজমেন্টের জন্য **Firebase** ব্যবহৃত হয়েছে।

---

## ১. সিস্টেমের মূল উপাদান ও ভূমিকা (System Components)

* **ESP32 (Node):** সম্পূর্ণ *Stateless* ডিভাইস। সে মেমরিতে কোনো ডায়নামিক পাথের ট্র্যাক রাখবে না। কমান্ড রিসিভ করে অ্যাকশন নেবে এবং নতুন স্টেট/সেন্সর ডেটা নির্দিষ্ট টপিকে পাবলিশ করে মেমরি খালি করে দেবে।
* **Flutter App (Client):** সম্পূর্ণ *Stateful* এবং বুদ্ধিমান ক্লায়েন্ট। সে সব নোডের বাল্ক ডেটা রিসিভ করে লোকাল ক্যাশ ডাটাবেসে (Hive/Isar) জমা রাখবে এবং UI রেন্ডার করবে।
* **MQTT Broker (যেমন: Mosquitto/EMQX):** সেকেন্ডারি ডেটা পাইপলাইন হিসেবে কাজ করবে এবং সর্বশেষ ডেটা *Retain* করে রাখবে।
* **Firebase (Auth & Cloud Database):** ব্যবহারকারীর রোল (Admin/User) এবং কোন ক্লায়েন্ট কোন নোডটি অ্যাক্সেস করতে পারবে তার পারমিশন লজিক হ্যান্ডেল করবে।

---

## ২. ফাইনাল এমকিউটিটি টপিক আর্কিটেকচার (MQTT Topic Rules)

নেটওয়ার্ক ট্রাফিক কমানো এবং অ্যাপ সাইডে অপ্রয়োজনীয় লুপ বা ব্যাক-ফায়ার এড়ানোর জন্য টপিক স্ট্রাকচারটি নিচে দেওয়া রুলস অনুযায়ী লক করা হলো:

### ক) ESP32 (Node) সাইড

* **Subscribed Topic:** `ESPHome/nodes/[OWN_MAC]/commands/#` (বাকি পাথ ডাইনামিক হবে, যেমন `sync`, `auto`, `add`, `del`, `state`, `mod`, `sys` ইত্যাদি)
* **Publishing Topics:** (অবশ্যই `Retain = True` সহ পাবলিশ হবে)
  * `ESPHome/nodes/[OWN_MAC]/config` $\rightarrow$ বুট টাইমে নিজের অনলাইন স্ট্যাটাস (`status`, `ip`, `uptime`, `heap`) পাঠাবে। এটির সাথে ব্রোকারে **Last Will and Testament (LWT)** রেজিস্টার করা থাকবে যা ডিভাইস অফলাইন হলে প্লেনটেক্সট `"offline"` রিলিজ করবে।
  * `ESPHome/nodes/[OWN_MAC]/loads/[load_id]` $\rightarrow$ ডাইনামিক লোড বা পিন রেজিস্ট্রেশন কনফিগারেশন (`pin`, `mode`)।
  * `ESPHome/nodes/[OWN_MAC]/states/[load_id]` $\rightarrow$ নির্দিষ্ট লোডের অ্যাক্টিভ অন/অফ স্টেট।
  * `ESPHome/nodes/[OWN_MAC]/sensors/[sensor_type]` $\rightarrow$ সেন্সর রিডিং ও আপটাইম সহ স্প্লিট পাবলিশিং (যেমন `sensors/temperature` এবং `sensors/humidity`)। কোনো সেন্সর না থাকলে শুধু `sensors/uptime` এ আপটাইম পাঠানো হবে।
  * `ESPHome/nodes/[OWN_MAC]/logs` $\rightarrow$ এনক্রিপ্টেড রিয়েল-টাইম ফার্মওয়্যার লগ মেসেজ।

### খ) Flutter App (Client) সাইড

* **Subscribed Topics:** `ESPHome/nodes/+/(config, loads, states, sensors, logs)/#`
  * *লজিক:* প্লাস (`+`) ওয়াইল্ডকার্ডের মাধ্যমে সব নোডের ডেটা একসাথে আসবে। কিন্তু মাঝখানে সুনির্দিষ্ট পাথ থাকায় অ্যাপের পাঠানো কোনো কমান্ড অ্যাপের নিজের কাছে ব্যাক-ফায়ার করবে না।

* **Publishing Topics:** 
  * `ESPHome/nodes/[SPECIFIC_MAC]/commands/[TARGET_PATH]` (নির্দিষ্ট নোডকে কমান্ড পাঠানোর জন্য)।
  * `ESPHome/nodes/[SPECIFIC_MAC]/commands/sync` $\rightarrow$ এই টপিকে হিট করলে নোড তার সমস্ত কনফিগ এবং স্টেট পুনরায় পাবলিশ করবে।

---

## ৩. ডায়নামিক নোড ডিসকভারি ও রোল ফিল্টারিং (Firebase Logic)

সিস্টেমটি মাল্টি-ইউজার হওয়ায় সরাসরি কোনো নোড অ্যাপে যুক্ত হবে না। নিচে ডাটাবেস স্ট্রাকচার ও ফ্লো দেওয়া হলো:

### ফায়ারবেস ডাটাবেস স্কিমা (Firebase Database Schema)

```json
{
  "users": {
    "USER_UID_123": {
      "email": "user@gmail.com",
      "role": "user" // অথবা "admin"
    }
  },
  "pending_requests": {
    "node_mac_A1B2C3": {
      "requested_by_uid": "USER_UID_123",
      "requested_by_email": "user@gmail.com",
      "timestamp": 1719876543
    }
  },
  "approved_nodes": {
    "node_mac_A1B2C3": {
      "owner_uid": "ADMIN_UID_456",
      "shared_users": {
        "USER_UID_123": true
      }
    }
  }
}

```

### নোড রেজিস্ট্রেশন ও পারমিশন ফ্লো:

১. একটি নতুন ESP32 অন হওয়ামাত্রই `ESPHome/[MAC]/config` টপিকে মেসেজ পাঠাবে।
২. অ্যাপ গ্লোবাল সাবস্ক্রিপশনের মাধ্যমে নোডের MAC আইডিটি জানতে পারবে।
৩. অ্যাপ ফায়ারবেসের `approved_nodes` চেক করবে। যদি MAC-টি অনুমোদিত না থাকে এবং ইউজার যদি সাধারণ **"User"** হন, তবে অ্যাপে **"Request to Add"** বাটন দেখাবে।
৪. ইউজার বাটনে চাপ দিলে অ্যাপ নিজের `UID` ও `Email` সহ ফায়ারবেসের `pending_requests`-এ পুশ করবে।
৫. **Admin** তার অ্যাপে নোটিফিকেশন পাবেন এবং "Agree" করলে রিকোয়েস্টটি `approved_nodes`-এ শিফট হবে।
৬. ফায়ারবেস রিয়েল-টাইম লিসেনারের মাধ্যমে সাধারণ ইউজারের অ্যাপে নোডটি তখন ড্যাশবোর্ডে অ্যাক্টিভ হবে।

---

## ৪. হাইব্রিড কানেকশন ও ডেটা ফ্লো (Websocket + MQTT)

সিস্টেমের প্রথম পছন্দ **Websocket (Local)** এবং ব্যাকআপ পছন্দ **MQTT (Cloud/Fallback)**।

```
                  ┌────────────────────────┐
                  │   Flutter App UI       │
                  └───────────┬────────────┘
                              │
               [Connection Manager Engine]
                              │
             ┌────────────────┴────────────────┐
             ▼ (If Local WiFi OK)              ▼ (If Local Offline/Mobile Data)
   【 Websocket Mode 】               【 MQTT Mode 】
   Direct TCP/IP Connection           Publish to Broker
   (Latency < 2ms)                    (Fallback Connection)
             │                                 │
             └────────────────┬────────────────┘
                              ▼
                        【 ESP32 Node 】
            (Process Command -> Trigger GPIO)
                              │
             ┌────────────────┴────────────────┐
             ▼ (Websocket Response)            ▼ (MQTT Retained Publish)
        Direct WS Frame                   Publish to /states/ with Retain=True

```

### কমান্ড ও স্টেট সিঙ্কের বাস্তব সিকোয়েন্স (Request-Response Pattern):

১. **কমান্ড প্রেরণ:** ইউজার অ্যাপে লাইট অন করার বাটন চাপলেন। অ্যাপ সরাসরি লাইটের কালার চেঞ্জ করবে না। অ্যাপ Websocket (অথবা MQTT সেকেন্ডারি মোডে `ESPHome/nodes/[MAC]/commands/light1` টপিকে) কমান্ড পাঠাবে: `{"action": "TURN_ON"}`।
২. **প্রসেসিং:** ESP32 কমান্ডটি রিসিভ করবে, রিলে `HIGH` করবে।
৩. **কনফার্মেশন ও স্টেট পাবলিশ:** রিলে সাকসেসফুলি অন হলে ESP32 তার আউটপুট পাথ `ESPHome/nodes/[MAC]/states/light1`-এ `{"status": "ON"}` মেসেজটি `Retain = True` সহ ছুড়ে মারবে।
৪. **UI রেন্ডার:** অ্যাপ ওই স্টেট পাথ থেকে কনফার্মেশন মেসেজ পাওয়ার পর UI-তে বাটনটি সবুজ/অন দেখাবে।

---

## ৫. ক্লায়েন্ট-সাইড পারসিস্টেন্স ও ক্যাশ লজিক (Flutter Client Engine)

ESP32-এর মেমরি ক্র্যাশ রোধ করতে সব প্রসেসিং লোড ফ্লার্টার অ্যাপ হ্যান্ডেল করবে:

* **Stateless ESP32:** ESP32 ডায়নামিক পাথ তৈরি করে ডেটা পাবলিশ করেই মেমরি ফ্রি করে দেবে। সে নিজে কোনো স্টেট মনে রাখবে না।
* **Stateful Flutter App:** অ্যাপের ব্যাকগ্রাউন্ডে একটি সেন্ট্রাল স্ট্রিম ম্যানেজার থাকবে।
* **টপিক পার্সিং লজিক:** ব্রোকার থেকে যখনই কোনো বাল্ক বা ডায়নামিক মেসেজ আসবে, অ্যাপ স্ট্রিং স্প্লিট (String Split) করে নোড আইডি আলাদা করবে:
```dart
List<String> pathSegments = topic.split('/');
String nodeMac = pathSegments[2]; // node_mac (index 2 for ESPHome/nodes/[MAC])
String pathType = pathSegments[3]; // config, loads, states, or sensors (index 3)

```


* **ক্যাশিং (Hive/Isar):** পার্স করার পর অ্যাপ তার লোকাল ডাটাবেসে `key-value` আকারে স্টেট স্টোর করবে (যেমন: `{"node_mac/states/light1": "ON"}`) এবং ফায়ারবেস থেকে ওই নোডের কাস্টম নাম (যেমন: "Kitchen") নিয়ে UI আপডেট করবে।
* **Fresh Open Sync:** নতুন কোনো ক্লায়েন্ট অ্যাপ ওপেন হওয়ামাত্রই, MQTT ব্রোকার তার মেমরিতে থাকা সব নোডের শেষ রিটেইনড মেসেজগুলো একে একে অ্যাপে পুশ করবে। অ্যাপের লোকাল ক্যাশ সেকেন্ডের মধ্যে সিঙ্ক হয়ে সম্পূর্ণ ড্যাশবোর্ড লোড করে ফেলবে।

---

**নোট:** এই আর্কিটেকচারটি একদিকে যেমন ESP32-এর **Heap Memory** সুরক্ষিত রাখে, অন্যদিকে মাল্টি-ইউজার ও ডায়নামিক পাথের ক্ষেত্রে ফায়ারবেসের মতো শতভাগ সিঙ্কড এবং নিখুঁত ইউজার এক্সপেরিয়েন্স নিশ্চিত করে।