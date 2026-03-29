use serde_json::Value;

/// Temperature unit used by the device.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TemperatureUnit {
    Celsius,
    Fahrenheit,
}

impl TemperatureUnit {
    pub fn as_symbol(self) -> &'static str {
        match self {
            Self::Celsius => "C",
            Self::Fahrenheit => "F",
        }
    }

    pub fn supported_mini_setpoint_range(self) -> (f64, f64) {
        match self {
            Self::Celsius => (0.0, 92.0),
            Self::Fahrenheit => (32.0, 197.0),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OriginalCookerModel {
    Bluetooth800W,
    Wifi900W,
}

impl OriginalCookerModel {
    pub fn as_label(self) -> &'static str {
        match self {
            Self::Bluetooth800W => "800w",
            Self::Wifi900W => "900w-wifi",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TemperatureReading {
    pub value: f32,
    pub unit: TemperatureUnit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeviceStatus {
    Running,
    Stopped,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SensorSnapshot {
    pub water_temp: TemperatureReading,
    pub heater_temp: TemperatureReading,
    pub triac_temp: TemperatureReading,
    pub internal_temp: TemperatureReading,
    pub water_low: bool,
    pub water_leak: bool,
    pub motor_speed: i32,
}

impl SensorSnapshot {
    pub fn status(&self) -> DeviceStatus {
        if self.motor_speed == 0 {
            DeviceStatus::Stopped
        } else {
            DeviceStatus::Running
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DeviceInfo {
    pub raw_value: i32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FirmwareInfo {
    pub commit_id: String,
    pub tag_id: String,
    pub date_code: u32,
}

/// Snapshot of Mini state assembled from multiple JSON characteristics.
#[derive(Clone, Debug, PartialEq)]
pub struct MiniFullState {
    pub state: Value,
    pub current_temperature: Value,
    pub timer: Value,
}

impl MiniFullState {
    pub fn temperature_unit(&self) -> Option<TemperatureUnit> {
        match self.state.get("temperatureUnit")?.as_str()? {
            "C" | "c" => Some(TemperatureUnit::Celsius),
            "F" | "f" => Some(TemperatureUnit::Fahrenheit),
            _ => None,
        }
    }

    pub fn current_temperature_value(&self) -> Option<f64> {
        self.current_temperature.get("current")?.as_f64()
    }

    pub fn target_temperature_value(&self) -> Option<f64> {
        self.state
            .get("setpoint")
            .and_then(Value::as_f64)
            .or_else(|| self.current_temperature.get("setpoint").and_then(Value::as_f64))
    }

    pub fn state_mode(&self) -> Option<&str> {
        self.state.get("mode").and_then(Value::as_str)
    }

    pub fn timer_mode(&self) -> Option<&str> {
        self.timer.get("mode").and_then(Value::as_str)
    }

    pub fn timer_seconds_value(&self) -> Option<u64> {
        self.timer
            .get("remaining")
            .and_then(Value::as_u64)
            .or_else(|| self.timer.get("timerSeconds").and_then(Value::as_u64))
            .or_else(|| self.timer.get("initial").and_then(Value::as_u64))
    }

    pub fn is_running(&self) -> bool {
        self.state_mode().is_some_and(is_running_mode)
            || self.timer_mode().is_some_and(is_running_mode)
    }

    pub fn matches_running(&self, setpoint: f64, timer_seconds: u64) -> bool {
        if !self.is_running() {
            return false;
        }

        if !self
            .target_temperature_value()
            .is_none_or(|current| (current - setpoint).abs() <= 0.2)
        {
            return false;
        }

        if timer_seconds == 0 {
            return true;
        }

        self.timer_seconds_value()
            .is_some_and(|seconds| seconds > 0 && seconds <= timer_seconds)
    }

    pub fn matches_stopped(&self) -> bool {
        !self.is_running()
    }
}

fn is_running_mode(mode: &str) -> bool {
    matches!(mode, "cook" | "cooking" | "running" | "active")
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::MiniFullState;

    #[test]
    fn mini_full_state_matches_running_when_state_is_active() {
        let state = MiniFullState {
            state: json!({ "mode": "cook", "setpoint": 37.5 }),
            current_temperature: json!({ "current": 37.0 }),
            timer: json!({ "initial": 120, "mode": "idle" }),
        };

        assert!(state.matches_running(37.5, 120));
    }

    #[test]
    fn mini_full_state_matches_stopped_when_no_active_modes_exist() {
        let state = MiniFullState {
            state: json!({ "mode": "idle" }),
            current_temperature: json!({ "current": 37.0 }),
            timer: json!({ "initial": 120, "mode": "idle" }),
        };

        assert!(state.matches_stopped());
    }
}
