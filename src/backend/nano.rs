use std::time::Duration;

use uuid::Uuid;

use crate::error::Result;
use crate::protocol::{
    NanoCommand, decode_device_info, decode_firmware_info, decode_frame, decode_integer_value,
    decode_sensor_snapshot, decode_unit,
};
use crate::transport::DeviceTransport;
use crate::transport::ble::{BleProfile, BleTransport, DiscoveredDevice};
use crate::types::{DeviceInfo, DeviceStatus, FirmwareInfo, SensorSnapshot, TemperatureUnit};

const DEFAULT_SCAN_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const NANO_SERVICE_UUID: Uuid = Uuid::from_u128(0x0e1400000af14582a242773e63054c68);
const NANO_WRITE_CHARACTERISTIC_UUID: Uuid = Uuid::from_u128(0x0e1400010af14582a242773e63054c68);
const NANO_READ_CHARACTERISTIC_UUID: Uuid = Uuid::from_u128(0x0e1400020af14582a242773e63054c68);

/// Common BLE connection settings for Anova BLE devices.
#[derive(Clone, Debug)]
pub struct BleConnectOptions {
    pub address: Option<String>,
    pub scan_timeout: Duration,
    pub command_timeout: Duration,
}

impl Default for BleConnectOptions {
    fn default() -> Self {
        Self {
            address: None,
            scan_timeout: DEFAULT_SCAN_TIMEOUT,
            command_timeout: DEFAULT_COMMAND_TIMEOUT,
        }
    }
}

/// High-level backend for Anova Nano BLE devices.
#[derive(Debug)]
pub struct AnovaNano<T = BleTransport<NanoBleProfile>> {
    transport: T,
    command_timeout: Duration,
}

impl AnovaNano<BleTransport<NanoBleProfile>> {
    pub async fn discover(scan_timeout: Duration) -> Result<Vec<DiscoveredDevice>> {
        BleTransport::<NanoBleProfile>::discover(scan_timeout).await
    }

    pub async fn connect(options: BleConnectOptions) -> Result<Self> {
        let transport = BleTransport::<NanoBleProfile>::connect(
            options.address.as_deref(),
            options.scan_timeout,
        )
        .await?;
        Ok(Self::new(transport, options.command_timeout))
    }
}

impl<T> AnovaNano<T>
where
    T: DeviceTransport,
{
    pub fn new(transport: T, command_timeout: Duration) -> Self {
        Self {
            transport,
            command_timeout,
        }
    }

    pub async fn disconnect(&self) -> Result<()> {
        self.transport.disconnect().await
    }

    pub async fn get_sensor_snapshot(&self) -> Result<SensorSnapshot> {
        let payload = self.request(NanoCommand::GetSensorValues).await?;
        decode_sensor_snapshot(&payload)
    }

    pub async fn get_status(&self) -> Result<DeviceStatus> {
        Ok(self.get_sensor_snapshot().await?.status())
    }

    pub async fn get_current_temperature(&self) -> Result<f32> {
        Ok(self.get_sensor_snapshot().await?.water_temp.value)
    }

    pub async fn get_target_temperature(&self) -> Result<f32> {
        let payload = self.request(NanoCommand::GetTargetTemperature).await?;
        Ok(decode_integer_value(&payload)? as f32 / 10.0)
    }

    pub async fn get_timer_minutes(&self) -> Result<i32> {
        let payload = self.request(NanoCommand::GetTimer).await?;
        decode_integer_value(&payload)
    }

    pub async fn get_unit(&self) -> Result<TemperatureUnit> {
        let payload = self.request(NanoCommand::GetUnit).await?;
        decode_unit(&payload)
    }

    pub async fn get_firmware_info(&self) -> Result<FirmwareInfo> {
        let payload = self.request(NanoCommand::GetFirmwareInfo).await?;
        decode_firmware_info(&payload)
    }

    pub async fn get_device_info(&self) -> Result<DeviceInfo> {
        let payload = self.request(NanoCommand::GetDeviceInfo).await?;
        decode_device_info(&payload)
    }

    pub async fn start(&self) -> Result<()> {
        self.send(NanoCommand::Start).await
    }

    pub async fn stop(&self) -> Result<()> {
        self.send(NanoCommand::Stop).await
    }

    pub async fn set_unit(&self, unit: TemperatureUnit) -> Result<()> {
        self.send(NanoCommand::SetUnit(unit)).await
    }

    pub async fn set_target_temperature(&self, temperature: f32) -> Result<()> {
        self.send(NanoCommand::SetTargetTemperature(temperature))
            .await
    }

    pub async fn set_timer_minutes(&self, minutes: u32) -> Result<()> {
        self.send(NanoCommand::SetTimer(minutes)).await
    }

    async fn request(&self, command: NanoCommand) -> Result<Vec<u8>> {
        let expect_response = command.expects_response();
        let payload = command.encode();
        let response = self
            .transport
            .exchange(&payload, expect_response, self.command_timeout)
            .await?;

        Ok(response.unwrap_or_default())
    }

    async fn send(&self, command: NanoCommand) -> Result<()> {
        let _ = self.request(command).await?;
        Ok(())
    }
}

/// BLE profile for the Anova Nano protocol surface.
#[derive(Debug)]
pub struct NanoBleProfile;

impl BleProfile for NanoBleProfile {
    fn service_uuid() -> Uuid {
        NANO_SERVICE_UUID
    }

    fn exchange_write_characteristic_uuid() -> Option<Uuid> {
        Some(NANO_WRITE_CHARACTERISTIC_UUID)
    }

    fn notification_characteristic_uuid() -> Option<Uuid> {
        Some(NANO_READ_CHARACTERISTIC_UUID)
    }

    fn decode_response(raw: &[u8], _latest_chunk: &[u8]) -> Option<Vec<u8>> {
        decode_frame(raw)
    }

    fn required_characteristic_uuids() -> Vec<Uuid> {
        vec![
            NANO_WRITE_CHARACTERISTIC_UUID,
            NANO_READ_CHARACTERISTIC_UUID,
        ]
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Arc;
    use std::time::Duration;

    use async_trait::async_trait;
    use tokio::sync::Mutex;
    use uuid::Uuid;

    use super::AnovaNano;
    use crate::error::Result;
    use crate::transport::DeviceTransport;
    use crate::types::{DeviceStatus, TemperatureUnit};

    #[derive(Debug, Default)]
    struct MockTransport {
        writes: Mutex<Vec<Vec<u8>>>,
        responses: Mutex<VecDeque<Option<Vec<u8>>>>,
    }

    impl MockTransport {
        fn with_responses(responses: impl IntoIterator<Item = Option<Vec<u8>>>) -> Arc<Self> {
            Arc::new(Self {
                writes: Mutex::new(Vec::new()),
                responses: Mutex::new(responses.into_iter().collect()),
            })
        }
    }

    #[async_trait]
    impl DeviceTransport for Arc<MockTransport> {
        async fn exchange(
            &self,
            payload: &[u8],
            _expect_response: bool,
            _timeout: Duration,
        ) -> Result<Option<Vec<u8>>> {
            self.writes.lock().await.push(payload.to_vec());
            Ok(self.responses.lock().await.pop_front().flatten())
        }

        async fn read(&self, _characteristic: Uuid, _timeout: Duration) -> Result<Vec<u8>> {
            unreachable!("nano tests use exchange only")
        }

        async fn write(
            &self,
            _characteristic: Uuid,
            _payload: &[u8],
            _response: bool,
        ) -> Result<()> {
            unreachable!("nano tests use exchange only")
        }

        async fn disconnect(&self) -> Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn get_target_temperature_decodes_tenths_of_a_degree() {
        let transport = MockTransport::with_responses([Some(vec![8, 164, 3])]);
        let backend = AnovaNano::new(transport, Duration::from_secs(1));

        let temperature = backend.get_target_temperature().await.expect("temperature");
        assert!((temperature - 42.0).abs() < f32::EPSILON);
    }

    #[tokio::test]
    async fn status_uses_motor_speed() {
        let transport = MockTransport::with_responses([Some(vec![
            10, 7, 8, 210, 16, 16, 4, 24, 0, 10, 6, 8, 20, 16, 6, 24, 1, 10, 6, 8, 22, 16, 6, 24,
            2, 10, 6, 8, 24, 16, 6, 24, 3, 10, 6, 8, 25, 16, 6, 24, 4, 10, 6, 8, 1, 16, 3, 24, 5,
            10, 6, 8, 0, 16, 3, 24, 6, 10, 6, 8, 5, 16, 2, 24, 7,
        ])]);
        let backend = AnovaNano::new(transport, Duration::from_secs(1));

        let status = backend.get_status().await.expect("status");
        assert_eq!(status, DeviceStatus::Running);
    }

    #[tokio::test]
    async fn set_unit_writes_without_needing_a_response() {
        let transport = MockTransport::with_responses([None]);
        let backend = AnovaNano::new(transport.clone(), Duration::from_secs(1));

        backend
            .set_unit(TemperatureUnit::Fahrenheit)
            .await
            .expect("set unit");

        let writes = transport.writes.lock().await;
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0], vec![1, 4, 6, 8, 7, 0]);
    }
}
