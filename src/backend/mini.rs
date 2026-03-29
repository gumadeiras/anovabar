use std::time::Duration;

use serde_json::{Value, json};
use time::OffsetDateTime;
use time::macros::format_description;
use uuid::Uuid;

use super::nano::BleConnectOptions;
use crate::error::Result;
use crate::protocol::mini::{decode_json_payload, encode_json_payload};
use crate::transport::DeviceTransport;
use crate::transport::ble::{BleProfile, BleTransport, DiscoveredDevice};
use crate::types::{MiniFullState, TemperatureUnit};

const MINI_SERVICE_UUID: Uuid = Uuid::from_u128(0x910772a8a5e749a7bc6d701e9a783a5c);
const MINI_SET_TEMPERATURE_UUID: Uuid = Uuid::from_u128(0x0f5639f73c4e47d094960672c89ea48a);
const MINI_CURRENT_TEMPERATURE_UUID: Uuid = Uuid::from_u128(0x6ffdca46d6a84fb28fd9c6330f1939e3);
const MINI_TIMER_UUID: Uuid = Uuid::from_u128(0xa2b179f8944e436fa246c66caaf7061f);
const MINI_STATE_UUID: Uuid = Uuid::from_u128(0x54e53c60367a4783a5c1b1770c54142b);
const MINI_SET_CLOCK_UUID: Uuid = Uuid::from_u128(0xd8a89692cae84b7496e30b99d3637793);
const MINI_SYSTEM_INFO_UUID: Uuid = Uuid::from_u128(0x153c94327c834b8892527588229d5473);

const DEFAULT_SCAN_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const MINI_CONFIRMATION_POLL_INTERVAL: Duration = Duration::from_millis(350);
const MINI_START_CONFIRMATION_ATTEMPTS: usize = 10;
const MINI_STOP_CONFIRMATION_ATTEMPTS: usize = 24;

/// Parameters used by the Mini `start` command.
#[derive(Clone, Debug, PartialEq)]
pub struct StartCookOptions {
    pub setpoint: f64,
    pub timer_seconds: u64,
    pub cookable_id: String,
    pub cookable_type: String,
}

impl StartCookOptions {
    pub fn new(setpoint: f64) -> Self {
        Self {
            setpoint,
            timer_seconds: 0,
            cookable_id: "menubar".to_string(),
            cookable_type: "manual".to_string(),
        }
    }
}

/// High-level backend for Anova Mini BLE devices.
#[derive(Debug)]
pub struct AnovaMini<T = BleTransport<MiniBleProfile>> {
    transport: T,
    command_timeout: Duration,
}

impl AnovaMini<BleTransport<MiniBleProfile>> {
    pub async fn discover(scan_timeout: Duration) -> Result<Vec<DiscoveredDevice>> {
        BleTransport::<MiniBleProfile>::discover(scan_timeout).await
    }

    pub async fn connect(options: BleConnectOptions) -> Result<Self> {
        let transport = BleTransport::<MiniBleProfile>::connect(
            options.address.as_deref(),
            options.scan_timeout,
        )
        .await?;
        Ok(Self::new(transport, options.command_timeout))
    }
}

impl<T> AnovaMini<T>
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

    pub async fn get_system_info(&self) -> Result<Value> {
        self.read_json(MINI_SYSTEM_INFO_UUID).await
    }

    pub async fn get_state(&self) -> Result<Value> {
        self.read_json(MINI_STATE_UUID).await
    }

    pub async fn get_current_temperature(&self) -> Result<Value> {
        self.read_json(MINI_CURRENT_TEMPERATURE_UUID).await
    }

    pub async fn get_timer(&self) -> Result<Value> {
        self.read_json(MINI_TIMER_UUID).await
    }

    pub async fn get_full_state(&self) -> Result<MiniFullState> {
        Ok(MiniFullState {
            state: self.get_state().await?,
            current_temperature: self.get_current_temperature().await?,
            timer: self.get_timer().await?,
        })
    }

    pub async fn set_clock_to_utc_now(&self) -> Result<()> {
        let current_time = chrono_like_utc_timestamp();
        self.write_json(
            MINI_SET_CLOCK_UUID,
            json!({ "currentTime": current_time }),
            true,
        )
        .await
    }

    pub async fn set_unit(&self, unit: TemperatureUnit) -> Result<()> {
        self.write_json(
            MINI_STATE_UUID,
            json!({
                "command": "changeUnit",
                "payload": { "temperatureUnit": unit.as_symbol() }
            }),
            false,
        )
        .await
    }

    pub async fn set_temperature(&self, value: f64) -> Result<()> {
        self.write_json(
            MINI_SET_TEMPERATURE_UUID,
            json!({ "setpoint": value }),
            false,
        )
        .await
    }

    pub async fn start_cook(&self, options: StartCookOptions) -> Result<()> {
        self.write_json(
            MINI_STATE_UUID,
            json!({
                "command": "start",
                "payload": {
                    "setpoint": options.setpoint,
                    "timer": options.timer_seconds,
                    "cookableId": options.cookable_id,
                    "cookableType": options.cookable_type,
                }
            }),
            false,
        )
        .await
    }

    pub async fn start_cook_confirmed(&self, options: StartCookOptions) -> Result<()> {
        let setpoint = options.setpoint;
        let timer_seconds = options.timer_seconds;

        self.set_clock_to_utc_now().await?;
        self.start_cook(options).await?;
        self.poll_until(
            MINI_START_CONFIRMATION_ATTEMPTS,
            format!("mini cooker did not confirm a running state for setpoint {setpoint:.1} and timer {timer_seconds}s"),
            |snapshot| snapshot.matches_running(setpoint, timer_seconds),
        )
        .await?;

        Ok(())
    }

    pub async fn stop_cook(&self) -> Result<()> {
        self.write_json(MINI_STATE_UUID, json!({ "command": "stop" }), false)
            .await
    }

    pub async fn stop_cook_confirmed(&self) -> Result<()> {
        self.stop_cook().await?;
        self.poll_until(
            MINI_STOP_CONFIRMATION_ATTEMPTS,
            "mini cooker did not confirm a stopped state".to_string(),
            MiniFullState::matches_stopped,
        )
        .await?;

        Ok(())
    }

    async fn read_json(&self, characteristic: Uuid) -> Result<Value> {
        let payload = self
            .transport
            .read(characteristic, self.command_timeout)
            .await?;
        decode_json_payload(&payload)
    }

    async fn write_json(&self, characteristic: Uuid, value: Value, response: bool) -> Result<()> {
        let payload = encode_json_payload(&value)?;
        self.transport
            .write(characteristic, &payload, response)
            .await
    }

    async fn poll_until<F>(
        &self,
        attempts: usize,
        error_message: String,
        predicate: F,
    ) -> Result<MiniFullState>
    where
        F: Fn(&MiniFullState) -> bool,
    {
        for attempt in 0..attempts {
            if attempt > 0 {
                tokio::time::sleep(MINI_CONFIRMATION_POLL_INTERVAL).await;
            }

            let snapshot = self.get_full_state().await?;
            if predicate(&snapshot) {
                return Ok(snapshot);
            }
        }

        Err(crate::error::Error::StateUnconfirmed(error_message))
    }
}

/// BLE profile for the Anova Mini / Gen 3 cooker.
#[derive(Debug)]
pub struct MiniBleProfile;

impl BleProfile for MiniBleProfile {
    fn service_uuid() -> Uuid {
        MINI_SERVICE_UUID
    }

    fn required_characteristic_uuids() -> Vec<Uuid> {
        vec![
            MINI_SET_TEMPERATURE_UUID,
            MINI_CURRENT_TEMPERATURE_UUID,
            MINI_TIMER_UUID,
            MINI_STATE_UUID,
            MINI_SET_CLOCK_UUID,
            MINI_SYSTEM_INFO_UUID,
        ]
    }
}

fn chrono_like_utc_timestamp() -> String {
    OffsetDateTime::now_utc()
        .format(&format_description!(
            "[year]-[month]-[day]T[hour]:[minute]:[second]+00:00"
        ))
        .expect("utc formatting should succeed")
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::sync::Arc;
    use std::time::Duration;

    use async_trait::async_trait;
    use serde_json::json;
    use tokio::sync::Mutex;
    use uuid::Uuid;

    use super::{
        AnovaMini, MINI_SET_CLOCK_UUID, MINI_SET_TEMPERATURE_UUID, MINI_STATE_UUID,
        StartCookOptions,
    };
    use crate::error::Result;
    use crate::protocol::mini::decode_json_payload;
    use crate::transport::DeviceTransport;
    use crate::types::TemperatureUnit;

    #[derive(Debug, Default)]
    struct MockTransport {
        reads: Mutex<VecDeque<Vec<u8>>>,
        writes: Mutex<Vec<(Uuid, Vec<u8>, bool)>>,
    }

    impl MockTransport {
        fn with_reads(reads: impl IntoIterator<Item = Vec<u8>>) -> Arc<Self> {
            Arc::new(Self {
                reads: Mutex::new(reads.into_iter().collect()),
                writes: Mutex::new(Vec::new()),
            })
        }
    }

    #[async_trait]
    impl DeviceTransport for Arc<MockTransport> {
        async fn exchange(
            &self,
            _payload: &[u8],
            _expect_response: bool,
            _timeout: Duration,
        ) -> Result<Option<Vec<u8>>> {
            unreachable!("mini tests use direct read/write only")
        }

        async fn read(&self, _characteristic: Uuid, _timeout: Duration) -> Result<Vec<u8>> {
            Ok(self.reads.lock().await.pop_front().expect("queued read"))
        }

        async fn write(&self, characteristic: Uuid, payload: &[u8], response: bool) -> Result<()> {
            self.writes
                .lock()
                .await
                .push((characteristic, payload.to_vec(), response));
            Ok(())
        }

        async fn disconnect(&self) -> Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn get_full_state_reads_three_json_characteristics() {
        let transport = MockTransport::with_reads([
            b"eyJ0ZW1wZXJhdHVyZVVuaXQiOiJDIiwic3RhdGUiOiJpZGxlIn0=".to_vec(),
            b"eyJjdXJyZW50Ijo2My41fQ==".to_vec(),
            b"eyJyZW1haW5pbmciOjM2MDB9".to_vec(),
        ]);
        let backend = AnovaMini::new(transport, Duration::from_secs(1));

        let full_state = backend.get_full_state().await.expect("full state");

        assert_eq!(full_state.state["temperatureUnit"], "C");
        assert_eq!(full_state.current_temperature["current"], 63.5);
        assert_eq!(full_state.timer["remaining"], 3600);
    }

    #[tokio::test]
    async fn set_temperature_writes_base64_json_to_expected_characteristic() {
        let transport = MockTransport::with_reads([]);
        let backend = AnovaMini::new(transport.clone(), Duration::from_secs(1));

        backend
            .set_temperature(65.5)
            .await
            .expect("set temperature");

        let writes = transport.writes.lock().await;
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].0, MINI_SET_TEMPERATURE_UUID);
        assert!(!writes[0].2);
        assert_eq!(
            decode_json_payload(&writes[0].1).expect("decode"),
            json!({ "setpoint": 65.5 })
        );
    }

    #[tokio::test]
    async fn start_cook_writes_expected_command_shape() {
        let transport = MockTransport::with_reads([]);
        let backend = AnovaMini::new(transport.clone(), Duration::from_secs(1));
        let mut options = StartCookOptions::new(63.0);
        options.timer_seconds = 3_600;
        options.cookable_id = "recipe-1".to_string();
        options.cookable_type = "recipe".to_string();

        backend.start_cook(options).await.expect("start cook");

        let writes = transport.writes.lock().await;
        assert_eq!(writes[0].0, MINI_STATE_UUID);
        assert_eq!(
            decode_json_payload(&writes[0].1).expect("decode"),
            json!({
                "command": "start",
                "payload": {
                    "setpoint": 63.0,
                    "timer": 3600,
                    "cookableId": "recipe-1",
                    "cookableType": "recipe",
                }
            })
        );
    }

    #[tokio::test]
    async fn set_unit_writes_temperature_unit_command() {
        let transport = MockTransport::with_reads([]);
        let backend = AnovaMini::new(transport.clone(), Duration::from_secs(1));

        backend
            .set_unit(TemperatureUnit::Fahrenheit)
            .await
            .expect("set unit");

        let writes = transport.writes.lock().await;
        assert_eq!(writes[0].0, MINI_STATE_UUID);
        assert_eq!(
            decode_json_payload(&writes[0].1).expect("decode"),
            json!({
                "command": "changeUnit",
                "payload": { "temperatureUnit": "F" }
            })
        );
    }

    #[tokio::test]
    async fn set_clock_uses_acknowledged_write() {
        let transport = MockTransport::with_reads([]);
        let backend = AnovaMini::new(transport.clone(), Duration::from_secs(1));

        backend.set_clock_to_utc_now().await.expect("set clock");

        let writes = transport.writes.lock().await;
        assert_eq!(writes[0].0, MINI_SET_CLOCK_UUID);
        assert!(writes[0].2);
        let decoded = decode_json_payload(&writes[0].1).expect("decode");
        assert!(decoded["currentTime"].as_str().is_some());
    }
}
