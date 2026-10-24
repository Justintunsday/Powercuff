#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

__attribute__((noinline)) static uint64_t CPUBlock(uint64_t value, unsigned int rounds) {
    for (unsigned int i = 0; i < rounds; i++) {
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
    }
    return value;
}

int PCBenchmark(const char *kind, NSUInteger seconds) {
    if (seconds < 2 || seconds > 30) { fputs("Duration must be 2 to 30 seconds.\n", stderr); return 1; }
    NSInteger thermalBefore = NSProcessInfo.processInfo.thermalState;
    double started, elapsed, gpuSeconds = 0;
    uint64_t units = 0, checksum = 1;
    NSString *name;
    if (strcmp(kind, "cpu") == 0) {
        name = @"powercuff-xorshift64-v1";
        const unsigned int rounds = 1 << 20;
        checksum = CPUBlock(checksum, rounds); // Warm up outside the timed interval.
        started = NSProcessInfo.processInfo.systemUptime;
        do {
            checksum = CPUBlock(checksum, rounds);
            units += rounds;
            elapsed = NSProcessInfo.processInfo.systemUptime - started;
        } while (elapsed < seconds);
    } else if (strcmp(kind, "gpu") == 0) {
        name = @"metal-xorshift32-v1";
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fputs("Metal device unavailable.\n", stderr); return 2; }
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void work(device uint *data [[buffer(0)]], constant uint &rounds [[buffer(1)]], uint id [[thread_position_in_grid]]) {"
            "uint x=data[id]; for(uint i=0;i<rounds;i++){x^=x<<13;x^=x>>17;x^=x<<5;} data[id]=x;}";
        NSError *error = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion2_4;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"work"];
        id<MTLComputePipelineState> pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!pipeline) { fprintf(stderr, "Metal compilation failed: %s\n", error.description.UTF8String); return 2; }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        const NSUInteger count = 65536;
        const uint32_t rounds = 2048;
        id<MTLBuffer> buffer = [device newBufferWithLength:count * sizeof(uint32_t) options:MTLResourceStorageModeShared];
        if (!queue || !buffer) { fputs("Metal allocation failed.\n", stderr); return 2; }
        uint32_t *words = buffer.contents;
        for (NSUInteger i = 0; i < count; i++) words[i] = (uint32_t)i + 1;
        NSUInteger groupWidth = MIN((NSUInteger)256, pipeline.maxTotalThreadsPerThreadgroup);
        BOOL warmup = YES;
        started = NSProcessInfo.processInfo.systemUptime;
        do {
            @autoreleasepool {
                id<MTLCommandBuffer> command = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                if (!command || !encoder) { fputs("Metal command unavailable.\n", stderr); return 2; }
                [encoder setComputePipelineState:pipeline];
                [encoder setBuffer:buffer offset:0 atIndex:0];
                [encoder setBytes:&rounds length:sizeof(rounds) atIndex:1];
                [encoder dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
                [encoder endEncoding];
                [command commit];
                [command waitUntilCompleted];
                if (command.status != MTLCommandBufferStatusCompleted) {
                    fprintf(stderr, "GPU command failed: %s\n", command.error.description.UTF8String); return 2;
                }
                if (warmup) {
                    started = NSProcessInfo.processInfo.systemUptime;
                    warmup = NO;
                } else {
                    units += (uint64_t)count * rounds;
                    gpuSeconds += command.GPUEndTime - command.GPUStartTime;
                }
                elapsed = NSProcessInfo.processInfo.systemUptime - started;
            }
        } while (elapsed < seconds);
        for (NSUInteger i = 0; i < count; i++) checksum += words[i];
    } else { fputs("Benchmark must be cpu or gpu.\n", stderr); return 1; }
    NSDictionary *result = @{ @"benchmark": name, @"iterations": @(units), @"elapsed_seconds": @(elapsed),
        @"iterations_per_second": @(units / elapsed), @"checksum": @(checksum), @"gpu_seconds": @(gpuSeconds),
        @"thermal_before": @(thermalBefore), @"thermal_after": @(NSProcessInfo.processInfo.thermalState),
        @"low_power_mode": @(NSProcessInfo.processInfo.lowPowerModeEnabled),
        @"power_watts": [NSNull null], @"energy_joules": [NSNull null] };
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return 0;
}
