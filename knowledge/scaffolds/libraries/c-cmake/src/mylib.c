/**
 * @file mylib.c
 * @brief Implementation of mylib public API.
 */

#include "mylib/mylib.h"

int mylib_add(int a, int b) {
    return a + b;
}

int mylib_clamp(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

const char *mylib_version(void) {
    return "0.1.0";
}
