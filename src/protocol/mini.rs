use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value;

use crate::error::Result;

pub(crate) fn encode_json_payload(value: &Value) -> Result<Vec<u8>> {
    let json = serde_json::to_vec(value)?;
    Ok(STANDARD.encode(json).into_bytes())
}

pub(crate) fn decode_json_payload(data: &[u8]) -> Result<Value> {
    let decoded = STANDARD.decode(data)?;
    Ok(serde_json::from_slice(&decoded)?)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{decode_json_payload, encode_json_payload};

    #[test]
    fn round_trip_json_base64_payload() {
        let value = json!({
            "command": "start",
            "payload": { "setpoint": 63.0, "timer": 3600 }
        });

        let encoded = encode_json_payload(&value).expect("encode");
        let decoded = decode_json_payload(&encoded).expect("decode");

        assert_eq!(decoded, value);
    }
}
