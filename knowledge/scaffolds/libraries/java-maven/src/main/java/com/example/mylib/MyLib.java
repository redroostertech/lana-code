package com.example.mylib;

/**
 * MyLib provides reusable utility methods.
 */
public final class MyLib {

    private MyLib() {
        // Utility class — no instantiation
    }

    /**
     * Add two integers together.
     *
     * @param a first number
     * @param b second number
     * @return the sum of a and b
     */
    public static int add(int a, int b) {
        return a + b;
    }

    /**
     * Generate a greeting string with the default greeting "Hello".
     *
     * @param name the name to greet
     * @return the greeting string
     * @throws IllegalArgumentException if name is null or empty
     */
    public static String greet(String name) {
        return greet(name, "Hello");
    }

    /**
     * Generate a greeting string with a custom greeting.
     *
     * @param name     the name to greet
     * @param greeting the greeting prefix
     * @return the greeting string
     * @throws IllegalArgumentException if name is null or empty
     */
    public static String greet(String name, String greeting) {
        if (name == null || name.isEmpty()) {
            throw new IllegalArgumentException("name must not be empty");
        }
        return greeting + ", " + name + "!";
    }

    /**
     * Clamp a value to lie within [min, max].
     *
     * @param value the value to clamp
     * @param min   the minimum bound
     * @param max   the maximum bound
     * @return the clamped value
     */
    public static int clamp(int value, int min, int max) {
        return Math.max(min, Math.min(max, value));
    }
}
