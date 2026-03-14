package com.example.mylib;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.junit.jupiter.api.Assertions.*;

class MyLibTest {

    @ParameterizedTest
    @CsvSource({
        "2, 3, 5",
        "-1, 1, 0",
        "0, 0, 0",
        "100, 200, 300"
    })
    void testAdd(int a, int b, int expected) {
        assertEquals(expected, MyLib.add(a, b));
    }

    @Test
    void testGreetDefault() {
        assertEquals("Hello, World!", MyLib.greet("World"));
    }

    @Test
    void testGreetCustom() {
        assertEquals("Hi, World!", MyLib.greet("World", "Hi"));
    }

    @Test
    void testGreetEmptyNameThrows() {
        assertThrows(IllegalArgumentException.class, () -> MyLib.greet(""));
    }

    @Test
    void testGreetNullNameThrows() {
        assertThrows(IllegalArgumentException.class, () -> MyLib.greet(null));
    }

    @ParameterizedTest
    @CsvSource({
        "5, 0, 10, 5",
        "-5, 0, 10, 0",
        "15, 0, 10, 10",
        "0, 0, 10, 0",
        "10, 0, 10, 10"
    })
    void testClamp(int value, int min, int max, int expected) {
        assertEquals(expected, MyLib.clamp(value, min, max));
    }
}
