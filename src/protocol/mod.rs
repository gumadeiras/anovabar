pub(crate) mod mini;

mod codec;
mod command;
mod messages;

pub(crate) use codec::{decode_frame, encode_command};
pub(crate) use command::NanoCommand;
pub(crate) use messages::{
    ConfigDomainMessageType, FirmwareInfo as ProtoFirmwareInfo, IntegerValue, SensorType,
    SensorValueList, UnitType,
};

use prost::Message;

use crate::error::{Error, Result};
use crate::types::{DeviceInfo, FirmwareInfo, SensorSnapshot, TemperatureReading, TemperatureUnit};

pub(crate) fn decode_integer_value(payload: &[u8]) -> Result<i32> {
    Ok(IntegerValue::decode(payload)?.value)
}

pub(crate) fn decode_unit(payload: &[u8]) -> Result<TemperatureUnit> {
    let raw = decode_integer_value(payload)?;
    match UnitType::try_from(raw) {
        Ok(UnitType::DegreesC) => Ok(TemperatureUnit::Celsius),
        Ok(UnitType::DegreesF) => Ok(TemperatureUnit::Fahrenheit),
        _ => Err(Error::UnsupportedTemperatureUnit(raw)),
    }
}

pub(crate) fn decode_firmware_info(payload: &[u8]) -> Result<FirmwareInfo> {
    let firmware = ProtoFirmwareInfo::decode(payload)?;
    Ok(FirmwareInfo {
        commit_id: firmware.commit_id,
        tag_id: firmware.tag_id,
        date_code: firmware.date_code,
    })
}

pub(crate) fn decode_device_info(payload: &[u8]) -> Result<DeviceInfo> {
    Ok(DeviceInfo {
        raw_value: decode_integer_value(payload)?,
    })
}

pub(crate) fn decode_sensor_snapshot(payload: &[u8]) -> Result<SensorSnapshot> {
    let sensor_values = SensorValueList::decode(payload)?;

    let mut water_temp = None;
    let mut heater_temp = None;
    let mut triac_temp = None;
    let mut internal_temp = None;
    let mut water_low = None;
    let mut water_leak = None;
    let mut motor_speed = None;

    for sensor in sensor_values.values {
        match SensorType::try_from(sensor.sensor_type) {
            Ok(SensorType::WaterTemp) => {
                water_temp = Some(decode_temperature(sensor.value, sensor.units)?)
            }
            Ok(SensorType::HeaterTemp) => {
                heater_temp = Some(decode_temperature(sensor.value, sensor.units)?)
            }
            Ok(SensorType::TriacTemp) => {
                triac_temp = Some(decode_temperature(sensor.value, sensor.units)?)
            }
            Ok(SensorType::InternalTemp) => {
                internal_temp = Some(decode_temperature(sensor.value, sensor.units)?)
            }
            Ok(SensorType::WaterLow) => water_low = Some(sensor.value != 0),
            Ok(SensorType::WaterLeak) => water_leak = Some(sensor.value != 0),
            Ok(SensorType::MotorSpeed) => motor_speed = Some(sensor.value),
            Ok(SensorType::UnusedTemp) | Err(_) => {}
        }
    }

    Ok(SensorSnapshot {
        water_temp: water_temp.ok_or(Error::MissingSensor("water temperature"))?,
        heater_temp: heater_temp.ok_or(Error::MissingSensor("heater temperature"))?,
        triac_temp: triac_temp.ok_or(Error::MissingSensor("triac temperature"))?,
        internal_temp: internal_temp.ok_or(Error::MissingSensor("internal temperature"))?,
        water_low: water_low.ok_or(Error::MissingSensor("water low"))?,
        water_leak: water_leak.ok_or(Error::MissingSensor("water leak"))?,
        motor_speed: motor_speed.ok_or(Error::MissingSensor("motor speed"))?,
    })
}

fn decode_temperature(raw_value: i32, raw_unit: i32) -> Result<TemperatureReading> {
    let (unit, factor) = match UnitType::try_from(raw_unit) {
        Ok(UnitType::DegreesPoint1C) => (TemperatureUnit::Celsius, 10.0),
        Ok(UnitType::DegreesPoint01C) => (TemperatureUnit::Celsius, 100.0),
        Ok(UnitType::DegreesC) => (TemperatureUnit::Celsius, 1.0),
        Ok(UnitType::DegreesPoint1F) => (TemperatureUnit::Fahrenheit, 10.0),
        Ok(UnitType::DegreesPoint01F) => (TemperatureUnit::Fahrenheit, 100.0),
        Ok(UnitType::DegreesF) => (TemperatureUnit::Fahrenheit, 1.0),
        _ => return Err(Error::UnsupportedTemperatureUnit(raw_unit)),
    };

    Ok(TemperatureReading {
        value: raw_value as f32 / factor,
        unit,
    })
}

#[cfg(test)]
mod tests {
    use prost::Message;

    use super::{codec::encode_frame, decode_frame, decode_integer_value, decode_sensor_snapshot};
    use crate::protocol::{ConfigDomainMessageType, IntegerValue, NanoCommand};
    use crate::types::{DeviceStatus, TemperatureUnit};

    #[test]
    fn encode_frame_matches_python_fixture() {
        let command = NanoCommand::GetSensorValues.encode();
        assert_eq!(command, vec![1, 2, 5, 0]);
    }

    #[test]
    fn encode_set_unit_matches_python_fixture() {
        let value = IntegerValue { value: 2 };
        let payload = [0, ConfigDomainMessageType::SetTempUnits as u8]
            .into_iter()
            .chain(value.encode_to_vec())
            .collect::<Vec<_>>();

        assert_eq!(encode_frame(&payload), vec![1, 4, 6, 8, 2, 0]);
    }

    #[test]
    fn decode_integer_matches_python_fixture() {
        let payload = decode_frame(&[1, 5, 4, 8, 164, 3, 0]).expect("frame");
        let raw = decode_integer_value(&payload).expect("integer");
        assert_eq!(raw, 420);
    }

    #[test]
    fn decode_sensor_values_matches_python_fixture() {
        let payload = decode_frame(
            b"\x01\n\x05\n\x07\x08\xd2\x10\x10\x04\x18\x14\n\x06\x08\x14\x10\x06\x18\x01\n\x06\x08\x16\x10\x06\x18\x02\n\x06\x08\x18\x10\x06\x18\x03\n\x06\x08\x19\x10\x06\x18\x04\n\x06\x08\x01\x10\x03\x18\x05\n\x06\x08\x08\x10\x03\x18\x06\n\x06\x08\x05\x10\x02\x18\x07\x00",
        )
        .expect("frame");

        let sensors = decode_sensor_snapshot(&payload).expect("snapshot");
        assert_eq!(sensors.water_temp.unit, TemperatureUnit::Celsius);
        assert!((sensors.water_temp.value - 21.3).abs() < f32::EPSILON);
        assert_eq!(sensors.status(), DeviceStatus::Stopped);
        assert!(!sensors.water_leak);
    }

    #[test]
    fn decode_incomplete_frame_returns_none() {
        assert!(decode_frame(&[1, 10, 5, 10]).is_none());
    }
}
