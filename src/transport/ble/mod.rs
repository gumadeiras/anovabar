mod profile;

use std::collections::HashMap;
use std::marker::PhantomData;
use std::time::Duration;

use async_trait::async_trait;
use btleplug::api::{
    Central, Characteristic, Manager as _, Peripheral as _, ScanFilter, ValueNotification,
    WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::error::{Error, Result};
use crate::transport::DeviceTransport;

pub use profile::BleProfile;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveredDevice {
    pub address: String,
    pub local_name: Option<String>,
}

/// Shared BLE transport that can be specialized by a [`BleProfile`].
#[derive(Debug)]
pub struct BleTransport<P> {
    peripheral: Peripheral,
    characteristics: HashMap<Uuid, Characteristic>,
    notifications: Mutex<mpsc::UnboundedReceiver<Vec<u8>>>,
    notification_task: Mutex<Option<JoinHandle<()>>>,
    request_lock: Mutex<()>,
    _profile: PhantomData<P>,
}

impl<P> BleTransport<P>
where
    P: BleProfile,
{
    pub async fn discover(scan_timeout: Duration) -> Result<Vec<DiscoveredDevice>> {
        let adapter = first_adapter().await?;
        scan_for_devices::<P>(&adapter, scan_timeout).await
    }

    pub async fn connect(address: Option<&str>, scan_timeout: Duration) -> Result<Self> {
        let adapter = first_adapter().await?;
        let peripheral = find_device::<P>(&adapter, address, scan_timeout).await?;

        peripheral.connect().await?;
        peripheral.discover_services().await?;

        let characteristics = peripheral
            .characteristics()
            .into_iter()
            .map(|characteristic| (characteristic.uuid, characteristic))
            .collect::<HashMap<_, _>>();

        for required_uuid in P::required_characteristic_uuids() {
            if !characteristics.contains_key(&required_uuid) {
                return Err(Error::MissingCharacteristic(
                    "required profile characteristic",
                ));
            }
        }

        let (tx, rx) = mpsc::unbounded_channel();
        let notification_task = if let Some(notification_uuid) =
            P::notification_characteristic_uuid()
        {
            let notification_characteristic = characteristics
                .get(&notification_uuid)
                .cloned()
                .ok_or(Error::MissingCharacteristic("notification"))?;

            let mut notification_stream = peripheral.notifications().await?;
            peripheral.subscribe(&notification_characteristic).await?;

            Some(tokio::spawn(async move {
                while let Some(ValueNotification { value, .. }) = notification_stream.next().await {
                    if tx.send(value).is_err() {
                        break;
                    }
                }
            }))
        } else {
            None
        };

        Ok(Self {
            peripheral,
            characteristics,
            notifications: Mutex::new(rx),
            notification_task: Mutex::new(notification_task),
            request_lock: Mutex::new(()),
            _profile: PhantomData,
        })
    }
}

#[async_trait]
impl<P> DeviceTransport for BleTransport<P>
where
    P: BleProfile + Send + Sync,
{
    async fn exchange(
        &self,
        payload: &[u8],
        expect_response: bool,
        timeout: Duration,
    ) -> Result<Option<Vec<u8>>> {
        let write_uuid = P::exchange_write_characteristic_uuid()
            .ok_or(Error::UnsupportedOperation("exchange"))?;
        let write_characteristic = self
            .characteristics
            .get(&write_uuid)
            .ok_or(Error::MissingCharacteristic("exchange write"))?;
        let _request_guard = self.request_lock.lock().await;
        let mut notifications = self.notifications.lock().await;

        while notifications.try_recv().is_ok() {}

        self.peripheral
            .write(write_characteristic, payload, WriteType::WithoutResponse)
            .await?;

        if !expect_response {
            return Ok(None);
        }

        let response = tokio::time::timeout(timeout, async {
            let mut raw = Vec::new();

            loop {
                let chunk = notifications
                    .recv()
                    .await
                    .ok_or(Error::NotificationStreamClosed)?;
                raw.extend_from_slice(&chunk);

                if let Some(decoded) = P::decode_response(&raw, &chunk) {
                    return Ok::<Vec<u8>, Error>(decoded);
                }
            }
        })
        .await
        .map_err(|_| Error::Timeout(timeout))??;

        Ok(Some(response))
    }

    async fn read(&self, characteristic: Uuid, timeout: Duration) -> Result<Vec<u8>> {
        let characteristic = self
            .characteristics
            .get(&characteristic)
            .ok_or(Error::MissingCharacteristic("read"))?;

        let data = tokio::time::timeout(timeout, self.peripheral.read(characteristic))
            .await
            .map_err(|_| Error::Timeout(timeout))??;

        Ok(data)
    }

    async fn write(&self, characteristic: Uuid, payload: &[u8], response: bool) -> Result<()> {
        let characteristic = self
            .characteristics
            .get(&characteristic)
            .ok_or(Error::MissingCharacteristic("write"))?;
        let write_type = if response {
            WriteType::WithResponse
        } else {
            WriteType::WithoutResponse
        };

        self.peripheral
            .write(characteristic, payload, write_type)
            .await?;

        Ok(())
    }

    async fn disconnect(&self) -> Result<()> {
        if self.peripheral.is_connected().await? {
            self.peripheral.disconnect().await?;
        }

        if let Some(task) = self.notification_task.lock().await.take() {
            task.abort();
        }

        Ok(())
    }
}

async fn first_adapter() -> Result<Adapter> {
    let manager = Manager::new().await?;
    manager
        .adapters()
        .await?
        .into_iter()
        .next()
        .ok_or(Error::NoBluetoothAdapters)
}

async fn scan_for_devices<P>(
    adapter: &Adapter,
    scan_timeout: Duration,
) -> Result<Vec<DiscoveredDevice>>
where
    P: BleProfile,
{
    adapter.start_scan(ScanFilter::default()).await?;
    tokio::time::sleep(scan_timeout).await;

    let peripherals = adapter.peripherals().await?;
    let mut devices = Vec::new();

    for peripheral in peripherals {
        let Some(properties) = peripheral.properties().await? else {
            continue;
        };

        if !P::matches_device(&properties) {
            continue;
        }

        devices.push(DiscoveredDevice {
            address: properties.address.to_string(),
            local_name: properties.local_name,
        });
    }

    devices.sort_by(|left, right| left.address.cmp(&right.address));
    devices.dedup_by(|left, right| left.address.eq_ignore_ascii_case(&right.address));

    Ok(devices)
}

async fn find_device<P>(
    adapter: &Adapter,
    address: Option<&str>,
    scan_timeout: Duration,
) -> Result<Peripheral>
where
    P: BleProfile,
{
    adapter.start_scan(ScanFilter::default()).await?;
    tokio::time::sleep(scan_timeout).await;

    let peripherals = adapter.peripherals().await?;
    let normalized_address = address.map(str::to_ascii_uppercase);

    for peripheral in peripherals {
        let Some(properties) = peripheral.properties().await? else {
            continue;
        };

        if !P::matches_device(&properties) {
            continue;
        }

        let matches_address = normalized_address
            .as_deref()
            .map(|wanted| properties.address.to_string().eq_ignore_ascii_case(wanted))
            .unwrap_or(true);

        if matches_address {
            return Ok(peripheral);
        }
    }

    Err(Error::DeviceNotFound)
}
