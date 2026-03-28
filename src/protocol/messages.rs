#[derive(Clone, PartialEq, ::prost::Message)]
pub(crate) struct FirmwareInfo {
    #[prost(string, tag = "1")]
    pub commit_id: String,
    #[prost(string, tag = "2")]
    pub tag_id: String,
    #[prost(uint32, tag = "3")]
    pub date_code: u32,
}

#[derive(Clone, PartialEq, ::prost::Message)]
pub(crate) struct IntegerValue {
    #[prost(int32, tag = "1")]
    pub value: i32,
}

#[derive(Clone, PartialEq, ::prost::Message)]
pub(crate) struct SensorValue {
    #[prost(int32, tag = "1")]
    pub value: i32,
    #[prost(enumeration = "UnitType", tag = "2")]
    pub units: i32,
    #[prost(enumeration = "SensorType", tag = "3")]
    pub sensor_type: i32,
}

#[derive(Clone, PartialEq, ::prost::Message)]
pub(crate) struct SensorValueList {
    #[prost(message, repeated, tag = "1")]
    pub values: Vec<SensorValue>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ::prost::Enumeration)]
#[repr(i32)]
pub(crate) enum SensorType {
    WaterTemp = 0,
    HeaterTemp = 1,
    TriacTemp = 2,
    UnusedTemp = 3,
    InternalTemp = 4,
    WaterLow = 5,
    WaterLeak = 6,
    MotorSpeed = 7,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ::prost::Enumeration)]
#[repr(i32)]
pub(crate) enum UnitType {
    DegreesPoint1C = 0,
    DegreesPoint1F = 1,
    MotorSpeed = 2,
    Boolean = 3,
    DegreesPoint01C = 4,
    DegreesPoint01F = 5,
    DegreesC = 6,
    DegreesF = 7,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, ::prost::Enumeration)]
#[repr(i32)]
pub(crate) enum ConfigDomainMessageType {
    Loopback = 0,
    CliText = 1,
    SayHello = 2,
    SetTempSetpoint = 3,
    GetTempSetpoint = 4,
    GetSensors = 5,
    SetTempUnits = 6,
    GetTempUnits = 7,
    SetCookingPowerLevel = 8,
    GetCookingPowerLevel = 9,
    StartCooking = 10,
    StopCooking = 11,
    SetSoundLevel = 12,
    GetSoundLevel = 13,
    SetDisplayBrightness = 14,
    GetDisplayBrightness = 15,
    SetCookingTimer = 16,
    StopCookingTimer = 17,
    GetCookingTimer = 18,
    CancelCookingTimer = 19,
    SetChangePoint = 20,
    ChangePoint = 22,
    SetBleParams = 23,
    BleParams = 24,
    GetDeviceInfo = 25,
    GetFirmwareInfo = 26,
    SystemAlertVector = 27,
    Reserved28 = 28,
    MessageSpoof = 29,
}
