#include "Hardware.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <mach/mach.h>
#include <mach/host_info.h>
#include <mach/vm_statistics.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>

// AppleSMC's existing IOKit ABI, expressed as local read-only message types.
// The driver is not a public temperature API; unsupported versions fail closed.
// References for ABI facts and CPU key names:
// https://github.com/beltex/SMCKit/blob/master/SMCKit/SMC.swift
// https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift
typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} PBSMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpu, gpu, memory;
} PBSMCLimits;

typedef struct {
    uint32_t size, type;
    uint8_t attributes;
} PBSMCKeyInfo;

typedef struct {
    uint32_t key;
    PBSMCVersion version;
    PBSMCLimits limits;
    PBSMCKeyInfo keyInfo;
    uint8_t result, status, command;
    uint32_t argument;
    uint8_t bytes[32];
} PBSMCMessage;

_Static_assert(sizeof(PBSMCMessage) == 80, "AppleSMC message ABI must be 80 bytes");
_Static_assert(offsetof(PBSMCMessage, keyInfo) == 28, "AppleSMC key-info ABI");
_Static_assert(offsetof(PBSMCMessage, bytes) == 48, "AppleSMC payload ABI");

typedef struct {
    uint32_t key;
    PBSMCKeyInfo info;
} PBSMCSensor;

struct PBHardwareContext {
    io_connect_t smc;
    PBSMCSensor sensors[32];
    size_t sensorCount;
    double nextDiscoveryTime;
    PBSMCKeyInfo batteryPowerInfo;
    bool batteryPowerKeyChecked;
};

static double PBMonotonicSeconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static uint32_t PBFourCC(const char *key) {
    return ((uint32_t)(uint8_t)key[0] << 24) |
           ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint8_t)key[3];
}

static bool PBSMCCall(PBHardwareContext *context, const PBSMCMessage *input,
                      PBSMCMessage *output) {
    if (!context || !context->smc) return false;
    memset(output, 0, sizeof(*output));
    size_t length = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(context->smc, 2, input,
                                                     sizeof(*input), output, &length);
    return result == KERN_SUCCESS && length == sizeof(*output) && output->result == 0;
}

static void PBSMCClose(PBHardwareContext *context) {
    if (context->smc) IOServiceClose(context->smc);
    context->smc = IO_OBJECT_NULL;
    context->sensorCount = 0;
    context->batteryPowerInfo = (PBSMCKeyInfo){0};
    context->batteryPowerKeyChecked = false;
}

// Opening the connection is kept separate from enumerating CPU temperature
// keys. Battery sampling needs one known key and must not wait on the entire
// optional temperature-key scan before it can report a fresh power value.
static bool PBSMCOpen(PBHardwareContext *context) {
    if (!context) return false;
    if (context->smc) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return false;
    kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0, &context->smc);
    IOObjectRelease(service);
    if (opened != KERN_SUCCESS) {
        context->smc = IO_OBJECT_NULL;
        return false;
    }
    return true;
}

static bool PBSMCDiscover(PBHardwareContext *context) {
    if (!context) return false;
    const double now = PBMonotonicSeconds();
    if (now < context->nextDiscoveryTime) return context->sensorCount > 0;
    context->nextDiscoveryTime = now + 60;
    if (!PBSMCOpen(context)) return false;
    context->sensorCount = 0;

    // Known CPU temperature sensors only. No battery, enclosure or GPU readings
    // are relabelled as CPU temperature. Keys absent on this Mac are discarded.
    static const char *const keys[] = {
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
        "Tp1h", "Tp1t", "Tp1p", "Tp1l", // M2 family
        "Tp0T", "Tp0H", "Tp0L", "Tp0P", // Additional M1 family sensors
        "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B",
        "TC0D", "TC0P", "TCAD" // Older hardware fallbacks
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        PBSMCMessage input = {0}, output = {0};
        input.key = PBFourCC(keys[i]);
        input.command = 9; // Read metadata only.
        if (!PBSMCCall(context, &input, &output)) continue;
        const PBSMCKeyInfo info = output.keyInfo;
        const bool supported = (info.type == PBFourCC("flt ") && info.size == 4) ||
                               (info.type == PBFourCC("sp78") && info.size == 2);
        if (!supported) continue;
        context->sensors[context->sensorCount++] = (PBSMCSensor){input.key, info};
    }
    return context->sensorCount > 0;
}

PBHardwareContext *PBHardwareCreate(void) {
    return calloc(1, sizeof(PBHardwareContext));
}

void PBHardwareDestroy(PBHardwareContext *context) {
    if (!context) return;
    PBSMCClose(context);
    free(context);
}

bool PBReadCPUTicks(PBCPUTicks *reading) {
    if (!reading) return false;
    host_cpu_load_info_data_t info = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    const mach_port_t host = mach_host_self();
    const kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO,
                                                  (host_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS || count != HOST_CPU_LOAD_INFO_COUNT) return false;
    *reading = (PBCPUTicks){info.cpu_ticks[CPU_STATE_USER], info.cpu_ticks[CPU_STATE_SYSTEM],
                            info.cpu_ticks[CPU_STATE_IDLE], info.cpu_ticks[CPU_STATE_NICE]};
    return true;
}

PBMemoryReading PBReadMemory(void) {
    PBMemoryReading reading = {0};
    size_t size = sizeof(reading.totalBytes);
    if (sysctlbyname("hw.memsize", &reading.totalBytes, &size, NULL, 0) != 0 ||
        size != sizeof(reading.totalBytes) || !reading.totalBytes) return reading;

    vm_statistics64_data_t info = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t pageSize = 0;
    const mach_port_t host = mach_host_self();
    const kern_return_t statsResult = host_statistics64(host, HOST_VM_INFO64,
                                                         (host_info64_t)&info, &count);
    const kern_return_t pageResult = host_page_size(host, &pageSize);
    mach_port_deallocate(mach_task_self(), host);
    // New SDKs append VM fields. Older running kernels return a shorter valid
    // prefix (26.4 returns 40 words with a 26.5 SDK advertising 62). Only require
    // the fields we actually read, rather than the latest SDK's entire struct.
    const size_t requiredBytes = offsetof(vm_statistics64_data_t, external_page_count)
                               + sizeof(info.external_page_count);
    if (statsResult != KERN_SUCCESS || pageResult != KERN_SUCCESS || !pageSize ||
        (size_t)count * sizeof(integer_t) < requiredBytes) return reading;

    // Approximation of Activity Monitor's Memory Used: resident application,
    // wired and compressed pages, excluding reclaimable file cache/purgeable
    // pages. Speculative file pages must be included before subtracting external
    // pages, which include that same cache. This is not memory-pressure percent.
    const uint64_t residentPages = (uint64_t)info.active_count + info.inactive_count +
        info.speculative_count + info.wire_count + info.compressor_page_count;
    const uint64_t reclaimablePages = (uint64_t)info.purgeable_count + info.external_page_count;
    if (reclaimablePages > residentPages) return reading;
    const uint64_t usedPages = residentPages - reclaimablePages;
    if (usedPages > UINT64_MAX / pageSize) return reading;
    const uint64_t usedBytes = usedPages * pageSize;
    reading.usedBytes = usedBytes > reading.totalBytes ? reading.totalBytes : usedBytes;
    reading.valid = true;
    return reading;
}

static bool PBCFNumber(CFDictionaryRef dictionary, CFStringRef key, double *result) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, result) &&
           isfinite(*result);
}

static bool PBCFBoolean(CFDictionaryRef dictionary, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    return value && CFGetTypeID(value) == CFBooleanGetTypeID() &&
           CFBooleanGetValue((CFBooleanRef)value);
}

static double PBDictionaryNumber(CFDictionaryRef dictionary, CFStringRef key) {
    double number = NAN;
    (void)PBCFNumber(dictionary, key, &number);
    return number;
}

// IOKit's current is a signed mA integer. ioreg may print its unsigned bit
// pattern; converting through Double would lose low bits in a 64-bit pattern.
// CFNumber's signed conversion preserves actual negative values. Also accept
// a zero-extended 32-bit two's-complement value from older driver variants.
static bool PBCFCurrentMilliAmps(CFTypeRef value, double *result) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
        CFNumberIsFloatType((CFNumberRef)value)) return false;
    int64_t signedValue = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &signedValue)) return false;
    if (signedValue > INT32_MAX && signedValue <= UINT32_MAX) signedValue -= (INT64_C(1) << 32);
    if (signedValue < -30000 || signedValue > 30000) return false;
    *result = (double)signedValue;
    return true;
}

static double PBDictionaryCurrent(CFDictionaryRef dictionary, CFStringRef key) {
    double current = NAN;
    (void)PBCFCurrentMilliAmps(CFDictionaryGetValue(dictionary, key), &current);
    return current;
}

// At a power-source transition the instant current may still be zero or have
// the previous direction while the controller's average already reflects the
// new state. Use a measured, direction-consistent fallback, never abs(current).
static double PBSelectBatteryCurrent(double instantMA, double averageMA,
                                     double voltageMV, bool onACPower, bool charging) {
    if (onACPower && !charging) {
        // A charge-limit hold can legitimately report zero. Do not replace it
        // with the earlier positive average and suggest charging has restarted.
        return isfinite(instantMA) ? instantMA : averageMA;
    }
    const double direction = onACPower ? 1.0 : -1.0;
    const double instantWatts = direction * instantMA * voltageMV / 1000000.0;
    const double averageWatts = direction * averageMA * voltageMV / 1000000.0;
    if (isfinite(instantWatts) && instantWatts >= 0.25) return instantMA;
    if (isfinite(averageWatts) && averageWatts >= 0.25) return averageMA;
    // Preserve missing, zero or contradictory data when neither is usable;
    // the estimator can expire its short grace period without inventing power.
    return isfinite(instantMA) ? instantMA : averageMA;
}

// Voltage is pack mV, raw capacities are mAh, current is signed pack mA.
// Multiplying by voltage gives Wh and W; their ratio cancels the current
// voltage in the ETA, avoiding a claim to model future discharge voltage.
// Never treat Apple Silicon's normalized CurrentCapacity/MaxCapacity (0..100)
// as mAh. Missing/implausible raw properties simply leave estimates unavailable.
// Units: SDK IOPMPowerSource.h; Apple driver signed-current publication:
// https://github.com/apple-oss-distributions/PowerManagement/blob/main/AppleSmartBatteryManager/AppleSmartBattery.cpp
// Apple Silicon raw capacity keys:
// https://github.com/exelban/stats/blob/master/Modules/Battery/readers.swift
static void PBUpdateBatteryElectrical(PBBatteryReading *reading, double currentMAh,
                                     double maximumMAh, double voltageMV, double currentMA) {
    if (!isfinite(voltageMV) || voltageMV < 5000 || voltageMV > 25000) return;
    if (isfinite(currentMAh) && isfinite(maximumMAh) && maximumMAh > 100 &&
        maximumMAh <= 30000 && currentMAh >= 0 && currentMAh <= maximumMAh * 1.1) {
        // The gauge can briefly recalibrate a little above full capacity.
        // Bound energy consistently with the raw percentage in that case.
        reading->remainingEnergyWh = fmin(currentMAh, maximumMAh) * voltageMV / 1000000.0;
        reading->fullChargeEnergyWh = maximumMAh * voltageMV / 1000000.0;
        reading->precisePercent = fmin(100, 100.0 * currentMAh / maximumMAh);
        reading->energyValid = true;
    }
    if (isfinite(currentMA) && fabs(currentMA) <= 30000) {
        reading->netPowerWatts = currentMA * voltageMV / 1000000.0;
        reading->powerValid = true;
    }
}

static void PBUpdateBatteryRegistry(PBBatteryReading *reading, CFDictionaryRef properties) {
    // Resolve state and electrical values from the same registry snapshot.
    // IOPS remains a fallback if optional registry state fields are absent.
    CFTypeRef connected = CFDictionaryGetValue(properties, CFSTR("ExternalConnected"));
    if (connected && CFGetTypeID(connected) == CFBooleanGetTypeID()) {
        reading->onACPower = CFBooleanGetValue((CFBooleanRef)connected);
    }
    CFTypeRef charging = CFDictionaryGetValue(properties, CFSTR("IsCharging"));
    if (charging && CFGetTypeID(charging) == CFBooleanGetTypeID()) {
        reading->charging = CFBooleanGetValue((CFBooleanRef)charging);
    }
    // Physical disconnection overrides a delayed cached charging flag.
    if (!reading->onACPower) reading->charging = false;

    const double currentMAh = PBDictionaryNumber(properties, CFSTR("AppleRawCurrentCapacity"));
    const double maximumMAh = PBDictionaryNumber(properties, CFSTR("AppleRawMaxCapacity"));
    const double voltageMV = PBDictionaryNumber(properties, CFSTR("Voltage"));
    const double currentMA = PBSelectBatteryCurrent(
        PBDictionaryCurrent(properties, CFSTR("InstantAmperage")),
        PBDictionaryCurrent(properties, CFSTR("Amperage")), voltageMV,
        reading->onACPower, reading->charging);
    PBUpdateBatteryElectrical(reading, currentMAh, maximumMAh, voltageMV, currentMA);

    // Apple Silicon's optional charge-limit hold uses NotChargingReason bit 24.
    // https://github.com/killerk3emstar/OpenDente#apples-native-charge-limit-macos-264
    reading->chargeLimited = false;
    if (reading->onACPower && !reading->charging) {
        CFTypeRef data = CFDictionaryGetValue(properties, CFSTR("ChargerData"));
        if (data && CFGetTypeID(data) == CFDictionaryGetTypeID()) {
            double reason = 0;
            if (PBCFNumber((CFDictionaryRef)data, CFSTR("NotChargingReason"), &reason) &&
                reason >= 0 && reason <= UINT32_MAX && reason == floor(reason)) {
                reading->chargeLimited = (((uint32_t)reason & (1U << 24)) != 0);
            }
        }
    }
}

PBBatteryReading PBReadBattery(void) {
    PBBatteryReading reading = {0};
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info) return reading;
    CFStringRef sourceType = IOPSGetProvidingPowerSourceType(info);
    reading.onACPower = sourceType && CFEqual(sourceType, CFSTR(kIOPSACPowerValue));
    CFArrayRef sources = IOPSCopyPowerSourcesList(info);
    if (sources) {
        for (CFIndex i = 0; i < CFArrayGetCount(sources); ++i) {
            CFDictionaryRef description = IOPSGetPowerSourceDescription(info,
                                                      CFArrayGetValueAtIndex(sources, i));
            if (!description) continue;
            CFTypeRef type = CFDictionaryGetValue(description, CFSTR(kIOPSTypeKey));
            if (!type || !CFEqual(type, CFSTR(kIOPSInternalBatteryType))) continue;
            double current = 0, maximum = 0;
            if (PBCFNumber(description, CFSTR(kIOPSCurrentCapacityKey), &current) &&
                PBCFNumber(description, CFSTR(kIOPSMaxCapacityKey), &maximum) &&
                current >= 0 && maximum > 0) {
                reading.percent = fmin(100, fmax(0, 100 * current / maximum));
                reading.valid = true;
            }
            reading.charging = PBCFBoolean(description, CFSTR(kIOPSIsChargingKey));
            reading.fullyCharged = PBCFBoolean(description, CFSTR(kIOPSIsChargedKey));
            break;
        }
        CFRelease(sources);
    }
    CFRelease(info);
    // One local snapshot avoids combining flags and current from opposite sides
    // of an unplug event. Only the selected state/energy fields are consumed;
    // no registry identifiers are retained, logged or sent anywhere.
    if (reading.valid) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("AppleSmartBattery"));
        if (service) {
            CFMutableDictionaryRef properties = NULL;
            if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) ==
                    KERN_SUCCESS && properties) {
                PBUpdateBatteryRegistry(&reading, properties);
            }
            if (properties) CFRelease(properties);
            IOObjectRelease(service);
        }
    }
    return reading;
}

// Apple Silicon B0AP is signed pack power in mW. On this Mac its si32
// four-byte payload is little-endian, verified against live discharge
// readings. Require exact metadata rather than interpreting an unknown type.
// Key and unit reference (interface facts only, implementation written here):
// https://github.com/torvalds/linux/blob/master/drivers/power/supply/macsmc-power.c
static bool PBDecodeBatterySMCPower(PBSMCKeyInfo info, const uint8_t *bytes,
                                    double *watts) {
    if (!bytes || !watts || info.size != 4 || info.type != PBFourCC("si32")) return false;
    const uint32_t bits = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
    const int64_t signedMilliwatts = (bits & UINT32_C(0x80000000))
        ? (int64_t)bits - (INT64_C(1) << 32) : (int64_t)bits;
    const double decoded = (double)signedMilliwatts / 1000.0;
    if (fabs(decoded) > 500) return false;
    *watts = decoded;
    return true;
}

static double PBReadBatterySMCPower(PBHardwareContext *context) {
    if (!PBSMCOpen(context)) return NAN;
    if (!context->batteryPowerKeyChecked) {
        PBSMCMessage input = {0}, output = {0};
        input.key = PBFourCC("B0AP");
        input.command = 9; // Metadata only, cached until the connection closes.
        context->batteryPowerKeyChecked = true;
        if (PBSMCCall(context, &input, &output) && output.keyInfo.size == 4 &&
            output.keyInfo.type == PBFourCC("si32")) {
            context->batteryPowerInfo = output.keyInfo;
        }
    }
    if (context->batteryPowerInfo.size != 4) return NAN;
    PBSMCMessage input = {0}, output = {0};
    input.key = PBFourCC("B0AP");
    input.keyInfo = context->batteryPowerInfo;
    input.command = 5; // Read sensor bytes. Never request a write or forced poll.
    double watts = NAN;
    if (!PBSMCCall(context, &input, &output) ||
        !PBDecodeBatterySMCPower(context->batteryPowerInfo, output.bytes, &watts)) return NAN;
    return watts;
}

static void PBApplyBatterySMCPower(PBBatteryReading *reading, double watts) {
    if (!reading->valid || !isfinite(watts) || fabs(watts) > 500) return;
    // Ignore directionally contradictory transitional data. A plugged-in hold
    // can be zero or net discharging, but cannot imply charging from power alone.
    const bool usable = !reading->onACPower ? watts <= -0.25 :
        (reading->charging ? watts >= 0.25 : watts <= 0);
    if (!usable) return;
    reading->netPowerWatts = watts;
    reading->powerValid = true;
}

PBBatteryReading PBReadBatteryWithContext(PBHardwareContext *context) {
    PBBatteryReading reading = PBReadBattery();
    if (reading.valid) PBApplyBatterySMCPower(&reading, PBReadBatterySMCPower(context));
    return reading;
}

PBTemperatureReading PBReadTemperature(PBHardwareContext *context) {
    PBTemperatureReading reading = {0};
    if (!context) return reading;
    if ((!context->smc || !context->sensorCount) && !PBSMCDiscover(context)) return reading;

    int responses = 0;
    for (size_t i = 0; i < context->sensorCount; ++i) {
        const PBSMCSensor sensor = context->sensors[i];
        PBSMCMessage input = {0}, output = {0};
        input.key = sensor.key;
        input.keyInfo.size = sensor.info.size;
        input.command = 5; // Read sensor bytes. No write command exists in this code.
        if (!PBSMCCall(context, &input, &output)) continue;
        ++responses;
        double temperature = NAN;
        if (sensor.info.type == PBFourCC("flt ")) {
            // Apple Silicon flt values are IEEE 754 little-endian.
            const uint32_t bits = (uint32_t)output.bytes[0] | ((uint32_t)output.bytes[1] << 8) |
                ((uint32_t)output.bytes[2] << 16) | ((uint32_t)output.bytes[3] << 24);
            float value;
            memcpy(&value, &bits, sizeof(value));
            temperature = value;
        } else if (sensor.info.type == PBFourCC("sp78")) {
            const int16_t raw = (int16_t)(((uint16_t)output.bytes[0] << 8) | output.bytes[1]);
            temperature = (double)raw / 256.0;
        }
        // Sleeping/offline sensors often contain zero or sentinel values.
        if (!isfinite(temperature) || temperature < 5 || temperature > 125) continue;
        if (!reading.valid || temperature > reading.celsius) reading.celsius = temperature;
        reading.valid = true;
        ++reading.sensorCount;
    }
    if (!responses) {
        PBSMCClose(context);
        context->nextDiscoveryTime = PBMonotonicSeconds() + 5;
    }
    return reading;
}
