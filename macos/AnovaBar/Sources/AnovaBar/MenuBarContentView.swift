import AppKit
import SwiftUI

struct MenuBarContentView: View {
    enum UI {
        static let width: CGFloat = 336
        static let panelSpacing: CGFloat = 10
        static let panelPadding: CGFloat = 12
        static let rowLabelWidth: CGFloat = 74
        static let controlFieldWidth: CGFloat = 118
        static let controlInputCharacterLimit = 6
        static let settingsActionWidth: CGFloat = 50
        static let unitPickerWidth: CGFloat = 118
        static let headerIconButtonSize: CGFloat = 26
        static let headerIconGlyphSize: CGFloat = 13
        static let accent = Color(red: 0.88, green: 0.43, blue: 0.14)
        static let iconGradient = [
            Color(red: 0.95, green: 0.60, blue: 0.14),
            Color(red: 0.84, green: 0.43, blue: 0.08),
        ]
    }

    @ObservedObject var model: AppModel
    @State private var showingDeviceDetails = false

    var body: some View {
        content
            .frame(width: UI.width)
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
            .onChange(of: model.connectedDevice?.id) { newValue in
                if newValue == nil {
                    showingDeviceDetails = false
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.connectedDevice == nil {
            disconnectedBody
        } else {
            connectedBody
        }
    }

    private var disconnectedBody: some View {
        VStack(alignment: .leading, spacing: UI.panelSpacing) {
            compactHeader
            discoveryPanel
            footerRow
        }
        .padding(UI.panelPadding)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var connectedBody: some View {
        if showingDeviceDetails {
            deviceDetailsBody
        } else {
            VStack(alignment: .leading, spacing: UI.panelSpacing) {
                identityPanel
                readingsPanel
                controlsPanel
                if model.isDebugEnabled {
                    diagnosticsPanel
                }
                footerRow
            }
            .padding(UI.panelPadding)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var compactHeader: some View {
        HStack(spacing: UI.panelSpacing) {
            brandIcon(size: 34, symbolSize: 17)

            VStack(alignment: .leading, spacing: 2) {
                Text("AnovaBar")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.statusMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private var discoveryPanel: some View {
        VStack(alignment: .leading, spacing: UI.panelSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.devices.isEmpty ? "Nearby Minis" : "Choose a Mini")
                    .sectionTitle()

                Spacer()

                Button(action: asyncAction(model.scan)) {
                    ZStack {
                        Text("Scanning…")
                            .hidden()
                        Text(model.isScanning ? "Scanning…" : (model.hasCompletedScan ? "Rescan" : "Scan"))
                    }
                }
                    .prominentActionButton()
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

                    Button("Connect", action: asyncAction(model.connectSelectedDevice))
                        .prominentActionButton()
                        .disabled(model.selectedDeviceID == nil || model.isBusy)
                }
            }
        }
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private var identityPanel: some View {
        HStack(spacing: UI.panelSpacing) {
            brandIcon(size: 28, symbolSize: 14)

            Text(model.connectedDeviceTitle)
                .font(.system(size: 15, weight: .semibold))

            Spacer(minLength: 0)

            iconButton(systemName: "arrow.clockwise", help: "Refresh", action: asyncAction(model.refresh))
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
        .padding(UI.panelPadding)
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
                .sectionTitle()

            valueRow(title: "Current", value: model.currentDisplayText)
            valueRow(title: "Target", value: model.targetDisplayText)
            valueRow(title: "Timer", value: model.timerDisplayText)
        }
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: UI.panelSpacing) {
            HStack {
                Text("Controls")
                    .sectionTitle()

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
                .frame(width: UI.unitPickerWidth)
            }

            editableRow(label: "Temp (\(model.selectedUnit.symbol))") {
                TextField("", text: limitedText($model.targetTemperatureText))
                    .fieldStyle()

                Button("Set", action: asyncAction(model.applySetTemperature))
                    .actionButton()
            }

            editableRow(label: "Timer (min)") {
                TextField("", text: limitedText($model.timerMinutesText))
                    .fieldStyle()

                Button("Set", action: asyncAction(model.applyTimer))
                    .actionButton()
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Stop", action: asyncAction(model.stopCook))
                    .actionButton()
                    .disabled(!model.canStopCook)

                Button("Start Cook", action: asyncAction(model.startCook))
                    .primaryActionButton()
                    .disabled(!model.canStartCook)
            }
        }
        .disabled(model.isBusy)
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            diagnosticDisclosure("System Info", text: model.systemInfoText, maxHeight: 88)

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.vertical, 8)

            diagnosticDisclosure("BLE Trace", text: model.bleTraceText, maxHeight: 132)

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.vertical, 8)

            diagnosticDisclosure("BLE Payloads", text: model.rawReadingsText, maxHeight: 112)
        }
        .font(.system(size: 13))
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private var footerRow: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .actionButton()

            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var deviceDetailsBody: some View {
        VStack(alignment: .leading, spacing: UI.panelSpacing) {
            settingsHeader

            if let device = model.connectedDevice {
                deviceInfoPanel(device: device)
            }

            renamePanel
            debugPanel
            footerRow
        }
        .padding(UI.panelPadding)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pickerRow: some View {
        HStack(spacing: UI.panelSpacing) {
            Text("Device")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: UI.rowLabelWidth, alignment: .leading)

            Menu {
                ForEach(model.devices) { device in
                    Button {
                        model.selectDevice(device.id)
                    } label: {
                        HStack {
                            Text(model.label(for: device))
                            if model.selectedDeviceID == device.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(selectedDeviceMenuTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionFieldStyle()
        }
    }

    private var selectedDeviceMenuTitle: String {
        if let selectedID = model.selectedDeviceID,
           let selectedDevice = model.devices.first(where: { $0.id == selectedID }) {
            return model.label(for: selectedDevice)
        }

        return "Select a device"
    }

    private func valueRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UI.panelSpacing) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: UI.rowLabelWidth, alignment: .leading)

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func editableRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: UI.panelSpacing) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: UI.rowLabelWidth, alignment: .trailing)

            content()
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .top, spacing: UI.panelSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Device Details")
                    .font(.system(size: 18, weight: .bold))
                Text("Review device identity and customize its saved display name.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button("Done") {
                showingDeviceDetails = false
            }
            .actionButton()
        }
    }

    private func deviceInfoPanel(device: MiniDiscoveredDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                brandIcon(size: 26, symbolSize: 13)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.connectedDeviceTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text("Connected device")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                detailField(title: "Device Name", value: device.name)
                detailField(title: "UUID", value: device.identifier, monospaced: true)
            }
        }
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private var renamePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Display Name")
                .sectionTitle()

            Text("Use a custom label for this specific device. It appears in the picker and header.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                TextField("Kitchen Mini", text: $model.aliasText)
                    .settingsFieldStyle()
                    .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Button {
                        model.clearAlias()
                    } label: {
                        Text("Clear")
                            .frame(width: UI.settingsActionWidth)
                    }
                    .actionButton()

                    Button {
                        model.saveAlias()
                    } label: {
                        Text("Save")
                            .frame(width: UI.settingsActionWidth)
                    }
                    .prominentActionButton()
                }
            }
        }
        .disabled(model.selectedDeviceID == nil && model.connectedDevice == nil)
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: UI.panelSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Mode")
                        .sectionTitle()
                    Text("Show System Info, BLE Trace, and BLE Payloads in the main view.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Toggle(
                    "Debug Mode",
                    isOn: Binding(
                        get: { model.isDebugEnabled },
                        set: { model.setDebugEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
                .tint(UI.accent)
            }
        }
        .padding(UI.panelPadding)
        .panelBackground()
    }

    private func detailField(title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)

            Group {
                if monospaced {
                    Text(value)
                        .font(.system(size: 13, design: .monospaced))
                } else {
                    Text(value)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func diagnosticDisclosure(_ title: String, text: String, maxHeight: CGFloat) -> some View {
        DisclosureGroup(title) {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
            .frame(maxHeight: maxHeight)
        }
    }

    private func brandIcon(size: CGFloat, symbolSize: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.35, style: .continuous)
            .fill(
                LinearGradient(
                    colors: UI.iconGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: model.menuBarIconName)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: UI.headerIconGlyphSize, weight: .semibold))
                .frame(width: UI.headerIconGlyphSize, height: UI.headerIconGlyphSize, alignment: .center)
                .frame(width: UI.headerIconButtonSize, height: UI.headerIconButtonSize, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(AppButtonStyle(variant: .icon))
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

    private func asyncAction(_ action: @escaping @MainActor () async -> Void) -> () -> Void {
        {
            Task {
                await action()
            }
        }
    }

    private func limitedText(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { text.wrappedValue = String($0.prefix(UI.controlInputCharacterLimit)) }
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

    func fieldStyle() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13))
            .frame(width: MenuBarContentView.UI.controlFieldWidth)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func settingsFieldStyle() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 14))
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func selectionFieldStyle() -> some View {
        buttonStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    func actionButton() -> some View {
        buttonStyle(AppButtonStyle(variant: .secondary))
    }

    func prominentActionButton() -> some View {
        buttonStyle(AppButtonStyle(variant: .prominent))
    }

    func primaryActionButton() -> some View {
        prominentActionButton()
    }

    func sectionTitle() -> some View {
        font(.system(size: 13, weight: .semibold))
    }
}

private enum AppButtonVariant {
    case secondary
    case prominent
    case icon
}

private struct AppButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let variant: AppButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        let metrics = Self.metrics(for: variant)

        configuration.label
            .font(.system(size: metrics.fontSize, weight: .semibold))
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(backgroundFill(isPressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                            .strokeBorder(borderColor(isPressed: configuration.isPressed), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.48)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .prominent:
            return .white.opacity(isPressed ? 0.92 : 0.98)
        case .secondary, .icon:
            return .white.opacity(isPressed ? 0.88 : 0.96)
        }
    }

    private func backgroundFill(isPressed: Bool) -> LinearGradient {
        switch variant {
        case .prominent:
            return LinearGradient(
                colors: isPressed
                    ? [
                        MenuBarContentView.UI.accent.opacity(0.88),
                        Color(red: 0.72, green: 0.34, blue: 0.09).opacity(0.84),
                    ]
                    : [
                        MenuBarContentView.UI.accent,
                        Color(red: 0.72, green: 0.34, blue: 0.09),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary, .icon:
            return LinearGradient(
                colors: isPressed
                    ? [
                        Color.white.opacity(0.16),
                        Color.white.opacity(0.09),
                    ]
                    : [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.05),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        switch variant {
        case .prominent:
            return Color.white.opacity(isPressed ? 0.12 : 0.10)
        case .secondary, .icon:
            return Color.white.opacity(isPressed ? 0.16 : 0.10)
        }
    }

    private static func metrics(for variant: AppButtonVariant) -> (horizontalPadding: CGFloat, verticalPadding: CGFloat, cornerRadius: CGFloat, fontSize: CGFloat) {
        switch variant {
        case .secondary:
            return (10, 6, 10, 13)
        case .prominent:
            return (12, 7, 10, 13)
        case .icon:
            return (0, 0, 9, 13)
        }
    }
}
