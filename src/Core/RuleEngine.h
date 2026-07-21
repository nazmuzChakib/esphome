#ifndef RULE_ENGINE_H
#define RULE_ENGINE_H

#include <Arduino.h>

class RuleEngine {
public:
    static RuleEngine& getInstance();

    // Initialized rule configurations from rules.json
    bool begin();
    
    // Core 1 Evaluation: Process sensor values and toggle relay outputs under hysteresis limits
    void evaluateRules(float temperature, float humidity);

    // Getters/Setters for dynamic user-defined hysteresis bands
    void setHysteresis(float val);
    float getHysteresis() const;

private:
    RuleEngine();
    ~RuleEngine() = default;
    RuleEngine(const RuleEngine&) = delete;
    RuleEngine& operator=(const RuleEngine&) = delete;

    float _hysteresis;
    bool _relayState; 
};

#endif // RULE_ENGINE_H
