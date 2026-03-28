const CONFIG_DOMAIN_ID: u8 = 0;

pub(crate) fn encode_frame(payload: &[u8]) -> Vec<u8> {
    let mut framed = vec![0];
    let mut last_index = 0usize;
    let mut current_index = 1u8;

    let reset_index =
        |framed: &mut Vec<u8>, is_end: bool, last_index: &mut usize, current_index: &mut u8| {
            framed[*last_index] = *current_index;
            *last_index = framed.len();
            if is_end {
                framed.push(0);
            }
            *current_index = 1;
        };

    for &byte in payload {
        if byte == 0 {
            reset_index(&mut framed, true, &mut last_index, &mut current_index);
            continue;
        }

        framed.push(byte);
        current_index += 1;

        if current_index == u8::MAX {
            reset_index(&mut framed, true, &mut last_index, &mut current_index);
        }
    }

    reset_index(&mut framed, false, &mut last_index, &mut current_index);
    framed.push(0);
    framed
}

pub(crate) fn encode_command(message_type: u8, value_payload: Option<&[u8]>) -> Vec<u8> {
    let mut payload = vec![CONFIG_DOMAIN_ID, message_type];
    if let Some(value_payload) = value_payload {
        payload.extend_from_slice(value_payload);
    }
    encode_frame(&payload)
}

pub(crate) fn decode_frame(raw_data: &[u8]) -> Option<Vec<u8>> {
    if raw_data.is_empty() {
        return None;
    }

    let data = &raw_data[..raw_data.len() - 1];
    let mut results = Vec::new();
    let mut index = 0usize;

    while index < data.len().saturating_sub(1) {
        let block_length = data[index] as usize;
        index += 1;

        for _ in 1..block_length {
            let byte = *data.get(index)?;
            results.push(byte);
            index += 1;
        }

        if block_length < usize::from(u8::MAX) && index < data.len() {
            results.push(0);
        }
    }

    if results.len() <= 2 {
        return Some(Vec::new());
    }

    Some(results.split_off(2))
}
