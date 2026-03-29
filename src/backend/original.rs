use std::time::Duration;

use uuid::Uuid;

use super::nano::BleConnectOptions;
use crate::error::{Error, Result};
use crate::transport::DeviceTransport;
use crate::transport::ble::{BleProfile, BleTransport, DiscoveredDevice};
use crate::types::{OriginalCookerModel, TemperatureUnit};

const ORIGINAL_SERVICE_UUID: Uuid = Uuid::from_u128(0x0000ffe000001000800000805f9b34fb);
const ORIGINAL_CHARACTERISTIC_UUID: Uuid = Uuid::from_u128(0x0000ffe100001000800000805f9b34fb);

const DEFAULT_SCAN_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Debug, PartialEq)]
pub struct OriginalStartCookOptions {
    pub setpoint: f64,
    pub timer_minutes: u32,
}

impl OriginalStartCookOptions {
    pub fn new(setpoint: f64) -> Self {
        Self {
            setpoint,
            timer_minutes: 0,
        }
    }
}

#[derive(Debug)]
pub struct AnovaOriginalPrecisionCooker<T = BleTransport<OriginalPrecisionCookerBleProfile>> {
    transport: T,
    command_timeout: Duration,
}

impl AnovaOriginalPrecisionCooker<BleTransport<OriginalPrecisionCookerBleProfile>> {
    pub async fn discover(scan_timeout: Duration) -> Result<Vec<DiscoveredDevice>> {
        BleTransport::<OriginalPrecisionCookerBleProfile>::discover(scan_timeout).await
    }

    pub async fn connect(options: BleConnectOptions) -> Result<Self> {
        let transport = BleTransport::<OriginalPrecisionCookerBleProfile>::connect(
            options.address.as_deref(),
            options.scan_timeout,
        )
        .await?;
        Ok(Self::new(transport, options.command_timeout))
    }
}

impl<T> AnovaOriginalPrecisionCooker<T>
where
    T: DeviceTransport,
{
    pub fn new(transport: T, command_timeout: Duration) -> Self {
        Self {
            transport,
            command_timeout,
        }
    }

    pub fn default_scan_timeout() -> Duration {
        DEFAULT_SCAN_TIMEOUT
    }

    pub fn default_command_timeout() -> Duration {
        DEFAULT_COMMAND_TIMEOUT
    }

    pub async fn disconnect(&self) -> Result<()> {
        self.transport.disconnect().await
    }

    pub async fn status(&self) -> Result<String> {
        self.send_command("status").await
    }

    pub async fn read_unit(&self) -> Result<TemperatureUnit> {
        let response = self.send_command("read unit").await?;
        match response.trim().to_ascii_uppercase().as_str() {
            "C" => Ok(TemperatureUnit::Celsius),
            "F" => Ok(TemperatureUnit::Fahrenheit),
            value => Err(Error::InvalidInput(format!(
                "Unexpected unit response from original cooker: {value}"
            ))),
        }
    }

    pub async fn set_unit(&self, unit: TemperatureUnit) -> Result<String> {
        self.send_command(&format!(
            "set unit {}",
            unit.as_symbol().to_ascii_lowercase()
        ))
        .await
    }

    pub async fn read_target_temperature(&self) -> Result<String> {
        self.send_command("read set temp").await
    }

    pub async fn read_temperature(&self) -> Result<String> {
        self.send_command("read temp").await
    }

    pub async fn set_temperature(&self, temperature: f64) -> Result<String> {
        self.send_command(&format!("set temp {}", temperature))
            .await
    }

    pub async fn read_timer(&self) -> Result<String> {
        self.send_command("read timer").await
    }

    pub async fn set_timer_minutes(&self, minutes: u32) -> Result<String> {
        self.send_command(&format!("set timer {}", minutes)).await
    }

    pub async fn start_timer(&self) -> Result<String> {
        self.send_command("start time").await
    }

    pub async fn stop_timer(&self) -> Result<String> {
        self.send_command("stop time").await
    }

    pub async fn start_cook(&self, options: OriginalStartCookOptions) -> Result<()> {
        self.set_temperature(options.setpoint).await?;
        self.stop_timer().await?;
        self.set_timer_minutes(options.timer_minutes).await?;
        self.send_command("start").await?;
        if options.timer_minutes > 0 {
            self.start_timer().await?;
        }
        Ok(())
    }

    pub async fn stop_cook(&self) -> Result<String> {
        self.send_command("stop").await
    }

    pub async fn get_cooker_id(&self) -> Result<String> {
        self.send_command("get id card").await
    }

    pub async fn detect_model(&self) -> Result<OriginalCookerModel> {
        let response = self.get_cooker_id().await?;
        if response.to_ascii_lowercase().starts_with("anova f56-") {
            Ok(OriginalCookerModel::Wifi900W)
        } else {
            Ok(OriginalCookerModel::Bluetooth800W)
        }
    }

    pub async fn clear_alarm(&self) -> Result<String> {
        self.ensure_wifi_model().await?;
        self.send_command("clear alarm").await
    }

    pub async fn firmware_version(&self) -> Result<String> {
        self.ensure_wifi_model().await?;
        self.send_command("version").await
    }

    async fn ensure_wifi_model(&self) -> Result<()> {
        if self.detect_model().await? == OriginalCookerModel::Wifi900W {
            Ok(())
        } else {
            Err(Error::UnsupportedOperation(
                "command is only available on original 900w WiFi models",
            ))
        }
    }

    async fn send_command(&self, command: &str) -> Result<String> {
        let payload = format!("{command}\r");
        let response = self
            .transport
            .exchange(payload.as_bytes(), true, self.command_timeout)
            .await?
            .ok_or(Error::NotificationStreamClosed)?;
        Ok(String::from_utf8_lossy(&response)
            .trim_matches(char::from(0))
            .trim()
            .to_string())
    }
}

#[derive(Debug)]
pub struct OriginalPrecisionCookerBleProfile;

impl BleProfile for OriginalPrecisionCookerBleProfile {
    fn service_uuid() -> Uuid {
        ORIGINAL_SERVICE_UUID
    }

    fn exchange_write_characteristic_uuid() -> Option<Uuid> {
        Some(ORIGINAL_CHARACTERISTIC_UUID)
    }

    fn notification_characteristic_uuid() -> Option<Uuid> {
        Some(ORIGINAL_CHARACTERISTIC_UUID)
    }

    fn decode_response(raw: &[u8], latest_chunk: &[u8]) -> Option<Vec<u8>> {
        if latest_chunk.last().copied() == Some(0) || latest_chunk.len() < 20 {
            Some(raw.to_vec())
        } else {
            None
        }
    }

    fn required_characteristic_uuids() -> Vec<Uuid> {
        vec![ORIGINAL_CHARACTERISTIC_UUID]
    }

    fn matches_device(properties: &btleplug::api::PeripheralProperties) -> bool {
        properties.services.contains(&Self::service_uuid())
            || properties
                .local_name
                .as_deref()
                .map(|name| name.to_ascii_lowercase().contains("anova precision cooker"))
                .unwrap_or(false)
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

    use super::{
        AnovaOriginalPrecisionCooker, OriginalPrecisionCookerBleProfile, OriginalStartCookOptions,
        ORIGINAL_SERVICE_UUID,
    };
    use crate::error::Result;
    use crate::transport::ble::BleProfile;
    use crate::transport::DeviceTransport;
    use crate::types::{OriginalCookerModel, TemperatureUnit};

    #[derive(Debug, Default)]
    struct MockTransport {
        responses: Mutex<VecDeque<Option<Vec<u8>>>>,
        writes: Mutex<Vec<Vec<u8>>>,
    }

    impl MockTransport {
        fn with_responses(responses: impl IntoIterator<Item = Option<Vec<u8>>>) -> Arc<Self> {
            Arc::new(Self {
                responses: Mutex::new(responses.into_iter().collect()),
                writes: Mutex::new(Vec::new()),
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
            unreachable!("original cooker backend uses exchange")
        }

        async fn write(
            &self,
            _characteristic: Uuid,
            _payload: &[u8],
            _response: bool,
        ) -> Result<()> {
            unreachable!("original cooker backend uses exchange")
        }

        async fn disconnect(&self) -> Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn detects_wifi_model_from_cooker_id() {
        let transport = MockTransport::with_responses([Some(b"anova f56-900w".to_vec())]);
        let backend = AnovaOriginalPrecisionCooker::new(transport, Duration::from_secs(1));

        let model = backend.detect_model().await.expect("model");

        assert_eq!(model, OriginalCookerModel::Wifi900W);
    }

    #[tokio::test]
    async fn parses_temperature_unit() {
        let transport = MockTransport::with_responses([Some(b"F".to_vec())]);
        let backend = AnovaOriginalPrecisionCooker::new(transport, Duration::from_secs(1));

        let unit = backend.read_unit().await.expect("unit");

        assert_eq!(unit, TemperatureUnit::Fahrenheit);
    }

    #[tokio::test]
    async fn start_sequence_sets_temp_timer_and_starts_timer() {
        let transport = MockTransport::with_responses([
            Some(b"ok".to_vec()),
            Some(b"ok".to_vec()),
            Some(b"ok".to_vec()),
            Some(b"ok".to_vec()),
            Some(b"ok".to_vec()),
        ]);
        let backend = AnovaOriginalPrecisionCooker::new(transport.clone(), Duration::from_secs(1));

        backend
            .start_cook(OriginalStartCookOptions {
                setpoint: 54.5,
                timer_minutes: 45,
            })
            .await
            .expect("start");

        let writes = transport
            .writes
            .lock()
            .await
            .iter()
            .map(|payload| String::from_utf8_lossy(payload).into_owned())
            .collect::<Vec<_>>();

        assert_eq!(
            writes,
            vec![
                "set temp 54.5\r",
                "stop time\r",
                "set timer 45\r",
                "start\r",
                "start time\r",
            ]
        );
    }

    #[test]
    fn device_matching_requires_service_or_precise_name() {
        let mut properties = btleplug::api::PeripheralProperties::default();

        assert!(!OriginalPrecisionCookerBleProfile::matches_device(&properties));

        properties.local_name = Some("Anova Precision Cooker".to_string());
        assert!(OriginalPrecisionCookerBleProfile::matches_device(&properties));

        properties.local_name = Some("Anova Mini".to_string());
        assert!(!OriginalPrecisionCookerBleProfile::matches_device(&properties));

        properties.local_name = Some("Unknown".to_string());
        properties.services.push(ORIGINAL_SERVICE_UUID);
        assert!(OriginalPrecisionCookerBleProfile::matches_device(&properties));
    }
}
