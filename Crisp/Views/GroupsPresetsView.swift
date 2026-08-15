import SwiftUI

// Groups, presets and schedules, in the panel's Settings section.
//
// Three collapsed rows and nothing else until one is opened. That is the whole
// design brief: this is a menu-bar panel someone opens to nudge a slider, not a
// control room, so a feature nobody has set up must cost exactly one line of
// height and no attention. Everything below follows the section idiom already in
// the panel — `ExpandableRow` header, rows indented under it, a subtitle that
// says how many of a thing there are so the row answers its own question without
// being opened.
//
// No decisions live here. Which member ends up at what brightness is
// `BrightnessSync`, what a preset may contain is `DDCPreset`, and whether a
// schedule is due is `ScheduleFiring` — all pure, all tested headlessly. This
// file's job is naming things and calling the three services.

// MARK: - Presets

/// Saved DDC snapshots: apply, save current as…, rename, delete.
struct PresetsSection: View {
    @ObservedObject private var presets = DDCPresetService.shared
    @EnvironmentObject var displayManager: DisplayManager
    @Binding var isExpanded: Bool

    /// Non-nil while the "save current as…" field is open, holding its text.
    @State private var newPresetName: String?
    /// The preset being renamed, and its in-progress name.
    @State private var renaming: (id: String, name: String)?

    private var subtitle: String {
        presets.presets.isEmpty
            ? String(localized: "None saved")
            : String(localized: "\(presets.presets.count) saved")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "square.stack.3d.up",
                iconColor: .purple,
                iconActive: !presets.presets.isEmpty,
                label: "Presets",
                subtitle: subtitle,
                isExpanded: $isExpanded
            )
            if isExpanded {
                ForEach(presets.presets) { preset in
                    presetRow(preset)
                }
                if let name = newPresetName {
                    NameField(
                        prompt: "Preset name",
                        text: name,
                        onCommit: { committed in
                            let displays = displayManager.displays.filter { !$0.isBuiltin }
                            presets.capture(name: committed, from: displays)
                            newPresetName = nil
                        },
                        onCancel: { newPresetName = nil },
                        onChange: { newPresetName = $0 }
                    )
                } else {
                    Button("Save Current as Preset…") {
                        newPresetName = String(localized: "New Preset")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.leading, 46)
                    .padding(.trailing, 12)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: DDCPreset) -> some View {
        if let renaming, renaming.id == preset.id {
            NameField(
                prompt: "Preset name",
                text: renaming.name,
                onCommit: { committed in
                    presets.rename(preset.id, to: committed)
                    self.renaming = nil
                },
                onCancel: { self.renaming = nil },
                onChange: { self.renaming = (id: preset.id, name: $0) }
            )
        } else {
            HStack(spacing: 8) {
                Button {
                    Task { await presets.apply(preset, origin: .panel) }
                } label: {
                    // Two lines rather than a name and a chevron: the count is
                    // what tells the user whether this preset still describes
                    // the desk they are at.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name).font(.callout)
                        Text("\(preset.displayCount) display(s)")
                            .font(.caption)
                            .foregroundColor(.secondaryReadable)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: preset.name))
                .accessibilityHint("Applies this preset")

                Spacer()

                if presets.applyingID == preset.id {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }

                Menu {
                    Button("Apply") {
                        Task { await presets.apply(preset, origin: .panel) }
                    }
                    Button("Save Current Here") {
                        presets.update(preset.id, from: displayManager.displays)
                    }
                    Button("Rename…") {
                        renaming = (id: preset.id, name: preset.name)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        presets.delete(preset.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Preset actions")
            }
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Groups

/// Named sets of displays whose brightness moves together.
struct DisplayGroupsSection: View {
    @ObservedObject private var groups = DisplayGroupService.shared
    @EnvironmentObject var displayManager: DisplayManager
    @Binding var isExpanded: Bool

    @State private var newGroupName: String?
    @State private var renaming: (id: String, name: String)?

    private var subtitle: String {
        groups.groups.isEmpty
            ? String(localized: "None")
            : String(localized: "\(groups.groups.count) group(s)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "rectangle.on.rectangle",
                iconColor: .teal,
                iconActive: !groups.groups.isEmpty,
                label: "Display Groups",
                subtitle: subtitle,
                isExpanded: $isExpanded
            )
            if isExpanded {
                ForEach(groups.groups) { group in
                    groupRow(group)
                }
                if let name = newGroupName {
                    NameField(
                        prompt: "Group name",
                        text: name,
                        onCommit: { committed in
                            // A new group starts with every external display in
                            // it: that is what "sync my monitors" means, and
                            // unticking one is easier than ticking three.
                            groups.createGroup(
                                name: committed,
                                members: displayManager.displays.filter { !$0.isBuiltin }.map(\.stateUUID)
                            )
                            newGroupName = nil
                        },
                        onCancel: { newGroupName = nil },
                        onChange: { newGroupName = $0 }
                    )
                } else {
                    Button("New Group…") {
                        newGroupName = String(localized: "New Group")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.leading, 46)
                    .padding(.trailing, 12)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: DisplayGroup) -> some View {
        if let renaming, renaming.id == group.id {
            NameField(
                prompt: "Group name",
                text: renaming.name,
                onCommit: { committed in
                    groups.rename(group.id, to: committed)
                    self.renaming = nil
                },
                onCancel: { self.renaming = nil },
                onChange: { self.renaming = (id: group.id, name: $0) }
            )
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(group.name).font(.callout)
                    Spacer()
                    Menu {
                        Button("Recapture Offsets") { groups.recaptureBaselines(group.id) }
                        Button("Rename…") { renaming = (id: group.id, name: group.name) }
                        Divider()
                        Button("Delete", role: .destructive) { groups.delete(group.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Group actions")
                }

                Picker("Brightness sync", selection: Binding(
                    get: { group.syncMode },
                    set: { groups.setSyncMode(group.id, to: $0) }
                )) {
                    Text("Keep offsets").tag(BrightnessSyncMode.relative)
                    Text("Same level").tag(BrightnessSyncMode.absolute)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()

                // Why the caption is worth the two lines it costs: "same level"
                // sounds obviously right and is usually wrong. Two panels'
                // percentages are not comparable — this fork's own BenQ is at a
                // normal room brightness on DDC 0.
                Text(group.syncMode == .relative
                     ? "Each display keeps the difference it had when you set the group up."
                     : "Every display goes to the same percentage, which can look wrong on mixed monitors.")
                    .font(.caption)
                    .foregroundColor(.secondaryReadable)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(displayManager.displays.filter { !$0.isBuiltin }) { display in
                    Toggle(isOn: Binding(
                        get: { group.members.contains(display.stateUUID) },
                        set: { groups.setMembership(group.id, display: display.stateUUID, isMember: $0) }
                    )) {
                        Text(display.name).font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
        }
    }
}

// MARK: - Schedules

/// Time-triggered presets.
struct SchedulesSection: View {
    @ObservedObject private var schedules = PresetScheduleService.shared
    @ObservedObject private var presets = DDCPresetService.shared
    @Binding var isExpanded: Bool

    /// The preset chosen in the "add" row, if any. Held here rather than added
    /// straight away so the user picks a time before anything is stored.
    @State private var draftPresetID: String?
    @State private var draftTime = Date()

    private var subtitle: String {
        let active = schedules.schedules.filter(\.enabled).count
        return active == 0
            ? String(localized: "None")
            : String(localized: "\(active) active")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "clock",
                iconColor: .indigo,
                iconActive: schedules.schedules.contains(where: \.enabled),
                label: "Schedules",
                subtitle: subtitle,
                isExpanded: $isExpanded
            )
            if isExpanded {
                if presets.presets.isEmpty {
                    Text("Save a preset first — a schedule applies one at a time of day.")
                        .font(.caption)
                        .foregroundColor(.secondaryReadable)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 46)
                        .padding(.trailing, 12)
                        .padding(.vertical, 3)
                } else {
                    ForEach(schedules.schedules) { schedule in
                        scheduleRow(schedule)
                    }
                    addRow
                }
            }
        }
    }

    private func scheduleRow(_ schedule: PresetSchedule) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { schedule.enabled },
                set: { schedules.setEnabled(schedule.id, $0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    // A schedule whose preset was deleted still shows, saying so:
                    // the time the user chose is worth more than tidiness, and
                    // the preset is often about to come back.
                    Text(schedules.preset(for: schedule)?.name ?? String(localized: "Missing preset"))
                        .font(.callout)
                    Text(verbatim: "\(schedule.trigger.at) · \(Self.daysLabel(schedule.trigger))")
                        .font(.caption)
                        .foregroundColor(.secondaryReadable)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            Button {
                schedules.delete(schedule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete schedule")
        }
        .padding(.leading, 46)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(presets.presets) { preset in
                    Button {
                        draftPresetID = preset.id
                    } label: {
                        Text(preset.name)
                    }
                }
            } label: {
                Text(draftPresetID.flatMap { id in presets.presets.first { $0.id == id }?.name }
                     ?? String(localized: "Choose preset"))
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Preset to schedule")

            DatePicker("At", selection: $draftTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()

            Spacer()

            Button("Add") {
                guard let presetID = draftPresetID, let trigger = Self.trigger(from: draftTime) else { return }
                schedules.add(presetID: presetID, trigger: trigger)
                draftPresetID = nil
            }
            .controlSize(.small)
            .disabled(draftPresetID == nil)
        }
        .padding(.leading, 46)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }

    /// The picked wall-clock time as the schedule's own trigger. Only the hour
    /// and minute are read: a `DatePicker` also carries today's date, and storing
    /// that would make the schedule mean one particular Tuesday.
    private static func trigger(from date: Date) -> ScheduleTrigger? {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute,
              let time = TimeOfDay(hour: hour, minute: minute) else { return nil }
        return ScheduleTrigger(at: time)
    }

    private static func daysLabel(_ trigger: ScheduleTrigger) -> String {
        trigger.isEveryDay
            ? String(localized: "every day")
            : String(localized: "\((trigger.days ?? []).count) day(s) a week")
    }
}

// MARK: - Shared

/// The inline "type a name" row used by presets and groups.
///
/// A field in the panel rather than a sheet: a menu-bar popover that opens a
/// window to ask for a string has lost the user's place, and every other naming
/// affordance in this app (the hotkey recorder, the calibration wizard) stays
/// inside the panel too.
private struct NameField: View {
    let prompt: LocalizedStringKey
    let text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    let onChange: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(prompt, text: Binding(get: { text }, set: onChange))
                // The placeholder is a literal at the call site, not here, so
                // the field carries a name of its own rather than relying on a
                // value the static gate cannot follow.
                .accessibilityLabel(Text(prompt))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.callout)
                .focused($isFocused)
                .onSubmit(commit)

            Button("Save", action: commit)
                .controlSize(.small)
                // An unnamed thing is not a thing anyone can find again in a
                // menu, so saving one is refused rather than auto-named.
                .disabled(trimmed.isEmpty)

            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.leading, 46)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .onAppear { isFocused = true }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
