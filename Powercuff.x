#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <os/log.h>
#import <math.h>
#import <unistd.h>
#import <sys/sysctl.h>
#import <rootless.h>
#import "PowercuffPolicy.h"
#import "PowercuffProtocol.h"

// Keep Apple's control loop running. Never enter forced thermal simulation.
@interface CommonProduct : NSObject
- (id)initProduct:(id)data;
- (NSArray *)listofComponentControl;
@end
@interface ComponentControl : NSObject
- (CFStringRef)nameofComponent;
- (int)mitigationType;
- (unsigned int)maxLoadingIndex;
- (int)getReleaseMaxLI;
- (void)setMaxLoadingIndex:(unsigned int)index releaseIndex:(unsigned int)release;
@end

static os_log_t logger;
static NSObject *stateLock;
static __weak CommonProduct *currentProduct;
static NSDictionary<NSString *, NSNumber *> *activeLimits;
static NSUInteger requestedMode, activeMode;
static BOOL hookReady, productSeen, supported, rejected, restoreLatch;
static uint64_t clampCalls;
static BOOL setterAccepted, stateTransition;
static int modeToken = -1, settingsToken = -1, diagnosticToken = -1;
static int responseToken = -1, statusToken = -1, restoreToken = -1;
static BOOL receivedSelection;
static const void *lastClampKey = &lastClampKey;
static NSMutableArray<NSString *> *events;
static BOOL MethodMatches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments);
static void RecordEvent(NSString *event) {
    @synchronized (stateLock) {
        if (!events) events = [NSMutableArray array];
        if (events.count >= 150) [events removeObjectAtIndex:0];
        [events addObject:event];
    }
}
static void RecordFormatted(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *text = [[NSString alloc] initWithFormat:[format stringByReplacingOccurrencesOfString:@"{public}" withString:@""] arguments:arguments];
    va_end(arguments);
    RecordEvent(text);
}
#define PCLog(format, ...) do { \
    os_log_with_type(logger, OS_LOG_TYPE_DEFAULT, format, ##__VA_ARGS__); \
    RecordFormatted(@format, ##__VA_ARGS__); \
} while (0)

// Verified in PackagePowerCC's initializer and on the live 20B101 device.
// Table positions are NOT mitigationType values. Restrict to this proven class.
static NSString *KeyForComponent(ComponentControl *component) {
    Class package = NSClassFromString(@"PackagePowerCC");
    return package && [component isKindOfClass:package] && [component mitigationType] == 13 ? @"dtPackage" : nil;
}

static void WriteDiagnostics(NSString *process) {
    NSArray *snapshot;
    NSDictionary *limits;
    @synchronized (stateLock) { snapshot = [events copy]; limits = activeLimits; }
    NSMutableArray *readback = [NSMutableArray array];
    CommonProduct *product = currentProduct;
    if (hookReady && product && MethodMatches(object_getClass(product), @selector(listofComponentControl), "@", @[])) {
        id components = [product listofComponentControl];
        if ([components isKindOfClass:[NSArray class]]) {
            for (ComponentControl *component in components) {
                if (!KeyForComponent(component)) continue;
                [readback addObject:@{ @"class": NSStringFromClass(object_getClass(component)),
                    @"type": @([component mitigationType]), @"key": KeyForComponent(component),
                    @"index": @([component maxLoadingIndex]), @"release_index": @([component getReleaseMaxLI]) }];
            }
        }
    }
    NSDictionary *report = @{ @"process": process, @"pid": @(getpid()),
        @"timestamp": [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:[NSTimeZone timeZoneForSecondsFromGMT:0] formatOptions:NSISO8601DateFormatWithInternetDateTime],
        @"native_readback": readback,
        @"events": snapshot ?: @[], @"active_limits": limits ?: @{},
        @"performance_effect": @"unmeasured" };
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    NSString *directory = ROOT_PATH_NS(@"/var/log/Powercuff");
    if ([process isEqualToString:@"SpringBoard"]) directory = [directory stringByAppendingPathComponent:@"mobile"];
    NSString *path = [directory stringByAppendingPathComponent:[process stringByAppendingPathExtension:@"json"]];
    NSError *error;
    if (![json writeToFile:path options:NSDataWritingAtomic error:&error])
        os_log_error(logger, "diagnostic-file-error=%{public}@", error);
}

static BOOL MethodMatches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != arguments.count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL matches = type && strcmp(type, result) == 0;
    free(type);
    for (NSUInteger i = 0; matches && i < arguments.count; i++) {
        type = method_copyArgumentType(method, (unsigned int)i + 2);
        matches = type && strcmp(type, arguments[i].UTF8String) == 0;
        free(type);
    }
    PCLog("stage=abi selector=%{public}s types=%{public}s compatible=%d", sel_getName(selector), method_getTypeEncoding(method), matches);
    return matches;
}

static void PublishStatus(void) {
    uint64_t state;
    @synchronized (stateLock) {
        state = activeMode | (requestedMode << 3) | ((uint64_t)productSeen << 6) |
            ((uint64_t)supported << 7) | ((uint64_t)rejected << 8) | ((uint64_t)hookReady << 9) |
            ((uint64_t)(clampCalls != 0) << 10) | ((uint64_t)setterAccepted << 11) |
            ((uint64_t)stateTransition << 12) | ((uint64_t)restoreLatch << 13) |
            ((clampCalls & 0xffff) << 16) | ((uint64_t)getpid() << 32);
    }
    if (statusToken >= 0 && notify_set_state(statusToken, state) != NOTIFY_STATUS_OK)
        PCLog("stage=error operation=publish-status");
}

static NSDictionary *CopyModeLimits(CommonProduct *product, NSUInteger mode) {
    if (mode <= 1) return @{};
    // Resolve type and offset from this runtime. Never write to the ivar.
    Ivar ivar = class_getInstanceVariable(object_getClass(product), "simulatedThermalMitigationLimits");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!type || type[0] != '@') return nil;
    id configuration = object_getIvar(product, ivar);
    if (![configuration isKindOfClass:[NSDictionary class]]) return nil;
    id limits = configuration[@(PCModeName(mode))];
    if (![limits isKindOfClass:[NSDictionary class]] || [limits count] == 0) return nil;
    NSMutableDictionary *validated = [NSMutableDictionary dictionary];
    for (id key in limits) {
        id value = limits[key];
        if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSNumber class]]) return nil;
        double number = [value doubleValue];
        // Device D79AP configuration uses 101 as the unrestricted sentinel.
        if (!isfinite(number) || number < 0 || number > 101 || floor(number) != number) return nil;
        if (number <= 100) validated[key] = value;
    }
    return [validated copy];
}

static void SelectMode(NSUInteger mode) {
    CommonProduct *product = currentProduct;
    NSDictionary *limits = product ? CopyModeLimits(product, mode) : nil;
    NSMutableArray *matched = [NSMutableArray array];
    NSMutableArray *available = [NSMutableArray array];
    if (product && mode > 1 && limits && MethodMatches(object_getClass(product), @selector(listofComponentControl), "@", @[])) {
        id components = [product listofComponentControl];
        if ([components isKindOfClass:[NSArray class]]) {
            for (id component in components) {
                if (![component isKindOfClass:NSClassFromString(@"ComponentControl")]) continue;
                NSString *name = (__bridge NSString *)[component nameofComponent];
                NSString *key = KeyForComponent(component);
                [available addObject:@{ @"name": name ?: @"(null)", @"class": NSStringFromClass(object_getClass(component)), @"type": @([component mitigationType]), @"key": key ?: @"native-only" }];
                if (key && limits[key] && [limits[key] unsignedIntValue] < 100)
                    [matched addObject:key];
            }
        }
    }
    // A configuration alone is insufficient: require a live, restrictive match.
    BOOL canApply = hookReady && product && limits && (mode <= 1 || matched.count > 0);
    @synchronized (stateLock) {
        requestedMode = mode;
        supported = canApply;
        rejected = !canApply && mode != 0;
        activeMode = canApply ? mode : 0;
        activeLimits = canApply ? limits : @{};
        clampCalls = 0;
        setterAccepted = NO;
        stateTransition = NO;
    }
    PCLog("stage=selection requested=%{public}s active=%{public}s supported=%d matched=%{public}@ limits=%{public}@",
          PCModeName(mode), PCModeName(canApply ? mode : 0), canApply, matched, canApply ? limits : @{});
    PCLog("stage=component-map available=%{public}@ configured=%{public}@", available, limits ?: @{});
    if (!canApply && mode != 0)
        PCLog("stage=unsupported reason=missing-product-configuration-or-component-match requested=%{public}s", PCModeName(mode));
    if (mode == 1) PCLog("stage=limitation mode=nominal effect=no-additional-cap; performance-difference-not-expected");
    PublishStatus();
    WriteDiagnostics(@"thermalmonitord");
}

static void ReceiveSelection(void) {
    uint64_t mode = 0;
    uint32_t result = notify_get_state(modeToken, &mode);
    if (result != NOTIFY_STATUS_OK || !PCValidMode(mode)) {
        PCLog("stage=error operation=read-selection result=%u value=%llu", result, (unsigned long long)mode);
        SelectMode(0);
        return;
    }
    receivedSelection = YES;
    if (!restoreLatch) SelectMode((NSUInteger)mode);
}

static void CaptureProduct(CommonProduct *product) {
    // Let the complete initializer finish before reading configuration.
    dispatch_async(dispatch_get_main_queue(), ^{
        currentProduct = product;
        productSeen = YES;
        PCLog("stage=product initialized=1 class=%{public}@", NSStringFromClass(object_getClass(product)));
        (void)MethodMatches(object_getClass(product), NSSelectorFromString(@"putDeviceInThermalSimulationMode:"), "v", @[@"@"]);
        PCLog("stage=backend name=additive-loading-index; forced-simulation-api-not-invoked");
        if (receivedSelection && !restoreLatch) ReceiveSelection();
        else SelectMode(0);
    });
}

%group ProductHooks
%hook CommonProduct
- (id)initProduct:(id)data {
    self = %orig(data);
    if (self) CaptureProduct(self);
    return self;
}
%end
%end

%group ComponentHooks
%hook ComponentControl
- (void)setMaxLoadingIndex:(unsigned int)index releaseIndex:(unsigned int)release {
    NSNumber *cap;
    NSUInteger mode;
    NSString *name = (__bridge NSString *)[self nameofComponent];
    NSString *key = KeyForComponent(self);
    @synchronized (stateLock) {
        cap = key && currentProduct ? activeLimits[key] : nil;
        mode = activeMode;
    }
    unsigned int output = cap ? PCClampIndex(index, cap.unsignedIntValue) : index;
    unsigned int outputRelease = cap ? PCClampIndex(release, cap.unsignedIntValue) : release;
    BOOL changedInput = output != index || outputRelease != release;
    unsigned int before = changedInput ? [self maxLoadingIndex] : 0;
    int beforeRelease = changedInput ? [self getReleaseMaxLI] : 0;
    %orig(output, outputRelease); // Always forward, on Apple's caller thread.
    if (changedInput) {
        unsigned int after = [self maxLoadingIndex];
        int afterRelease = [self getReleaseMaxLI];
        BOOL accepted = after == output && afterRelease >= 0 && (unsigned int)afterRelease == outputRelease;
        BOOL transitioned = accepted && (before != after || beforeRelease != afterRelease);
        @synchronized (stateLock) {
            clampCalls++;
            setterAccepted |= accepted;
            stateTransition |= transitioned;
        }
        NSString *signature = [NSString stringWithFormat:@"%lu:%u:%u:%u:%u", (unsigned long)mode, index, release, output, outputRelease];
        if (![objc_getAssociatedObject(self, lastClampKey) isEqual:signature]) {
            objc_setAssociatedObject(self, lastClampKey, signature, OBJC_ASSOCIATION_COPY_NONATOMIC);
            PCLog("stage=clamp-forwarded component=%{public}@ mode=%{public}s apple=%u/%u forwarded=%u/%u performance_effect=unmeasured",
                  name, PCModeName(mode), index, release, output, outputRelease);
            PCLog("stage=native-readback component=%{public}@ before=%u/%d after=%u/%d setter_accepted=%d state_transition=%d hardware_effect=unverified",
                  name, before, beforeRelease, after, afterRelease, accepted, transitioned);
        }
    }
}
%end
%end

static void PublishSettings(void) {
    CFPreferencesAppSynchronize(CFSTR(PC_PREFS));
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PowerMode"), CFSTR(PC_PREFS)));
    id requireLPM = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("RequireLowPowerMode"), CFSTR(PC_PREFS)));
    NSUInteger mode = [value isKindOfClass:[NSNumber class]] && PCValidMode([value unsignedLongLongValue]) ? [value unsignedIntegerValue] : 0;
    BOOL lowPower = NSProcessInfo.processInfo.lowPowerModeEnabled;
    BOOL gated = [requireLPM isKindOfClass:[NSNumber class]] && [requireLPM boolValue];
    NSUInteger effective = gated && !lowPower ? 0 : mode;
    uint32_t result = notify_set_state(modeToken, effective);
    if (result == NOTIFY_STATUS_OK) result = notify_post(PC_MODE);
    PCLog("stage=settings requested=%{public}s effective=%{public}s require_lpm=%d lpm=%d notification_result=%u",
          PCModeName(mode), PCModeName(effective), gated, lowPower, result);
    WriteDiagnostics(@"SpringBoard");
}

static BOOL RegisterCheck(const char *name, int *token) {
    uint32_t result = notify_register_check(name, token);
    if (result != NOTIFY_STATUS_OK) {
        *token = -1;
        PCLog("stage=error operation=register-check name=%{public}s result=%u", name, result);
    }
    return result == NOTIFY_STATUS_OK;
}

%ctor {
    @autoreleasepool {
        logger = os_log_create("com.rpetrich.powercuff", "diagnostics");
        stateLock = [NSObject new];
        activeLimits = @{};
        NSString *process = NSProcessInfo.processInfo.processName;
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        PCLog("stage=injection process=%{public}@ os=%ld.%ld.%ld pid=%d", process,
              (long)version.majorVersion, (long)version.minorVersion, (long)version.patchVersion, getpid());
        char model[64] = {0}, build[64] = {0};
        size_t modelSize = sizeof(model), buildSize = sizeof(build);
        BOOL target = sysctlbyname("hw.machine", model, &modelSize, NULL, 0) == 0 &&
            sysctlbyname("kern.osversion", build, &buildSize, NULL, 0) == 0 &&
            strcmp(model, "iPhone12,8") == 0 && strcmp(build, "20B101") == 0;
        if (version.majorVersion != 16 || !target) {
            PCLog("stage=unsupported reason=unverified-device-build model=%{public}s build=%{public}s", model, build);
            return;
        }
        if ([process isEqualToString:@"SpringBoard"]) {
            if (!RegisterCheck(PC_MODE, &modeToken)) return;
            uint32_t result = notify_register_dispatch(PC_SETTINGS, &settingsToken, dispatch_get_main_queue(), ^(int token) {
                PublishSettings();
            });
            if (result != NOTIFY_STATUS_OK) { PCLog("stage=error operation=register-settings result=%u", result); return; }
            // Replace _batterySaverModeChanged: and _CDBatterySaver with public APIs.
            [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { PublishSettings(); }];
            PublishSettings();
            PCLog("stage=lpm-observer installed=1");
        } else if ([process isEqualToString:@"thermalmonitord"]) {
            if (!RegisterCheck(PC_STATUS, &statusToken) || !RegisterCheck(PC_RESPONSE, &responseToken)) return;
            Class product = NSClassFromString(@"CommonProduct");
            Class component = NSClassFromString(@"ComponentControl");
            if (!MethodMatches(product, @selector(initProduct:), "@", @[@"@"]) ||
                !MethodMatches(component, @selector(nameofComponent), @encode(CFStringRef), @[]) ||
                !MethodMatches(component, @selector(mitigationType), "i", @[]) ||
                !MethodMatches(component, @selector(maxLoadingIndex), "I", @[]) ||
                !MethodMatches(component, @selector(getReleaseMaxLI), "i", @[]) ||
                !MethodMatches(component, @selector(setMaxLoadingIndex:releaseIndex:), "v", @[@"I", @"I"])) {
                PCLog("stage=unsupported reason=private-abi; no-hooks-installed");
            } else {
                IMP beforeProduct = class_getMethodImplementation(product, @selector(initProduct:));
                IMP beforeComponent = class_getMethodImplementation(component, @selector(setMaxLoadingIndex:releaseIndex:));
                %init(ProductHooks);
                %init(ComponentHooks);
                hookReady = beforeProduct != class_getMethodImplementation(product, @selector(initProduct:)) &&
                    beforeComponent != class_getMethodImplementation(component, @selector(setMaxLoadingIndex:releaseIndex:));
                PCLog("stage=hooks installed=%d", hookReady);
            }
            uint32_t result = notify_register_dispatch(PC_MODE, &modeToken, dispatch_get_main_queue(), ^(int token) { ReceiveSelection(); });
            if (result != NOTIFY_STATUS_OK) PCLog("stage=error operation=register-mode result=%u", result);
            result = notify_register_dispatch(PC_RESTORE, &restoreToken, dispatch_get_main_queue(), ^(int token) {
                restoreLatch = YES;
                SelectMode(0);
                PCLog("stage=restore latched=1 restart-daemon-to-reenable");
            });
            if (result != NOTIFY_STATUS_OK) PCLog("stage=error operation=register-restore result=%u", result);
            result = notify_register_dispatch(PC_DIAGNOSTICS, &diagnosticToken, dispatch_get_main_queue(), ^(int token) {
                uint64_t nonce = 0;
                PublishStatus();
                PCLog("stage=observation thermal_state=%ld performance_effect=unmeasured restoration_requires-native-control-loop",
                      (long)NSProcessInfo.processInfo.thermalState);
                WriteDiagnostics(@"thermalmonitord");
                if (notify_get_state(token, &nonce) == NOTIFY_STATUS_OK && notify_set_state(responseToken, nonce) == NOTIFY_STATUS_OK) notify_post(PC_RESPONSE);
            });
            if (result != NOTIFY_STATUS_OK) PCLog("stage=error operation=register-diagnostics result=%u", result);
            PublishStatus();
            notify_post(PC_SETTINGS); // Ask for fresh state after daemon startup.
        }
    }
}
