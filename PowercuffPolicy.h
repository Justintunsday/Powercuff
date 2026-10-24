#ifndef POWERCUFF_POLICY_H
#define POWERCUFF_POLICY_H
#include <stdint.h>
#include <stdbool.h>
static inline bool PCValidMode(uint64_t mode) { return mode <= 4; }
static inline const char *PCModeName(uint64_t mode) {
    static const char *const names[] = { "off", "nominal", "light", "moderate", "heavy" };
    return PCValidMode(mode) ? names[mode] : "off";
}
static inline unsigned int PCClampIndex(unsigned int native, unsigned int cap) {
    return native < cap ? native : cap;
}
#endif
