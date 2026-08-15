import AppIntents
import Foundation

// The preset, as Shortcuts sees it. `DisplayEntity`'s shape, for the same reason
// and with the same identity discipline: a saved shortcut stores the entity's
// `id`, so the id has to be the thing that survives — the preset's own stable
// identifier, which is also what `crisp://preset/<id>` and `crispctl preset
// apply` take.
//
// A preset the user has since deleted resolves to nothing, and `ApplyPresetIntent`
// refuses by name rather than running whichever preset happened to be first.

/// One saved DDC preset, addressable from Shortcuts.
struct PresetEntity: AppEntity, Identifiable {

    /// `DDCPreset.id`. Never an index into the list: reordering must not silently
    /// repoint a shortcut at a different preset.
    let id: String

    @Property(title: "Name")
    var name: String

    /// How many displays the preset names, including ones not attached right
    /// now — so the picker's subtitle does not change depending on the desk.
    @Property(title: "Displays")
    var displayCount: Int

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Preset")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(displayCount) display(s)")
    }

    static var defaultQuery: PresetEntityQuery { PresetEntityQuery() }

    init(id: String, name: String, displayCount: Int) {
        self.id = id
        self.name = name
        self.displayCount = displayCount
    }

    init(_ preset: DDCPreset) {
        self.init(id: preset.id, name: preset.name, displayCount: preset.displayCount)
    }
}

/// How Shortcuts finds presets: by the identifier a saved shortcut carries, and
/// by asking what exists right now when the user is picking one.
struct PresetEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [PresetEntity.ID]) async throws -> [PresetEntity] {
        let wanted = Set(identifiers)
        return DDCPresetService.shared.presets
            .filter { wanted.contains($0.id) }
            .map(PresetEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        DDCPresetService.shared.presets.map(PresetEntity.init)
    }
}
