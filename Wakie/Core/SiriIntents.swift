//
//  SiriIntents.swift
//  Wakie
//
//  Siri / Shortcuts support: set, edit and delete Wakie alarms by voice.
//  Siri asks follow-up questions for anything required that wasn't said
//  (the time and the challenge); everything else uses the app's defaults.
//

import AppIntents
import Foundation

// MARK: - Challenge as a Siri-understandable value

nonisolated extension Mission: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Challenge"

    static let caseDisplayRepresentations: [Mission: DisplayRepresentation] = [
        .shakyShaky: DisplayRepresentation(title: "Shaky-Shaky", subtitle: "Dance to stop the alarm",
                                           synonyms: ["Shaky Shaky", "dance", "dancing"]),
        .pickiePicky: DisplayRepresentation(title: "Pickie-Picky", subtitle: "Find an item and show it",
                                            synonyms: ["Pickie Picky", "Picky Picky", "find", "object"]),
        .blahBlah: DisplayRepresentation(title: "Blah-Blah", subtitle: "Talk out loud",
                                         synonyms: ["Blah Blah", "talk", "talking", "speak"]),
    ]
}

// MARK: - Alarms as entities Siri can refer to

nonisolated struct AlarmEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Alarm"
    static let defaultQuery = AlarmEntityQuery()

    let id: UUID
    let time: String
    let details: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(time)", subtitle: "\(details)")
    }

    init(_ alarm: WakieAlarm) {
        id = alarm.id
        time = "\(alarm.timeText) \(alarm.periodText)"
        details = alarm.subtitle + (alarm.isEnabled ? "" : " · Off")
    }
}

nonisolated struct AlarmEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [AlarmEntity] {
        await MainActor.run {
            AppModel.shared.alarms.filter { identifiers.contains($0.id) }.map(AlarmEntity.init)
        }
    }

    func suggestedEntities() async throws -> [AlarmEntity] {
        await MainActor.run { AppModel.shared.sortedAlarms.map(AlarmEntity.init) }
    }
}

/// Hour and minute from a time Siri understood.
private nonisolated func clockParts(_ date: Date) -> (hour: Int, minute: Int) {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 7, parts.minute ?? 0)
}

// MARK: - Set an alarm

struct CreateAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Set a Wakie Alarm"
    static let description = IntentDescription("Sets an alarm that you turn off by completing a challenge.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Time", kind: .time,
               requestValueDialog: IntentDialog("What time should I set the alarm for?"))
    var time: Date

    @Parameter(title: "Challenge",
               requestValueDialog: IntentDialog("Which challenge do you want: Shaky-Shaky, Pickie-Picky or Blah-Blah?"))
    var mission: Mission

    static var parameterSummary: some ParameterSummary {
        Summary("Set an alarm for \(\.$time) with \(\.$mission)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (hour, minute) = clockParts(time)
        let alarm = WakieAlarm(hour: hour, minute: minute, mission: mission)
        let scheduled = await AppModel.shared.saveAndSchedule(alarm)
        guard scheduled else {
            return .result(dialog: "I saved the alarm, but Wakie isn't allowed to ring alarms yet. Open Wakie to allow it.")
        }
        return .result(dialog: "Done! Your \(alarm.timeText) \(alarm.periodText) \(mission.title) alarm is set.")
    }
}

// MARK: - Edit an alarm

struct EditAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Change a Wakie Alarm"
    static let description = IntentDescription("Changes the time or challenge of one of your alarms.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Alarm", requestValueDialog: IntentDialog("Which alarm do you want to change?"))
    var alarm: AlarmEntity

    @Parameter(title: "New Time", kind: .time)
    var time: Date?

    @Parameter(title: "New Challenge")
    var mission: Mission?

    static var parameterSummary: some ParameterSummary {
        Summary("Change \(\.$alarm)") {
            \.$time
            \.$mission
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard var stored = await MainActor.run(body: { AppModel.shared.alarms.first { $0.id == alarm.id } }) else {
            return .result(dialog: "I couldn't find that alarm.")
        }
        // If nothing to change was said, ask for the new time.
        var newTime = time
        if newTime == nil && mission == nil {
            newTime = try await $time.requestValue(IntentDialog("What time should it ring instead?"))
        }
        if let newTime {
            (stored.hour, stored.minute) = clockParts(newTime)
        }
        if let mission { stored.mission = mission }
        let updated = stored
        await AppModel.shared.saveAndSchedule(updated)
        return .result(dialog: "Updated. It now rings at \(updated.timeText) \(updated.periodText) with \(updated.mission.title).")
    }
}

// MARK: - Delete an alarm

struct DeleteAlarmIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete a Wakie Alarm"
    static let description = IntentDescription("Deletes one of your alarms.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Alarm", requestValueDialog: IntentDialog("Which alarm do you want to delete?"))
    var alarm: AlarmEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$alarm)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Deleting can't be undone, so confirm first.
        try await requestConfirmation(
            actionName: .custom(acceptLabel: "Delete", acceptAlternatives: ["Yes", "Remove"], denyLabel: "Keep", denyAlternatives: ["No"], destructive: true),
            dialog: IntentDialog("Delete your \(alarm.time) alarm?")
        )
        let id = alarm.id
        await MainActor.run { AppModel.shared.delete(id) }
        return .result(dialog: "Deleted your \(alarm.time) alarm.")
    }
}

// MARK: - Siri phrases

struct WakieShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateAlarmIntent(),
            phrases: [
                "Set an alarm in \(.applicationName)",
                "Set a \(.applicationName) alarm",
                "Wake me up with \(.applicationName)",
                "Set a \(\.$mission) alarm in \(.applicationName)",
            ],
            shortTitle: "Set Alarm",
            systemImageName: "alarm"
        )
        AppShortcut(
            intent: EditAlarmIntent(),
            phrases: [
                "Change my \(.applicationName) alarm",
                "Edit an alarm in \(.applicationName)",
                "Change \(\.$alarm) in \(.applicationName)",
            ],
            shortTitle: "Change Alarm",
            systemImageName: "pencil"
        )
        AppShortcut(
            intent: DeleteAlarmIntent(),
            phrases: [
                "Delete a \(.applicationName) alarm",
                "Remove an alarm in \(.applicationName)",
                "Delete \(\.$alarm) in \(.applicationName)",
            ],
            shortTitle: "Delete Alarm",
            systemImageName: "trash"
        )
    }
}
