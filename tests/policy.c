#include "../PowercuffPolicy.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
int main(void) {
    // Exhaust all valid native index/cap pairs: additional caps can never relax
    // an Apple restriction. Off/nominal identity caps never change [0,100].
    for (unsigned int native = 0; native <= 100; native++) {
        for (unsigned int cap = 0; cap <= 100; cap++) {
            unsigned int output = PCClampIndex(native, cap);
            assert(output <= native && output <= cap);
            assert(PCClampIndex(output, cap) == output);
        }
        assert(PCClampIndex(native, 100) == native);
    }
    assert(PCClampIndex(UINT_MAX, 0) == 0);
    assert(PCClampIndex(0, UINT_MAX) == 0);
    assert(!PCValidMode(UINT64_MAX) && !PCValidMode(5));
    for (uint64_t mode = 0; mode <= 4; mode++) assert(PCValidMode(mode));
    puts("PASS: all 10,201 valid index/cap pairs preserve stronger Apple restrictions");
    return 0;
}
