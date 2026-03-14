//! Integration tests for mylib.

use mylib::{add, greet, MyLibError};

#[test]
fn test_add_basic() {
    assert_eq!(add(10, 20), 30);
}

#[test]
fn test_greet_default() {
    let result = greet("Rust", None).unwrap();
    assert_eq!(result, "Hello, Rust!");
}

#[test]
fn test_greet_custom() {
    let result = greet("Rust", Some("Hey")).unwrap();
    assert_eq!(result, "Hey, Rust!");
}

#[test]
fn test_greet_empty_name_error() {
    let result = greet("", None);
    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(matches!(err, MyLibError::EmptyName));
    assert_eq!(err.to_string(), "name must not be empty");
}
