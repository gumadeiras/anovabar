use std::time::Duration;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("no Bluetooth adapters were found")]
    NoBluetoothAdapters,
    #[error("no matching BLE device was found")]
    DeviceNotFound,
    #[error("missing BLE characteristic: {0}")]
    MissingCharacteristic(&'static str),
    #[error("notification stream closed unexpectedly")]
    NotificationStreamClosed,
    #[error("command timed out after {0:?}")]
    Timeout(Duration),
    #[error("operation is not supported by this transport/profile: {0}")]
    UnsupportedOperation(&'static str),
    #[error("invalid frame data")]
    InvalidFrame,
    #[error("unsupported temperature unit value: {0}")]
    UnsupportedTemperatureUnit(i32),
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("missing sensor value: {0}")]
    MissingSensor(&'static str),
    #[error("device did not confirm the expected state: {0}")]
    StateUnconfirmed(String),
    #[error("base64 decode error: {0}")]
    Base64Decode(#[from] base64::DecodeError),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("BLE error: {0}")]
    Ble(#[from] btleplug::Error),
    #[error("protobuf decode error: {0}")]
    Decode(#[from] prost::DecodeError),
}

pub type Result<T> = std::result::Result<T, Error>;
