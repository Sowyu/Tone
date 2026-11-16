import Foundation
import Observation

/// Reads and writes JSON files in ~/Library/Application Support/Tone.
enum Storage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Tone", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

@MainActor @Observable
final class PresetStore {
    static let builtIn: [EQPreset] = [
        EQPreset(name: "Flat", eq: .flat),
        EQPreset(name: "Bass Boost", eq: EQSettings(bands: [6, 5.5, 4.5, 3, 1.5, 0, 0, 0, 0, 0])),
        EQPreset(name: "Bass Reducer", eq: EQSettings(bands: [-6, -5.5, -4.5, -3, -1.5, 0, 0, 0, 0, 0])),
        EQPreset(name: "Treble Boost", eq: EQSettings(bands: [0, 0, 0, 0, 0, 1, 2.5, 4, 5.5, 6])),
        EQPreset(name: "Vocal", eq: EQSettings(bands: [-2, -3, -3, 1, 3.5, 4, 3.5, 1.5, 0, -1])),
        EQPreset(name: "Loudness", eq: EQSettings(bands: [6, 4.5, 0, 0, -2, 0, -1, -4.5, 4.5, 1.5])),
    ]
    static let customName = "Custom"

    private(set) var custom: [EQPreset]

    init() {
        custom = Storage.load([EQPreset].self, from: "presets.json") ?? []
    }

    var all: [EQPreset] { Self.builtIn + custom }

    func preset(named name: String) -> EQPreset? { all.first { $0.name == name } }

    func isBuiltIn(_ name: String) -> Bool { Self.builtIn.contains { $0.name == name } }

    /// Saves (or overwrites) a custom preset. Built-in names are rejected.
    @discardableResult
    func save(name: String, eq: EQSettings) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isBuiltIn(name), name != Self.customName else { return false }
        if let index = custom.firstIndex(where: { $0.name == name }) {
            custom[index].eq = eq
        } else {
            custom.append(EQPreset(name: name, eq: eq))
        }
        persist()
        return true
    }

    func delete(_ name: String) {
        custom.removeAll { $0.name == name }
        persist()
    }

    func rename(_ name: String, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, preset(named: newName) == nil, let i = custom.firstIndex(where: { $0.name == name }) else { return }
        custom[i].name = newName
        persist()
    }

    private func persist() { Storage.save(custom, to: "presets.json") }
}

/// Per-app settings, pins, hidden apps, row order and app preferences.
struct PersistedState: Codable {
    var apps: [String: AppAudioSettings] = [:]
    var pinned: [String] = []
    var hidden: [String] = []
    var appOrder: [String] = []
    var nowPlayingOrder: [String] = []
    var names: [String: String] = [:]
    var overdriveLimit: Double = 2
    var iconStyle: MenuBarIconStyle = .speaker
    var openSections: [PopoverSection] = [.applications]
}

@MainActor @Observable
final class SettingsStore {
    var state: PersistedState { didSet { scheduleSave() } }
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init() {
        state = Storage.load(PersistedState.self, from: "settings.json") ?? PersistedState()
    }

    func settings(for key: String) -> AppAudioSettings { state.apps[key] ?? AppAudioSettings() }

    func update(_ key: String, _ change: (inout AppAudioSettings) -> Void) {
        var s = settings(for: key)
        change(&s)
        state.apps[key] = s
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self.map { Storage.save($0.state, to: "settings.json") } }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        saveWork?.cancel()
        Storage.save(state, to: "settings.json")
    }

    /// Returns `keys` sorted by the persisted order, appending unknown ones at the end.
    static func ordered(_ keys: [String], by order: [String]) -> [String] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return keys.enumerated().sorted { a, b in
            switch (rank[a.element], rank[b.element]) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Moves `key` to sit where `target` is in `visible`, then folds that into the full order.
    static func move(_ key: String, to target: String, visible: [String], order: [String]) -> [String] {
        var list = visible
        guard let from = list.firstIndex(of: key), let to = list.firstIndex(of: target), from != to else { return order }
        list.remove(at: from)
        list.insert(key, at: to)
        // Keep remembered positions of apps that aren't visible right now.
        return list + order.filter { !list.contains($0) }
    }
}
