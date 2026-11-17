import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updates
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var renaming: String?
    @State private var newName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        @Bindable var store = model.store
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("Tone").font(.system(size: 17, weight: .semibold))
                Spacer()
                Link(destination: URL(string: "https://ko-fi.com/anikodev")!) {
                    Label("Donate on Ko-fi", systemImage: "cup.and.saucer")
                }
                .settingsAction()
            }

            SettingsSection(title: "General", symbol: "gearshape.fill") {
                SettingsRow(title: "Open at login") {
                    Toggle("Open at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, isOn in
                            model.launchAtLogin = isOn
                            launchAtLogin = model.launchAtLogin
                        }
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    SettingsRow(title: "Login item needs approval") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                SettingsRow(title: "Menu bar icon") {
                    Picker("Menu bar icon", selection: $store.state.iconStyle) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Label(style.title, systemImage: style.symbol).tag(style)
                        }
                    }
                    .labelsHidden()
                }
            }

            SettingsSection(title: "Volume", symbol: "speaker.wave.2.fill") {
                SettingsRow(title: "Maximum app volume",
                            detail: "Above 100%, Tone limits peaks so the boosted sound doesn't distort.") {
                    Picker("Maximum app volume", selection: $store.state.overdriveLimit) {
                        Text("100%").tag(1.0)
                        Text("125%").tag(1.25)
                        Text("150%").tag(1.5)
                        Text("200%").tag(2.0)
                        Text("300%").tag(3.0)
                        Text("400%").tag(4.0)
                        Text("500%").tag(5.0)
                    }
                    .labelsHidden()
                }
            }

            SettingsSection(title: "Equalizer presets", symbol: "slider.vertical.3") {
                if model.presets.custom.isEmpty {
                    Text("Add presets from an app's Preset menu.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 9)
                }
                ForEach(model.presets.custom) { preset in
                    if renaming == preset.name {
                        TextField("Preset Name", text: $newName)
                            .labelsHidden()
                            .focused($nameFieldFocused)
                            .onSubmit {
                                model.presets.rename(preset.name, to: newName)
                                renaming = nil
                            }
                            .onExitCommand { renaming = nil }
                            .padding(.vertical, 9)
                    } else {
                        SettingsRow(title: preset.name) {
                            HStack {
                                Button("Rename") {
                                    newName = preset.name
                                    renaming = preset.name
                                    nameFieldFocused = true
                                }
                                Button("Delete", role: .destructive) { model.presets.delete(preset.name) }
                            }
                        }
                    }
                }
            }

            if !store.state.hidden.isEmpty {
                SettingsSection(title: "Hidden apps", symbol: "eye.slash.fill") {
                    ForEach(store.state.hidden, id: \.self) { key in
                        SettingsRow(title: model.displayName(key)) {
                            Button("Show in Menu") { model.unhide(key) }
                        }
                    }
                }
            }

            SettingsSection(title: "Permissions", symbol: "hand.raised.fill") {
                SettingsRow(title: "System audio recording") {
                    switch model.permission.status {
                    case .authorized: Text("Allowed").foregroundStyle(.secondary)
                    case .denied: Button("Open Privacy Settings…") { model.permission.openSystemSettings() }
                    case .unknown: Button("Allow…") { model.permission.request() }
                    }
                }
                SettingsRow(title: "Now Playing", detail: nowPlayingDetail) {
                    switch model.nowPlaying.availability {
                    case .available, .starting: Text("Available").foregroundStyle(.secondary)
                    case .missingTool, .failed: Text("Unavailable").foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Version \(AppUpdate.installedVersion)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if updates.busy { ProgressView().controlSize(.small) }
                    if let update = updates.available {
                        Button { updates.install() } label: {
                            Label("Install Update \(update.version)…", systemImage: "arrow.down")
                        }
                        .settingsAction()
                        .disabled(updates.busy)
                    }
                    Button { updates.check(manual: true) } label: {
                        Label("Check for Updates…", systemImage: "arrow.clockwise")
                    }
                    .settingsAction()
                    .disabled(updates.busy)
                    .help("Checks daily and installs only when you choose.")
                }
                if !updates.status.isEmpty { SettingsFootnote(text: updates.status) }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: SettingsStyle.background))
        .onAppear { model.permission.refresh() }
    }

    private var nowPlayingDetail: String? {
        switch model.nowPlaying.availability {
        case .available, .starting: nil
        case .missingTool: "Install media-control with Homebrew, then reopen Tone."
        case .failed(let reason): reason
        }
    }
}
