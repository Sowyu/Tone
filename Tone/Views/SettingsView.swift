import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        @Bindable var store = model.store
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, isOn in
                        model.launchAtLogin = isOn
                        launchAtLogin = model.launchAtLogin
                    }
                if SMAppService.mainApp.status == .requiresApproval {
                    LabeledContent("Login item needs approval") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Picker("Menu bar icon", selection: $store.state.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label(style.title, systemImage: style.symbol).tag(style)
                    }
                }
            }

            Section {
                Picker("Maximum app volume", selection: $store.state.overdriveLimit) {
                    Text("100%").tag(1.0)
                    Text("125%").tag(1.25)
                    Text("150%").tag(1.5)
                    Text("200%").tag(2.0)
                }
            } footer: {
                Text("Above 100%, Tone limits peaks so the boosted sound doesn't distort.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Equalizer presets") {
                if model.presets.custom.isEmpty {
                    Text("Add presets from an app's Preset menu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.presets.custom) { preset in
                    LabeledContent {
                        Button("Rename") {
                            newName = preset.name
                            renaming = preset.name
                            nameFieldFocused = true
                        }
                        Button("Delete", role: .destructive) { model.presets.delete(preset.name) }
                    } label: {
                        if renaming == preset.name {
                            TextField("Preset Name", text: $newName)
                                .labelsHidden()
                                .focused($nameFieldFocused)
                                .onSubmit {
                                    model.presets.rename(preset.name, to: newName)
                                    renaming = nil
                                }
                                .onExitCommand { renaming = nil }
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }

            if !store.state.hidden.isEmpty {
                Section("Hidden apps") {
                    ForEach(store.state.hidden, id: \.self) { key in
                        LabeledContent(model.displayName(key)) {
                            Button("Show in Menu") { model.unhide(key) }
                        }
                    }
                }
            }

            Section("Permissions") {
                LabeledContent("System audio recording") {
                    switch model.permission.status {
                    case .authorized: Text("Allowed")
                    case .denied: Button("Open Privacy Settings…") { model.permission.openSystemSettings() }
                    case .unknown: Button("Allow…") { model.permission.request() }
                    }
                }
                LabeledContent {
                    switch model.nowPlaying.availability {
                    case .available, .starting: Text("Available")
                    case .missingTool, .failed: Text("Unavailable")
                    }
                } label: {
                    Text("Now Playing")
                    switch model.nowPlaying.availability {
                    case .available, .starting: EmptyView()
                    case .missingTool: Text("Install media-control with Homebrew, then reopen Tone.")
                    case .failed(let reason): Text(reason)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.permission.refresh() }
    }
}
