use prost::Message;

use crate::protocol::{ConfigDomainMessageType, IntegerValue, UnitType, encode_command};
use crate::types::TemperatureUnit;

#[derive(Clone, Debug)]
pub(crate) enum NanoCommand {
    GetSensorValues,
    GetTargetTemperature,
    GetTimer,
    GetUnit,
    GetFirmwareInfo,
    GetDeviceInfo,
    Start,
    Stop,
    SetUnit(TemperatureUnit),
    SetTargetTemperature(f32),
    SetTimer(u32),
}

impl NanoCommand {
    pub(crate) fn expects_response(&self) -> bool {
        matches!(
            self,
            Self::GetSensorValues
                | Self::GetTargetTemperature
                | Self::GetTimer
                | Self::GetUnit
                | Self::GetFirmwareInfo
                | Self::GetDeviceInfo
                | Self::Start
                | Self::Stop
        )
    }

    pub(crate) fn encode(&self) -> Vec<u8> {
        match self {
            Self::GetSensorValues => {
                encode_command(ConfigDomainMessageType::GetSensors as u8, None)
            }
            Self::GetTargetTemperature => {
                encode_command(ConfigDomainMessageType::GetTempSetpoint as u8, None)
            }
            Self::GetTimer => encode_command(ConfigDomainMessageType::GetCookingTimer as u8, None),
            Self::GetUnit => encode_command(ConfigDomainMessageType::GetTempUnits as u8, None),
            Self::GetFirmwareInfo => {
                encode_command(ConfigDomainMessageType::GetFirmwareInfo as u8, None)
            }
            Self::GetDeviceInfo => {
                encode_command(ConfigDomainMessageType::GetDeviceInfo as u8, None)
            }
            Self::Start => encode_command(ConfigDomainMessageType::StartCooking as u8, None),
            Self::Stop => encode_command(ConfigDomainMessageType::StopCooking as u8, None),
            Self::SetUnit(unit) => {
                let value = IntegerValue {
                    value: match unit {
                        TemperatureUnit::Celsius => UnitType::DegreesC as i32,
                        TemperatureUnit::Fahrenheit => UnitType::DegreesF as i32,
                    },
                };
                encode_command(
                    ConfigDomainMessageType::SetTempUnits as u8,
                    Some(&value.encode_to_vec()),
                )
            }
            Self::SetTargetTemperature(temperature) => {
                let value = IntegerValue {
                    value: (temperature * 10.0).round() as i32,
                };
                encode_command(
                    ConfigDomainMessageType::SetTempSetpoint as u8,
                    Some(&value.encode_to_vec()),
                )
            }
            Self::SetTimer(minutes) => {
                let value = IntegerValue {
                    value: *minutes as i32,
                };
                encode_command(
                    ConfigDomainMessageType::SetCookingTimer as u8,
                    Some(&value.encode_to_vec()),
                )
            }
        }
    }
}
