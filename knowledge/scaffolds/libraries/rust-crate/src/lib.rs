//! mylib - A reusable Rust library.
//!
//! # Examples
//!
//! ```
//! use mylib::add;
//! assert_eq!(add(2, 3), 5);
//! ```

pub mod error;

pub use error::MyLibError;

/// Add two numbers together.
///
/// # Examples
///
/// ```
/// assert_eq!(mylib::add(2, 3), 5);
/// ```
pub fn add(a: i64, b: i64) -> i64 {
    a + b
}

/// Generate a greeting string.
///
/// # Errors
///
/// Returns [`MyLibError::EmptyName`] if `name` is empty.
///
/// # Examples
///
/// ```
/// let msg = mylib::greet("World", None).unwrap();
/// assert_eq!(msg, "Hello, World!");
/// ```
pub fn greet(name: &str, greeting: Option<&str>) -> Result<String, MyLibError> {
    if name.is_empty() {
        return Err(MyLibError::EmptyName);
    }
    let greeting = greeting.unwrap_or("Hello");
    Ok(format!("{greeting}, {name}!"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(add(2, 3), 5);
        assert_eq!(add(-1, 1), 0);
        assert_eq!(add(0, 0), 0);
    }

    #[test]
    fn test_greet() {
        assert_eq!(greet("World", None).unwrap(), "Hello, World!");
        assert_eq!(greet("World", Some("Hi")).unwrap(), "Hi, World!");
    }

    #[test]
    fn test_greet_empty_name() {
        assert!(greet("", None).is_err());
    }
}
