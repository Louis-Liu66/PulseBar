// Include the implementation only in this focused decoder test, so the pure
// validation helpers remain private in the shipped hardware bridge.
#include "../Sources/Hardware.c"
#include <assert.h>
#include <stdio.h>

static int checks;
#define CHECK(value) do { assert(value); ++checks; } while (0)
static bool near(double a, double b) { return fabs(a - b) < 0.000001; }
static CFNumberRef number(int64_t value) {
    return CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
}
static void setNumber(CFMutableDictionaryRef dictionary, CFStringRef key, int64_t value) {
    CFNumberRef boxed = number(value);
    CFDictionarySetValue(dictionary, key, boxed);
    CFRelease(boxed);
}
static CFMutableDictionaryRef batteryProperties(bool connected, bool charging,
                                                int64_t instantMA, int64_t averageMA) {
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(properties, CFSTR("ExternalConnected"), connected ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(properties, CFSTR("IsCharging"), charging ? kCFBooleanTrue : kCFBooleanFalse);
    setNumber(properties, CFSTR("AppleRawCurrentCapacity"), 2000);
    setNumber(properties, CFSTR("AppleRawMaxCapacity"), 4000);
    setNumber(properties, CFSTR("Voltage"), 12000);
    setNumber(properties, CFSTR("InstantAmperage"), instantMA);
    setNumber(properties, CFSTR("Amperage"), averageMA);
    return properties;
}
static void powerBytes(int32_t milliwatts, uint8_t bytes[4]) {
    const uint32_t bits = (uint32_t)milliwatts;
    for (unsigned i = 0; i < 4; ++i) bytes[i] = (uint8_t)(bits >> (8 * i));
}
static void testBatterySMCPower(void) {
    const PBSMCKeyInfo info = {.size = 4, .type = PBFourCC("si32")};
    uint8_t bytes[4] = {0x3d, 0xd3, 0xff, 0xff}; // Live M2 signed -11459 mW.
    double watts = NAN;
    CHECK(PBDecodeBatterySMCPower(info, bytes, &watts) && near(watts, -11.459));
    powerBytes(11459, bytes);
    CHECK(PBDecodeBatterySMCPower(info, bytes, &watts) && near(watts, 11.459));
    powerBytes(0, bytes);
    CHECK(PBDecodeBatterySMCPower(info, bytes, &watts) && watts == 0);
    powerBytes(-500000, bytes);
    CHECK(PBDecodeBatterySMCPower(info, bytes, &watts) && watts == -500);
    powerBytes(500000, bytes);
    CHECK(PBDecodeBatterySMCPower(info, bytes, &watts) && watts == 500);
    powerBytes(500001, bytes);
    CHECK(!PBDecodeBatterySMCPower(info, bytes, &watts));
    powerBytes(-500001, bytes);
    CHECK(!PBDecodeBatterySMCPower(info, bytes, &watts));
    powerBytes(INT32_MIN, bytes);
    CHECK(!PBDecodeBatterySMCPower(info, bytes, &watts));
    powerBytes(INT32_MAX, bytes);
    CHECK(!PBDecodeBatterySMCPower(info, bytes, &watts));
    powerBytes(-10000, bytes);
    CHECK(!PBDecodeBatterySMCPower((PBSMCKeyInfo){.size = 3, .type = info.type}, bytes, &watts));
    CHECK(!PBDecodeBatterySMCPower((PBSMCKeyInfo){.size = 4, .type = PBFourCC("flt ")}, bytes, &watts));
    CHECK(!PBDecodeBatterySMCPower(info, NULL, &watts));
    CHECK(!PBDecodeBatterySMCPower(info, bytes, NULL));

    // Registry readings stay zero until the slower driver poll after unplug;
    // direct signed SMC power supplies a real measurement on the next sample.
    PBBatteryReading reading = {.valid = true, .onACPower = false,
                                .powerValid = true, .netPowerWatts = 0};
    PBApplyBatterySMCPower(&reading, -11.459);
    CHECK(reading.powerValid && near(reading.netPowerWatts, -11.459));
    PBApplyBatterySMCPower(&reading, 10);
    CHECK(near(reading.netPowerWatts, -11.459)); // Never abs a wrong-direction sample.
    PBApplyBatterySMCPower(&reading, 0);
    CHECK(near(reading.netPowerWatts, -11.459)); // Fall back to registry if direct power is unusable.
    PBApplyBatterySMCPower(&reading, -.1);
    CHECK(near(reading.netPowerWatts, -11.459)); // Same low-power threshold as estimator.
    PBApplyBatterySMCPower(&reading, -.25);
    CHECK(near(reading.netPowerWatts, -.25));
    PBApplyBatterySMCPower(&reading, NAN);
    CHECK(near(reading.netPowerWatts, -.25));
    PBApplyBatterySMCPower(&reading, -501);
    CHECK(near(reading.netPowerWatts, -.25));
    reading = (PBBatteryReading){.valid = true, .onACPower = true, .charging = true};
    PBApplyBatterySMCPower(&reading, 20);
    CHECK(reading.powerValid && reading.netPowerWatts == 20 && reading.charging);
    PBApplyBatterySMCPower(&reading, -10);
    CHECK(reading.netPowerWatts == 20); // A charge ETA requires net positive measured power.
    reading.charging = false;
    PBApplyBatterySMCPower(&reading, 0);
    CHECK(reading.netPowerWatts == 0 && !reading.charging);
    PBApplyBatterySMCPower(&reading, 10);
    CHECK(reading.netPowerWatts == 0 && !reading.charging);
    PBApplyBatterySMCPower(&reading, -5);
    CHECK(reading.netPowerWatts == -5 && !reading.charging); // An attached weak supply may discharge.
    reading = (PBBatteryReading){0};
    PBApplyBatterySMCPower(&reading, -10);
    CHECK(!reading.powerValid); // Power never fabricates a missing battery.

    PBHardwareContext context = {0};
    context.batteryPowerInfo = info;
    context.batteryPowerKeyChecked = true;
    PBSMCClose(&context);
    CHECK(!context.batteryPowerKeyChecked && context.batteryPowerInfo.size == 0);
}
int main(void) {
    double amps = NAN;
    CFNumberRef value = number(-693);
    CHECK(PBCFCurrentMilliAmps(value, &amps) && amps == -693);
    CFRelease(value);
    value = number(UINT32_MAX - 692);
    CHECK(PBCFCurrentMilliAmps(value, &amps) && amps == -693);
    CFRelease(value);
    value = number(1250);
    CHECK(PBCFCurrentMilliAmps(value, &amps) && amps == 1250);
    CFRelease(value);
    value = number(0);
    CHECK(PBCFCurrentMilliAmps(value, &amps) && amps == 0);
    CFRelease(value);
    value = number(INT64_MAX);
    CHECK(!PBCFCurrentMilliAmps(value, &amps));
    CFRelease(value);
    value = number(-30001);
    CHECK(!PBCFCurrentMilliAmps(value, &amps));
    CFRelease(value);
    value = number(65535);
    CHECK(!PBCFCurrentMilliAmps(value, &amps));
    CFRelease(value);
    double fractional = 10.5;
    value = CFNumberCreate(NULL, kCFNumberDoubleType, &fractional);
    CHECK(!PBCFCurrentMilliAmps(value, &amps));
    CFRelease(value);
    CHECK(!PBCFCurrentMilliAmps(kCFBooleanTrue, &amps));
    CHECK(!PBCFCurrentMilliAmps(CFSTR("-693"), &amps));
    CHECK(!PBCFCurrentMilliAmps(NULL, &amps));

    PBBatteryReading reading = {.percent = 55, .valid = true};
    PBUpdateBatteryElectrical(&reading, 2061, 3950, 11203, -693);
    CHECK(reading.energyValid && reading.powerValid);
    CHECK(near(reading.remainingEnergyWh, 23.089383));
    CHECK(near(reading.fullChargeEnergyWh, 44.25185));
    CHECK(near(reading.netPowerWatts, -7.763679));
    CHECK(near(reading.precisePercent, 52.1772151898734));
    CHECK(reading.percent == 55); // Preserve macOS's user-facing calibrated gauge.
    CHECK(near(reading.remainingEnergyWh / -reading.netPowerWatts, 2061.0 / 693.0));
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 2000, 4000, 12000, 1500);
    CHECK(reading.energyValid && reading.powerValid && near(reading.netPowerWatts, 18));
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 0, 4000, 12000, 0);
    CHECK(reading.energyValid && reading.remainingEnergyWh == 0 && reading.precisePercent == 0);
    CHECK(reading.powerValid && reading.netPowerWatts == 0);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 80, 100, 12000, -1000);
    CHECK(!reading.energyValid && reading.powerValid); // 0..100 is not mAh.
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, NAN, 4000, 12000, -1000);
    CHECK(!reading.energyValid && reading.powerValid);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 2000, 4000, 12000, NAN);
    CHECK(reading.energyValid && !reading.powerValid);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 2000, 4000, 0, -1000);
    CHECK(!reading.energyValid && !reading.powerValid);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 2000, 4000, INFINITY, -1000);
    CHECK(!reading.energyValid && !reading.powerValid);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 5000, 4000, 12000, -1000);
    CHECK(!reading.energyValid && reading.powerValid);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, -1, 4000, 12000, -1000);
    CHECK(!reading.energyValid && reading.powerValid);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 2000, 4000, 12000, 30001);
    CHECK(reading.energyValid && !reading.powerValid);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryElectrical(&reading, 4001, 4000, 12000, 0);
    CHECK(reading.energyValid && reading.precisePercent == 100); // Mild gauge recalibration.
    CHECK(near(reading.remainingEnergyWh, reading.fullChargeEnergyWh));

    // A transition can publish zero/wrong-direction instant current before the
    // average, and IOPS can still carry the previous charging flag.
    CFMutableDictionaryRef properties = batteryProperties(false, true, 0, -1000);
    reading = (PBBatteryReading){.valid = true, .percent = 80, .onACPower = true, .charging = true};
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(!reading.onACPower && !reading.charging);
    CHECK(reading.energyValid && reading.powerValid && near(reading.netPowerWatts, -12));
    CHECK(reading.percent == 80 && near(reading.remainingEnergyWh, 24));
    setNumber(properties, CFSTR("InstantAmperage"), 500);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(near(reading.netPowerWatts, -12)); // Never take abs(stale positive current).
    setNumber(properties, CFSTR("InstantAmperage"), -500);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(near(reading.netPowerWatts, -6)); // A useful instant sample takes precedence.
    setNumber(properties, CFSTR("InstantAmperage"), -10);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(near(reading.netPowerWatts, -12)); // Below the estimator's 0.25 W deadband.
    setNumber(properties, CFSTR("InstantAmperage"), 0);
    setNumber(properties, CFSTR("Amperage"), 0);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(reading.powerValid && reading.netPowerWatts == 0); // No invented load if both lag.
    CFDictionaryRemoveValue(properties, CFSTR("InstantAmperage"));
    setNumber(properties, CFSTR("Amperage"), -750);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(near(reading.netPowerWatts, -9)); // Missing instant field still uses measured average.
    CFDictionaryRemoveValue(properties, CFSTR("Amperage"));
    reading = (PBBatteryReading){0};
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(!reading.powerValid && reading.energyValid);
    CFRelease(properties);

    properties = batteryProperties(true, true, -500, 1500);
    reading = (PBBatteryReading){0};
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(reading.onACPower && reading.charging && near(reading.netPowerWatts, 18));
    CFDictionarySetValue(properties, CFSTR("IsCharging"), kCFBooleanFalse);
    setNumber(properties, CFSTR("InstantAmperage"), 0);
    CFMutableDictionaryRef charger = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    setNumber(charger, CFSTR("NotChargingReason"), 1U << 24);
    CFDictionarySetValue(properties, CFSTR("ChargerData"), charger);
    CFRelease(charger);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(reading.onACPower && !reading.charging && reading.chargeLimited);
    CHECK(reading.netPowerWatts == 0); // AC hold does not reuse the prior charging average.
    setNumber(properties, CFSTR("InstantAmperage"), -1000);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(!reading.charging && near(reading.netPowerWatts, -12)); // Weak AC may still discharge.
    CFDictionarySetValue(properties, CFSTR("ExternalConnected"), kCFBooleanFalse);
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(!reading.onACPower && !reading.charging && !reading.chargeLimited);
    CFDictionaryRemoveValue(properties, CFSTR("ExternalConnected"));
    CFDictionaryRemoveValue(properties, CFSTR("IsCharging"));
    reading = (PBBatteryReading){.onACPower = true, .charging = true};
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(reading.onACPower && reading.charging); // Absent optional state retains IOPS fallback.
    CFDictionarySetValue(properties, CFSTR("ExternalConnected"), CFSTR("false"));
    PBUpdateBatteryRegistry(&reading, properties);
    CHECK(reading.onACPower); // Malformed state is not confused with a valid disconnection.
    CFRelease(properties);
    testBatterySMCPower();
    printf("%d battery electrical decoding, signed-current and unit checks passed.\n", checks);
    return 0;
}
