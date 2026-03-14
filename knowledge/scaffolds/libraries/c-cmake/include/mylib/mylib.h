/**
 * @file mylib.h
 * @brief Public API for mylib.
 */

#ifndef MYLIB_H
#define MYLIB_H

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Add two integers together.
 *
 * @param a First number.
 * @param b Second number.
 * @return The sum of a and b.
 */
int mylib_add(int a, int b);

/**
 * @brief Clamp a value to lie within [min, max].
 *
 * @param value The value to clamp.
 * @param min   The minimum bound.
 * @param max   The maximum bound.
 * @return The clamped value.
 */
int mylib_clamp(int value, int min, int max);

/**
 * @brief Get the library version string.
 *
 * @return A null-terminated version string (e.g., "0.1.0").
 */
const char *mylib_version(void);

#ifdef __cplusplus
}
#endif

#endif /* MYLIB_H */
