import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        @Bindable var store = model.store
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        model.launchAtLogin = on
                        launchAtLogin = model.launchAtLogin
                    }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Picker("Overdrive limit", selection: $store.state.overdriveLimit) {
                    Text("100% (off)").tag(1.0)
                    Text("125%").tag(1.25)
                    Text("150%").tag(1.5)
                    Text("200%").tag(2.0)
                }
                Picker("Menu bar icon", selection: $store.state.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Presets") {
                if model.presets.custom.isEmpty {
                    Text("Save an EQ as a preset from the Preset menu.").foregroundStyle(.secondary)
                }
                ForEach(model.presets.custom) { preset in
                    HStack {
                        if renaming == preset.name {
                            TextField("Name", text: $newName)
                                .onSubmit {
                                    model.presets.rename(preset.name, to: newName)
                                    renaming = nil
                                }
                        } else {
                            Text(preset.name)
                        }
                        Spacer()
                        Button("Rename") { renaming = preset.name; newName = preset.name }
                        Button(role: .destructive) { model.presets.delete(preset.name) } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete \(preset.name)")
                    }
                }
            }

            if !store.state.hidden.isEmpty {
                Section("Hidden apps") {
                    ForEach(store.state.hidden, id: \.self) { key in
                        HStack {
                            Text(model.displayName(key))
                            Spacer()
                            Button("Show") { model.unhide(key) }
                        }
                    }
                }
            }

            Section("Permissions") {
                LabeledContent("System Audio Recording") {
                    switch model.permission.status {
                    case .authorized: Text("Allowed").foregroundStyle(.green)
                    case .denied: Button("Open Privacy Settings") { model.permission.openSystemSettings() }
                    case .unknown: Button("Request Access") { model.permission.request() }
                    }
                }
                LabeledContent("Now Playing") {
                    switch model.nowPlaying.availability {
                    case .available, .starting: Text("Using media-control").foregroundStyle(.secondary)
                    case .missingTool: Text("brew install media-control").textSelection(.enabled).foregroundStyle(.secondary)
                    case .failed(let reason): Text(reason).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 480)
        .onAppear { model.permission.refresh() }
    }
}
