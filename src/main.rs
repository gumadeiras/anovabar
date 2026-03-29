use std::fs;
use std::process::ExitCode;
use std::time::Duration;

use anovabar::{
    AnovaMini, AnovaNano, AnovaOriginalPrecisionCooker, BleConnectOptions, DeviceStatus,
    DiscoveredDevice, MiniFullState, OriginalStartCookOptions, StartCookOptions, TemperatureUnit,
};
use clap::{Args, Parser, Subcommand, ValueEnum, error::ErrorKind};
use futures::future::BoxFuture;
use serde_json::Value;

#[derive(Debug, Parser)]
#[command(name = "anovabar")]
#[command(about = "Control supported Anova devices over BLE", version)]
struct Cli {
    #[command(subcommand)]
    command: TopLevelCommand,
}

#[derive(Debug, Subcommand)]
enum TopLevelCommand {
    /// Commands for Anova Nano devices.
    Nano(NanoArgs),
    /// Commands for Anova Mini / Gen 3 devices.
    Mini(MiniArgs),
    /// Commands for the original Anova Precision Cooker (A2/A3).
    Original(OriginalArgs),
}

#[derive(Debug, Args)]
struct NanoArgs {
    #[command(subcommand)]
    command: NanoCommand,
}

#[derive(Debug, Args)]
struct MiniArgs {
    #[command(subcommand)]
    command: MiniCommand,
}

#[derive(Debug, Args)]
struct OriginalArgs {
    #[command(subcommand)]
    command: OriginalCommand,
}

#[derive(Debug, Subcommand)]
enum NanoCommand {
    Scan(ScanArgs),
    Status(DeviceOptions),
    CurrentTemp(DeviceOptions),
    TargetTemp(DeviceOptions),
    Timer(DeviceOptions),
    Unit(DeviceOptions),
    FirmwareInfo(DeviceOptions),
    DeviceInfo(DeviceOptions),
    Start(DeviceOptions),
    Stop(DeviceOptions),
    SetUnit(SetUnitArgs),
    SetTemp(SetTempArgs),
    SetTimer(SetTimerArgs),
}

#[derive(Debug, Subcommand)]
enum MiniCommand {
    Scan(ScanArgs),
    SystemInfo(DeviceOptions),
    State(DeviceOptions),
    CurrentTemp(DeviceOptions),
    Timer(DeviceOptions),
    FullState(DeviceOptions),
    SetClock(DeviceOptions),
    SetUnit(SetUnitArgs),
    SetTemp(SetMiniTempArgs),
    Start(StartMiniCookArgs),
    Stop(DeviceOptions),
}

#[derive(Debug, Subcommand)]
enum OriginalCommand {
    Scan(ScanArgs),
    Status(DeviceOptions),
    Unit(DeviceOptions),
    CurrentTemp(DeviceOptions),
    TargetTemp(DeviceOptions),
    Timer(DeviceOptions),
    CookerId(DeviceOptions),
    Model(DeviceOptions),
    FirmwareVersion(DeviceOptions),
    ClearAlarm(DeviceOptions),
    SetUnit(SetUnitArgs),
    SetTemp(SetMiniTempArgs),
    SetTimer(SetTimerArgs),
    StartTimer(DeviceOptions),
    StopTimer(DeviceOptions),
    Start(StartOriginalCookArgs),
    Stop(DeviceOptions),
}

#[derive(Clone, Debug, Args)]
struct ScanArgs {
    /// Scan duration in seconds.
    #[arg(long, default_value_t = 5)]
    scan_timeout: u64,
}

#[derive(Clone, Debug, Args)]
struct DeviceOptions {
    /// Specific BLE address to connect to. If omitted, the first matching device is used.
    #[arg(long)]
    address: Option<String>,
    /// Scan duration in seconds when discovering devices.
    #[arg(long, default_value_t = 5)]
    scan_timeout: u64,
    /// Command timeout in seconds.
    #[arg(long, default_value_t = 10)]
    command_timeout: u64,
}

impl DeviceOptions {
    fn into_connect_options(self) -> BleConnectOptions {
        BleConnectOptions {
            address: self.address,
            scan_timeout: Duration::from_secs(self.scan_timeout),
            command_timeout: Duration::from_secs(self.command_timeout),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
enum TemperatureUnitArg {
    C,
    F,
}

impl From<TemperatureUnitArg> for TemperatureUnit {
    fn from(value: TemperatureUnitArg) -> Self {
        match value {
            TemperatureUnitArg::C => TemperatureUnit::Celsius,
            TemperatureUnitArg::F => TemperatureUnit::Fahrenheit,
        }
    }
}

#[derive(Debug, Args)]
struct SetUnitArgs {
    #[command(flatten)]
    device: DeviceOptions,
    #[arg(value_enum)]
    unit: TemperatureUnitArg,
}

#[derive(Debug, Args)]
struct SetTempArgs {
    #[command(flatten)]
    device: DeviceOptions,
    temperature: f32,
}

#[derive(Debug, Args)]
struct SetMiniTempArgs {
    #[command(flatten)]
    device: DeviceOptions,
    temperature: f64,
}

#[derive(Debug, Args)]
struct SetTimerArgs {
    #[command(flatten)]
    device: DeviceOptions,
    minutes: u32,
}

#[derive(Debug, Args)]
struct StartMiniCookArgs {
    #[command(flatten)]
    device: DeviceOptions,
    setpoint: f64,
    #[arg(long, default_value_t = 0)]
    timer_seconds: u64,
    #[arg(long, default_value = "menubar")]
    cookable_id: String,
    #[arg(long, default_value = "manual")]
    cookable_type: String,
}

#[derive(Debug, Args)]
struct StartOriginalCookArgs {
    #[command(flatten)]
    device: DeviceOptions,
    setpoint: f64,
    #[arg(long, default_value_t = 0)]
    timer_minutes: u32,
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            let code = match error.kind() {
                ErrorKind::DisplayHelp | ErrorKind::DisplayVersion => 0,
                _ => 2,
            };

            error.print().ok();
            write_launcher_exit_status(code);
            return ExitCode::from(code);
        }
    };

    let exit_status = match run(cli).await {
        Ok(()) => {
            write_launcher_exit_status(0);
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("error: {error}");
            write_launcher_exit_status(1);
            ExitCode::FAILURE
        }
    };

    exit_status
}

fn write_launcher_exit_status(code: u8) {
    let Ok(path) = std::env::var("ANOVABAR_EXIT_STATUS_PATH") else {
        return;
    };

    let _ = fs::write(path, format!("{code}\n"));
}

async fn run(cli: Cli) -> anovabar::Result<()> {
    match cli.command {
        TopLevelCommand::Nano(args) => run_nano(args).await,
        TopLevelCommand::Mini(args) => run_mini(args).await,
        TopLevelCommand::Original(args) => run_original(args).await,
    }
}

async fn run_nano(args: NanoArgs) -> anovabar::Result<()> {
    match args.command {
        NanoCommand::Scan(args) => {
            let devices = AnovaNano::discover(Duration::from_secs(args.scan_timeout)).await?;
            print_devices(&devices);
        }
        NanoCommand::Status(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    print_status(device.get_status().await?);
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::CurrentTemp(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    let snapshot = device.get_sensor_snapshot().await?;
                    print_temperature(
                        "current_temperature",
                        snapshot.water_temp.value,
                        snapshot.water_temp.unit,
                    );
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::TargetTemp(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    let unit = device.get_unit().await?;
                    let temperature = device.get_target_temperature().await?;
                    print_temperature("target_temperature", temperature, unit);
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::Timer(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    println!("timer_minutes={}", device.get_timer_minutes().await?);
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::Unit(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    println!("unit={}", device.get_unit().await?.as_symbol());
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::FirmwareInfo(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    let firmware = device.get_firmware_info().await?;
                    println!("commit_id={}", firmware.commit_id);
                    println!("tag_id={}", firmware.tag_id);
                    println!("date_code={}", firmware.date_code);
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::DeviceInfo(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    println!("raw_value={}", device.get_device_info().await?.raw_value);
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::Start(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    device.start().await?;
                    println!("started=true");
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::Stop(options) => {
            with_nano(options, |device| {
                Box::pin(async move {
                    device.stop().await?;
                    println!("stopped=true");
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::SetUnit(args) => {
            with_nano(args.device, |device| {
                Box::pin(async move {
                    let unit = TemperatureUnit::from(args.unit);
                    device.set_unit(unit).await?;
                    println!("unit={}", unit.as_symbol());
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::SetTemp(args) => {
            with_nano(args.device, |device| {
                Box::pin(async move {
                    device.set_target_temperature(args.temperature).await?;
                    println!("target_temperature={}", args.temperature);
                    Ok(())
                })
            })
            .await?;
        }
        NanoCommand::SetTimer(args) => {
            with_nano(args.device, |device| {
                Box::pin(async move {
                    device.set_timer_minutes(args.minutes).await?;
                    println!("timer_minutes={}", args.minutes);
                    Ok(())
                })
            })
            .await?;
        }
    }

    Ok(())
}

async fn run_mini(args: MiniArgs) -> anovabar::Result<()> {
    match args.command {
        MiniCommand::Scan(args) => {
            let devices = AnovaMini::discover(Duration::from_secs(args.scan_timeout)).await?;
            print_devices(&devices);
        }
        MiniCommand::SystemInfo(options) => {
            with_mini(options, |device| {
                Box::pin(async move {
                    print_json(&device.get_system_info().await?);
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::State(options) => {
            with_mini(options, |device| {
                Box::pin(async move {
                    print_json(&device.get_state().await?);
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::CurrentTemp(options) => {
            with_mini(options, |device| {
                Box::pin(async move {
                    print_json(&device.get_current_temperature().await?);
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::Timer(options) => {
            with_mini(options, |device| {
                Box::pin(async move {
                    print_json(&device.get_timer().await?);
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::FullState(options) => {
            with_mini(options, |device| {
                Box::pin(async move {
                    print_full_state(&device.get_full_state().await?);
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::SetClock(options) => {
            with_mini(options, |device| {
                Box::pin(async move {
                    device.set_clock_to_utc_now().await?;
                    println!("clock_synced=true");
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::SetUnit(args) => {
            with_mini(args.device, |device| {
                Box::pin(async move {
                    let unit = TemperatureUnit::from(args.unit);
                    device.set_unit(unit).await?;
                    println!("unit={}", unit.as_symbol());
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::SetTemp(args) => {
            with_mini(args.device, |device| {
                Box::pin(async move {
                    let full_state = device.get_full_state().await?;
                    let unit = full_state
                        .temperature_unit()
                        .unwrap_or(TemperatureUnit::Celsius);
                    validate_mini_setpoint(args.temperature, unit)?;
                    device.set_temperature(args.temperature).await?;
                    println!("setpoint={}", args.temperature);
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::Start(args) => {
            with_mini(args.device, |device| {
                Box::pin(async move {
                    let full_state = device.get_full_state().await?;
                    let unit = full_state
                        .temperature_unit()
                        .unwrap_or(TemperatureUnit::Celsius);
                    validate_mini_setpoint(args.setpoint, unit)?;
                    let mut options = StartCookOptions::new(args.setpoint);
                    options.timer_seconds = args.timer_seconds;
                    options.cookable_id = args.cookable_id;
                    options.cookable_type = args.cookable_type;
                    device.set_clock_to_utc_now().await?;
                    device.start_cook(options).await?;
                    confirm_mini_start(device, args.setpoint, args.timer_seconds).await?;
                    println!("started=true");
                    Ok(())
                })
            })
            .await?;
        }
        MiniCommand::Stop(options) => {
            with_mini(options, |device| {
                Box::pin(async move {
                    device.stop_cook().await?;
                    confirm_mini_stop(device).await?;
                    println!("stopped=true");
                    Ok(())
                })
            })
            .await?;
        }
    }

    Ok(())
}

async fn run_original(args: OriginalArgs) -> anovabar::Result<()> {
    match args.command {
        OriginalCommand::Scan(args) => {
            let devices =
                AnovaOriginalPrecisionCooker::discover(Duration::from_secs(args.scan_timeout))
                    .await?;
            print_devices(&devices);
        }
        OriginalCommand::Status(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!("status={}", device.status().await?);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::Unit(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!("unit={}", device.read_unit().await?.as_symbol());
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::CurrentTemp(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!("current_temperature={}", device.read_temperature().await?);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::TargetTemp(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!(
                        "target_temperature={}",
                        device.read_target_temperature().await?
                    );
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::Timer(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!("timer={}", device.read_timer().await?);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::CookerId(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!("cooker_id={}", device.get_cooker_id().await?);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::Model(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    let model = device.detect_model().await?;
                    println!("model={}", model.as_label());
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::FirmwareVersion(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!("firmware_version={}", device.firmware_version().await?);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::ClearAlarm(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    println!("clear_alarm={}", device.clear_alarm().await?);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::SetUnit(args) => {
            with_original(args.device, |device| {
                Box::pin(async move {
                    let unit = TemperatureUnit::from(args.unit);
                    device.set_unit(unit).await?;
                    println!("unit={}", unit.as_symbol());
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::SetTemp(args) => {
            with_original(args.device, |device| {
                Box::pin(async move {
                    device.set_temperature(args.temperature).await?;
                    println!("target_temperature={}", args.temperature);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::SetTimer(args) => {
            with_original(args.device, |device| {
                Box::pin(async move {
                    device.set_timer_minutes(args.minutes).await?;
                    println!("timer_minutes={}", args.minutes);
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::StartTimer(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    device.start_timer().await?;
                    println!("timer_started=true");
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::StopTimer(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    device.stop_timer().await?;
                    println!("timer_stopped=true");
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::Start(args) => {
            with_original(args.device, |device| {
                Box::pin(async move {
                    let mut options = OriginalStartCookOptions::new(args.setpoint);
                    options.timer_minutes = args.timer_minutes;
                    device.start_cook(options).await?;
                    println!("started=true");
                    Ok(())
                })
            })
            .await?;
        }
        OriginalCommand::Stop(options) => {
            with_original(options, |device| {
                Box::pin(async move {
                    device.stop_cook().await?;
                    println!("stopped=true");
                    Ok(())
                })
            })
            .await?;
        }
    }

    Ok(())
}

fn validate_mini_setpoint(value: f64, unit: TemperatureUnit) -> anovabar::Result<()> {
    let (min, max) = unit.supported_mini_setpoint_range();
    if (min..=max).contains(&value) {
        return Ok(());
    }

    Err(anovabar::Error::InvalidInput(format!(
        "Mini setpoint must be between {min:.1}{} and {max:.1}{}",
        unit.as_symbol(),
        unit.as_symbol()
    )))
}

async fn confirm_mini_start(
    device: &AnovaMini,
    setpoint: f64,
    timer_seconds: u64,
) -> anovabar::Result<()> {
    for attempt in 0..10 {
        sleep_for_mini_confirmation_attempt(attempt).await;
        let snapshot = device.get_full_state().await?;
        if mini_snapshot_matches_running(&snapshot, setpoint, timer_seconds) {
            return Ok(());
        }
    }

    Err(anovabar::Error::InvalidInput(format!(
        "mini cooker did not confirm a running state for setpoint {setpoint:.1} and timer {timer_seconds}s"
    )))
}

async fn confirm_mini_stop(device: &AnovaMini) -> anovabar::Result<()> {
    for attempt in 0..24 {
        sleep_for_mini_confirmation_attempt(attempt).await;
        let snapshot = device.get_full_state().await?;
        if mini_snapshot_matches_stopped(&snapshot) {
            return Ok(());
        }
    }

    Err(anovabar::Error::InvalidInput(
        "mini cooker did not confirm a stopped state".to_string(),
    ))
}

async fn sleep_for_mini_confirmation_attempt(attempt: usize) {
    const POLL_INTERVAL_MS: u64 = 350;

    if attempt > 0 {
        tokio::time::sleep(Duration::from_millis(POLL_INTERVAL_MS)).await;
    }
}

fn mini_snapshot_matches_running(
    snapshot: &MiniFullState,
    setpoint: f64,
    timer_seconds: u64,
) -> bool {
    let state_mode = snapshot
        .state
        .get("mode")
        .and_then(Value::as_str)
        .map(str::to_ascii_lowercase);
    let timer_mode = snapshot
        .timer
        .get("mode")
        .and_then(Value::as_str)
        .map(str::to_ascii_lowercase);

    let running = state_mode.as_deref().is_some_and(is_running_mode)
        || timer_mode.as_deref().is_some_and(is_running_mode);
    if !running {
        return false;
    }

    let target_matches = snapshot
        .state
        .get("setpoint")
        .and_then(Value::as_f64)
        .or_else(|| snapshot.current_temperature.get("setpoint").and_then(Value::as_f64))
        .is_none_or(|current| (current - setpoint).abs() <= 0.2);
    if !target_matches {
        return false;
    }

    if timer_seconds == 0 {
        return true;
    }

    snapshot
        .timer
        .get("remaining")
        .and_then(Value::as_u64)
        .or_else(|| snapshot.timer.get("timerSeconds").and_then(Value::as_u64))
        .or_else(|| snapshot.timer.get("initial").and_then(Value::as_u64))
        .is_some_and(|seconds| seconds > 0 && seconds <= timer_seconds)
}

fn mini_snapshot_matches_stopped(snapshot: &MiniFullState) -> bool {
    let state_mode = snapshot
        .state
        .get("mode")
        .and_then(Value::as_str)
        .map(str::to_ascii_lowercase);
    let timer_mode = snapshot
        .timer
        .get("mode")
        .and_then(Value::as_str)
        .map(str::to_ascii_lowercase);

    !state_mode.as_deref().is_some_and(is_running_mode)
        && !timer_mode.as_deref().is_some_and(is_running_mode)
}

fn is_running_mode(mode: &str) -> bool {
    matches!(mode, "cook" | "cooking" | "running" | "active")
}

async fn with_nano<F>(options: DeviceOptions, operation: F) -> anovabar::Result<()>
where
    F: for<'a> FnOnce(&'a AnovaNano) -> BoxFuture<'a, anovabar::Result<()>>,
{
    let device = AnovaNano::connect(options.into_connect_options()).await?;
    let result = operation(&device).await;
    // Best effort disconnect after the command completes.
    // If the command already failed, prefer its original error.
    let disconnect_result = device.disconnect().await;

    match (result, disconnect_result) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

async fn with_mini<F>(options: DeviceOptions, operation: F) -> anovabar::Result<()>
where
    F: for<'a> FnOnce(&'a AnovaMini) -> BoxFuture<'a, anovabar::Result<()>>,
{
    let device = AnovaMini::connect(options.into_connect_options()).await?;
    let result = operation(&device).await;
    let disconnect_result = device.disconnect().await;

    match (result, disconnect_result) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

async fn with_original<F>(options: DeviceOptions, operation: F) -> anovabar::Result<()>
where
    F: for<'a> FnOnce(&'a AnovaOriginalPrecisionCooker) -> BoxFuture<'a, anovabar::Result<()>>,
{
    let device = AnovaOriginalPrecisionCooker::connect(options.into_connect_options()).await?;
    let result = operation(&device).await;
    let disconnect_result = device.disconnect().await;

    match (result, disconnect_result) {
        (Err(error), _) => Err(error),
        (Ok(()), Err(error)) => Err(error),
        (Ok(()), Ok(())) => Ok(()),
    }
}

fn print_devices(devices: &[DiscoveredDevice]) {
    if devices.is_empty() {
        println!("devices_found=0");
        return;
    }

    for device in devices {
        match &device.local_name {
            Some(name) => println!("{} {}", device.address, name),
            None => println!("{}", device.address),
        }
    }
}

fn print_status(status: DeviceStatus) {
    let value = match status {
        DeviceStatus::Running => "running",
        DeviceStatus::Stopped => "stopped",
    };

    println!("status={value}");
}

fn print_temperature(label: &str, value: f32, unit: TemperatureUnit) {
    println!("{label}={value}{}", unit.as_symbol());
}

fn print_json(value: &Value) {
    println!(
        "{}",
        serde_json::to_string_pretty(value).expect("json serialization should succeed")
    );
}

fn print_full_state(state: &MiniFullState) {
    let json = Value::Object(
        [
            ("state".to_string(), state.state.clone()),
            (
                "currentTemperature".to_string(),
                state.current_temperature.clone(),
            ),
            ("timer".to_string(), state.timer.clone()),
        ]
        .into_iter()
        .collect(),
    );
    print_json(&json);
}
