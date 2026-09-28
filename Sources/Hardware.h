#ifndef PULSEBAR_HARDWARE_H
#define PULSEBAR_HARDWARE_H

#include <stdbool.h>
#include <stdint.h>

// Internal, read-only hardware bridge. Each context belongs to one serial queue.
typedef struct PBHardwareContext PBHardwareContext;

typedef struct {
    uint32_t user;
    uint32_t system;
    uint32_t idle;
    uint32_t nice;
} PBCPUTicks;

typedef struct {
    uint64_t totalBytes;
    uint64_t usedBytes;
    bool valid;
} PBMemoryReading;

typedef struct {
    double percent;
    bool valid;
    bool charging;
    bool onACPower;
    bool fullyCharged;
    bool chargeLimited;
    // Raw pack capacity (mAh) × present voltage (V). Optional; these are not
    // adapter power or macOS's precomputed time-remaining estimates.
    double remainingEnergyWh;
    double fullChargeEnergyWh;
    double netPowerWatts; // Positive into the battery, negative out of it.
    double precisePercent; // Raw charge ratio; may differ from the UI gauge.
    bool energyValid;
    bool powerValid;
} PBBatteryReading;

typedef struct {
    double celsius;
    int sensorCount;
    bool valid;
} PBTemperatureReading;

PBHardwareContext *PBHardwareCreate(void);
void PBHardwareDestroy(PBHardwareContext *context);
bool PBReadCPUTicks(PBCPUTicks *reading);
PBMemoryReading PBReadMemory(void);
PBBatteryReading PBReadBattery(void);
// Reuses the context's read-only SMC connection for a fresh battery-power sample.
// Falls back to the same registry reading if this Mac lacks a supported key.
PBBatteryReading PBReadBatteryWithContext(PBHardwareContext *context);
PBTemperatureReading PBReadTemperature(PBHardwareContext *context);

#endif
