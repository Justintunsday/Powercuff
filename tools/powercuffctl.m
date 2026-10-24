#import <Foundation/Foundation.h>
#import <notify.h>
#import <unistd.h>
#import "PowercuffPolicy.h"
#import "PowercuffProtocol.h"
extern int PCBenchmark(const char *kind, NSUInteger seconds);

static int RequestStatus(void) {
    int request = -1, response = -1, status = -1;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    uint64_t nonce = ((uint64_t)arc4random() << 32) | arc4random();
    uint32_t result = notify_register_dispatch(PC_RESPONSE, &response,
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(int token) {
            uint64_t value = 0;
            if (notify_get_state(token, &value) == NOTIFY_STATUS_OK && value == nonce)
                dispatch_semaphore_signal(semaphore);
        });
    if (result != NOTIFY_STATUS_OK) return 2;
    if (notify_register_check(PC_DIAGNOSTICS, &request) != NOTIFY_STATUS_OK ||
        notify_register_check(PC_STATUS, &status) != NOTIFY_STATUS_OK ||
        notify_set_state(request, nonce) != NOTIFY_STATUS_OK || notify_post(PC_DIAGNOSTICS) != NOTIFY_STATUS_OK) {
        notify_cancel(response);
        if (request >= 0) notify_cancel(request);
        if (status >= 0) notify_cancel(status);
        return 2;
    }
    long timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    uint64_t state = 0;
    result = notify_get_state(status, &state);
    notify_cancel(request);
    notify_cancel(response);
    notify_cancel(status);
    if (timedOut || result != NOTIFY_STATUS_OK) {
        fputs("No fresh thermalmonitord reply. Injection, daemon health, or notification access is unverified.\n", stderr);
        return 2;
    }
    NSDictionary *report = @{
        @"fresh_daemon_reply": @YES, @"daemon_pid": @(state >> 32),
        @"requested_mode": @(PCModeName((state >> 3) & 7)), @"active_mode": @(PCModeName(state & 7)),
        @"product_initialized": @((state & (1 << 6)) != 0), @"mode_supported": @((state & (1 << 7)) != 0),
        @"mode_rejected": @((state & (1 << 8)) != 0), @"hooks_installed": @((state & (1 << 9)) != 0),
        @"clamp_forwarded": @((state & (1 << 10)) != 0), @"clamp_calls_mod_65536": @((state >> 16) & 0xffff),
        @"setter_readback_matched": @((state & (1 << 11)) != 0),
        @"native_index_transition_observed": @((state & (1 << 12)) != 0),
        @"emergency_off_latched": @((state & (1 << 13)) != 0),
        @"system_thermal_state": @(NSProcessInfo.processInfo.thermalState), @"performance_effect": @"unmeasured",
        @"restoration": @"Off removes additional caps; verify native-loop recovery with benchmarks"
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    if (state & (1 << 8)) return 3;
    return (state & (1 << 6)) && (state & (1 << 9)) ? 0 : 2;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 4 && strcmp(argv[1], "benchmark") == 0) {
            char *end = NULL;
            unsigned long seconds = strtoul(argv[3], &end, 10);
            if (!argv[3][0] || !end || *end) return 1;
            return PCBenchmark(argv[2], seconds);
        }
        if (argc == 2 && strcmp(argv[1], "status") == 0) return RequestStatus();
        if (argc == 2 && strcmp(argv[1], "restore") == 0) {
            uint32_t result = notify_post(PC_RESTORE);
            puts("Emergency Off requested; run status and allow the native loop to settle. Restart thermalmonitord to reenable.");
            return result == NOTIFY_STATUS_OK ? 0 : 2;
        }
        if (argc == 3 && (strcmp(argv[1], "mode") == 0 || strcmp(argv[1], "lpm-only") == 0)) {
            if (getuid() != 501 || geteuid() != 501) {
                fputs("Run preference changes as mobile (uid 501), so SpringBoard reads the same domain.\n", stderr);
                return 1;
            }
            NSNumber *value = nil;
            CFStringRef key;
            if (strcmp(argv[1], "mode") == 0) {
                for (NSUInteger mode = 0; mode <= 4; mode++)
                    if (strcmp(argv[2], PCModeName(mode)) == 0) value = @(mode);
                key = CFSTR("PowerMode");
            } else {
                if (strcmp(argv[2], "on") == 0) value = @YES;
                if (strcmp(argv[2], "off") == 0) value = @NO;
                key = CFSTR("RequireLowPowerMode");
            }
            if (!value) { fputs("Invalid value.\n", stderr); return 1; }
            CFPreferencesSetAppValue(key, (__bridge CFPropertyListRef)value, CFSTR(PC_PREFS));
            if (!CFPreferencesAppSynchronize(CFSTR(PC_PREFS))) return 2;
            if (notify_post(PC_SETTINGS) != NOTIFY_STATUS_OK) return 2;
            puts("Settings saved and notification posted; use status to check the daemon. This is not proof of throttling.");
            return 0;
        }
        fputs("Usage: powercuffctl status | restore | mode off|nominal|light|moderate|heavy | lpm-only on|off | benchmark cpu|gpu 2..30\n", stderr);
        return 1;
    }
}
