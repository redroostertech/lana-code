//! Error types for mylib.

use thiserror::Error;

/// Errors that can occur in mylib operations.
#[derive(Debug, Error)]
pub enum MyLibError {
    /// The provided name was empty.
    #[error("name must not be empty")]
    EmptyName,

    /// An I/O error occurred.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// A custom error with a message.
    #[error("{0}")]
    Custom(String),
}
