package mylib

import (
	"errors"
	"testing"
)

func TestAdd(t *testing.T) {
	tests := []struct {
		name string
		a, b int
		want int
	}{
		{"positive", 2, 3, 5},
		{"negative", -1, 1, 0},
		{"zeros", 0, 0, 0},
		{"large", 1000000, 2000000, 3000000},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Add(tt.a, tt.b)
			if got != tt.want {
				t.Errorf("Add(%d, %d) = %d, want %d", tt.a, tt.b, got, tt.want)
			}
		})
	}
}

func TestGreet(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		greeting []string
		want     string
		wantErr  error
	}{
		{"default greeting", "World", nil, "Hello, World!", nil},
		{"custom greeting", "World", []string{"Hi"}, "Hi, World!", nil},
		{"empty name", "", nil, "", ErrEmptyName},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Greet(tt.input, tt.greeting...)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("Greet(%q) error = %v, want %v", tt.input, err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Greet(%q) unexpected error: %v", tt.input, err)
			}
			if got != tt.want {
				t.Errorf("Greet(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestClamp(t *testing.T) {
	tests := []struct {
		name            string
		value, min, max int
		want            int
	}{
		{"within range", 5, 0, 10, 5},
		{"below min", -5, 0, 10, 0},
		{"above max", 15, 0, 10, 10},
		{"at min", 0, 0, 10, 0},
		{"at max", 10, 0, 10, 10},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Clamp(tt.value, tt.min, tt.max)
			if got != tt.want {
				t.Errorf("Clamp(%d, %d, %d) = %d, want %d", tt.value, tt.min, tt.max, got, tt.want)
			}
		})
	}
}
