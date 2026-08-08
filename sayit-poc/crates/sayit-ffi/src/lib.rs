#![allow(unexpected_cfgs)]

//! SayIt FFI Bridge for Flutter.

mod frb_generated;

use flutter_rust_bridge::frb;

#[derive(Debug, Clone)]
pub struct SimpleResult {
    pub audio: Vec<u8>,
    pub sample_rate: u32,
    pub channels: u16,
    pub format: String,
}

#[frb(sync)]
pub fn test_hello() -> String {
    "Hello from SayIt FFI".to_string()
}

#[frb(sync)]
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}
