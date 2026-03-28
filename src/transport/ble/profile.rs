use btleplug::api::PeripheralProperties;
use uuid::Uuid;

/// Describes the BLE surface needed by a device family.
pub trait BleProfile: 'static {
    /// Primary service UUID used to discover compatible devices.
    fn service_uuid() -> Uuid;

    /// Characteristic used for request/response style exchanges, if the device supports them.
    fn exchange_write_characteristic_uuid() -> Option<Uuid> {
        None
    }

    /// Characteristic that emits notifications for `exchange` responses, if any.
    fn notification_characteristic_uuid() -> Option<Uuid> {
        None
    }

    /// Decodes an accumulated notification buffer into a complete response payload.
    fn decode_response(_raw: &[u8]) -> Option<Vec<u8>> {
        None
    }

    /// Characteristics that must be present for the profile to be considered usable.
    fn required_characteristic_uuids() -> Vec<Uuid> {
        let mut uuids = Vec::new();
        if let Some(uuid) = Self::exchange_write_characteristic_uuid() {
            uuids.push(uuid);
        }
        if let Some(uuid) = Self::notification_characteristic_uuid() {
            uuids.push(uuid);
        }
        uuids
    }

    fn matches_device(properties: &PeripheralProperties) -> bool {
        properties.services.contains(&Self::service_uuid())
    }
}
