import SwiftUI

struct SettingsView: View {
    @Environment(StationStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettings
    @State private var testResult: String?
    @State private var testing = false

    init(initial: AppSettings) {
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use demo data", isOn: $draft.demo)
                    TextField("192.168.11.20:8100", text: $draft.collectorAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(draft.demo)
                    SecureField("API token (optional)", text: $draft.token)
                        .disabled(draft.demo)
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(draft.demo || draft.collectorAddress.isEmpty || testing)
                    if let testResult {
                        Text(testResult).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Collector")
                } footer: {
                    Text("The address of the collector container on your network, e.g. 192.168.11.20:8100. To use the app away from home, put the collector and your devices on Tailscale and use its Tailscale address.")
                }

                Section("Display") {
                    Picker("Units", selection: $draft.units) {
                        ForEach(UnitSystem.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Station name", text: $draft.stationName)
                    Toggle("Keep screen on", isOn: $draft.keepScreenOn)
                }

                if let c = store.current, !store.isDemo {
                    Section("Station") {
                        LabeledContent("Signal", value: c.station.signalOk ? "OK" : "Not receiving")
                        if let r = c.station.rssi { LabeledContent("RSSI", value: "\(Int(r)) dBm") }
                        if let b = c.station.battery { LabeledContent("Station battery", value: String(format: "%.1f V", b)) }
                        if let tz = c.timezone { LabeledContent("Collector time zone", value: tz) }
                        if let clock = c.station.clock { LabeledContent("IP-100 clock", value: clock) }
                        if let fw = c.station.firmware { LabeledContent("IP-100 firmware", value: fw) }
                        ForEach(c.warnings ?? [], id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.yellow)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.apply(draft)
                        dismiss()
                    }
                }
            }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let source = try CollectorSource(address: draft.collectorAddress, token: draft.token)
            let c = try await source.current()
            if !c.online {
                testResult = "Connected to the collector, but it can't reach the IP-100: \(c.error ?? "unknown error")"
            } else if !c.station.signalOk {
                testResult = "Connected. The IP-100 isn't receiving the station right now."
            } else {
                let t = c.outside.temperature.map { String(format: "%.1f °F", $0) } ?? "–"
                testResult = "Connected. Outside temperature \(t)."
            }
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
        }
    }
}
