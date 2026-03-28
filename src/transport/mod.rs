use std::time::Duration;

use async_trait::async_trait;
use uuid::Uuid;

use crate::error::Result;

pub mod ble;

/// Async device I/O surface used by the protocol-specific backends.
#[async_trait]
pub trait DeviceTransport: Send + Sync {
    /// Sends a request through a request/response transport and optionally waits for a response.
    async fn exchange(
        &self,
        payload: &[u8],
        expect_response: bool,
        timeout: Duration,
    ) -> Result<Option<Vec<u8>>>;

    /// Reads raw bytes from a specific characteristic.
    async fn read(&self, characteristic: Uuid, timeout: Duration) -> Result<Vec<u8>>;

    /// Writes raw bytes to a specific characteristic.
    async fn write(&self, characteristic: Uuid, payload: &[u8], response: bool) -> Result<()>;

    /// Closes the underlying device connection.
    async fn disconnect(&self) -> Result<()>;
}
