"""Tests for mylib.core."""

import pytest
from mylib.core import add, greet


class TestAdd:
    def test_integers(self):
        assert add(2, 3) == 5

    def test_floats(self):
        assert add(1.5, 2.5) == 4.0

    def test_negative(self):
        assert add(-1, 1) == 0

    def test_zero(self):
        assert add(0, 0) == 0


class TestGreet:
    def test_default_greeting(self):
        assert greet("World") == "Hello, World!"

    def test_custom_greeting(self):
        assert greet("World", greeting="Hi") == "Hi, World!"

    def test_empty_name(self):
        assert greet("") == "Hello, !"
