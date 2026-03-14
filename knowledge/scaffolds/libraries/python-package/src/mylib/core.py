"""Core library functionality."""

from __future__ import annotations


def add(a: int | float, b: int | float) -> int | float:
    """Add two numbers together.

    Args:
        a: First number.
        b: Second number.

    Returns:
        The sum of a and b.
    """
    return a + b


def greet(name: str, greeting: str = "Hello") -> str:
    """Generate a greeting string.

    Args:
        name: The name to greet.
        greeting: The greeting prefix. Defaults to "Hello".

    Returns:
        A formatted greeting string.
    """
    return f"{greeting}, {name}!"
