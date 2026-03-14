/**
 * @file test_mylib.c
 * @brief Minimal test harness for mylib.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mylib/mylib.h"

static int tests_run = 0;
static int tests_failed = 0;

#define ASSERT_EQ(actual, expected, msg) \
    do { \
        tests_run++; \
        if ((actual) != (expected)) { \
            fprintf(stderr, "FAIL: %s (got %d, expected %d)\n", \
                    (msg), (actual), (expected)); \
            tests_failed++; \
        } \
    } while (0)

#define ASSERT_STR_EQ(actual, expected, msg) \
    do { \
        tests_run++; \
        if (strcmp((actual), (expected)) != 0) { \
            fprintf(stderr, "FAIL: %s (got \"%s\", expected \"%s\")\n", \
                    (msg), (actual), (expected)); \
            tests_failed++; \
        } \
    } while (0)

static void test_add(void) {
    ASSERT_EQ(mylib_add(2, 3), 5, "add(2, 3)");
    ASSERT_EQ(mylib_add(-1, 1), 0, "add(-1, 1)");
    ASSERT_EQ(mylib_add(0, 0), 0, "add(0, 0)");
}

static void test_clamp(void) {
    ASSERT_EQ(mylib_clamp(5, 0, 10), 5, "clamp(5, 0, 10)");
    ASSERT_EQ(mylib_clamp(-5, 0, 10), 0, "clamp(-5, 0, 10)");
    ASSERT_EQ(mylib_clamp(15, 0, 10), 10, "clamp(15, 0, 10)");
    ASSERT_EQ(mylib_clamp(0, 0, 10), 0, "clamp(0, 0, 10)");
    ASSERT_EQ(mylib_clamp(10, 0, 10), 10, "clamp(10, 0, 10)");
}

static void test_version(void) {
    ASSERT_STR_EQ(mylib_version(), "0.1.0", "version()");
}

int main(void) {
    test_add();
    test_clamp();
    test_version();

    printf("%d/%d tests passed\n", tests_run - tests_failed, tests_run);

    return tests_failed > 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}
