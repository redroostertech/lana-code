// Package mylib provides reusable utility functions.
package mylib

import (
	"errors"
	"fmt"
)

// ErrEmptyName is returned when an empty name is passed to Greet.
var ErrEmptyName = errors.New("name must not be empty")

// Add returns the sum of two integers.
func Add(a, b int) int {
	return a + b
}

// Greet produces a greeting string for the given name.
// It returns ErrEmptyName if name is empty.
// An optional greeting prefix can be provided; it defaults to "Hello".
func Greet(name string, greeting ...string) (string, error) {
	if name == "" {
		return "", ErrEmptyName
	}
	g := "Hello"
	if len(greeting) > 0 && greeting[0] != "" {
		g = greeting[0]
	}
	return fmt.Sprintf("%s, %s!", g, name), nil
}

// Clamp restricts a value to lie within [min, max].
func Clamp(value, min, max int) int {
	if value < min {
		return min
	}
	if value > max {
		return max
	}
	return value
}
