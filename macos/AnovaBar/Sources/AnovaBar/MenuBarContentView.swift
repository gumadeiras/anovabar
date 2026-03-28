import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingDeviceDetails = false

    var body: some View {
        Group {
            if model.connectedDevice == nil {
                disconnectedBody
            } else {
                connectedBody
            }
        }
        .frame(width: 392)
        .alert("Bluetooth Error", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
        }
        .task {
            await model.loadIfNeeded()
        }
    }

    private var disconnectedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            compactHeader
            discoveryPanel
            footerRow
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var connectedBody: some View {
        Group {
            if showingDeviceDetails {
                deviceDetailsBody
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    identityPanel
                    readingsPanel
                    controlsPanel
                    diagnosticsPanel
                    footerRow
                }
                .padding(12)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.95, green: 0.60, blue: 0.14), Color(red: 0.84, green: 0.43, blue: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: model.menuBarIconName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("AnovaBar")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.statusMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if model.connectedDevice != nil {
                Text("Live")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .panelBackground()
    }

    private var discoveryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.devices.isEmpty ? "Nearby Minis" : "Choose a Mini")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Button(model.isScanning ? "Scanning…" : "Scan") {
                    Task {
                        await model.scan()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Color(red: 0.88, green: 0.43, blue: 0.14))
                .disabled(model.isScanning || model.isBusy)
            }

            if model.devices.isEmpty {
                Text("Bluetooth permission or pairing may appear on first scan.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                pickerRow

                HStack {
                    Text("Names are saved per device.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Connect") {
                        Task {
                            await model.connectSelectedDevice()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(Color(red: 0.88, green: 0.43, blue: 0.14))
                    .disabled(model.selectedDeviceID == nil || model.isBusy)
                }
            }
        }
        .padding(12)
        .panelBackground()
    }

    private var identityPanel: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.95, green: 0.60, blue: 0.14), Color(red: 0.84, green: 0.43, blue: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: model.menuBarIconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

            Text(model.connectedDeviceTitle)
                .font(.system(size: 15, weight: .semibold))

            Spacer(minLength: 0)

            iconButton(systemName: "arrow.clockwise", help: "Refresh") {
                Task {
                    await model.refresh()
                }
            }

            iconButton(systemName: "slider.horizontal.3", help: "Device details and naming") {
                showingDeviceDetails = true
            }

            iconButton(systemName: "power", help: "Disconnect") {
                showingDeviceDetails = false
                Task {
                    await model.disconnect()
                }
            }
        }
        .padding(12)
        .panelBackground(
            colors: [
                Color.white.opacity(0.07),
                Color(red: 0.25, green: 0.16, blue: 0.09).opacity(0.60),
            ]
        )
    }

    private var readingsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Readings")
                .font(.system(size: 13, weight: .semibold))

            valueRow(title: "Current", value: model.snapshot?.currentTemperatureDisplay ?? "Loading…")
            valueRow(title: "Target", value: model.targetDisplayText)
            valueRow(title: "Timer", value: model.timerDisplayText)
        }
        .padding(12)
        .panelBackground()
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Controls")
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 0)

                Picker(
                    "Unit",
                    selection: Binding(
                        get: { model.selectedUnit },
                        set: { newUnit in
                            let previousUnit = model.selectedUnit
                            guard previousUnit != newUnit else {
                                return
                            }
                            model.selectedUnit = newUnit
                            Task {
                                await model.applyUnitChange(to: newUnit, previousUnit: previousUnit)
                            }
                        }
                    )
                ) {
                    ForEach(MiniTemperatureUnit.allCases) { unit in
                        Text(unit.symbol)
                            .tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 118)
            }

            HStack(spacing: 10) {
                Text("Setpoint")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)

                TextField("", text: $model.targetTemperatureText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button("Set") {
                    Task {
                        await model.applySetTemperature()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 13, weight: .semibold))
            }

            HStack(spacing: 10) {
                Text("Timer")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)

                TextField("", text: $model.timerMinutesText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("min")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button("Set") {
                    Task {
                        await model.applyTimer()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 13, weight: .semibold))
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Stop") {
                    Task {
                        await model.stopCook()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 13, weight: .semibold))

                Button("Start Cook") {
                    Task {
                        await model.startCook()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 13, weight: .semibold))
                .tint(Color(red: 0.88, green: 0.43, blue: 0.14))
            }
        }
        .disabled(model.isBusy)
        .padding(12)
        .panelBackground()
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup("System Info") {
                ScrollView {
                    Text(model.systemInfoText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .frame(maxHeight: 88)
            }

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.vertical, 8)

            DisclosureGroup("Raw Readings") {
                ScrollView {
                    Text(model.rawReadingsText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .frame(maxHeight: 96)
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .panelBackground()
    }

    private var footerRow: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var deviceDetailsBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Device Details")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.connectedDeviceTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done") {
                    showingDeviceDetails = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let device = model.connectedDevice {
                detailRow(title: "Name", value: device.name)
                detailRow(title: "UUID", value: device.identifier)
            }

            renameRow

            footerRow
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pickerRow: some View {
        HStack(spacing: 10) {
            Text("Device")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            Picker(
                "Device",
                selection: Binding(
                    get: { model.selectedDeviceID },
                    set: { model.selectDevice($0) }
                )
            ) {
                ForEach(model.devices) { device in
                    Text(model.label(for: device))
                        .tag(Optional(device.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var renameRow: some View {
        HStack(spacing: 10) {
            Text("Name")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            TextField("Kitchen Mini", text: $model.aliasText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button("Save") {
                model.saveAlias()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Clear") {
                model.clearAlias()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .disabled(model.selectedDeviceID == nil && model.connectedDevice == nil)
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.lastError != nil },
            set: { newValue in
                if !newValue {
                    model.lastError = nil
                }
            }
        )
    }
}

private extension View {
    func panelBackground(colors: [Color] = [Color.white.opacity(0.07), Color.white.opacity(0.03)]) -> some View {
        background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
