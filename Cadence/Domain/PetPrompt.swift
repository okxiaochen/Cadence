import Foundation

/// A saved thing to ask the assistant, shown as a button on the companion.
///
/// Buttons rather than features. What is worth asking depends entirely on what
/// somebody has connected and how they work — "check what I have missed" means
/// one thing with a ticket tracker attached and nothing at all without one — so
/// the app ships the way to ask rather than a fixed list of questions.
///
/// This is also what keeps the panel from growing a button per capability. A
/// new source becomes a new prompt, not a new control.
struct PetPrompt: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    /// What the button says. Short — it sits in a row two or three wide.
    var title: String
    /// What gets sent, verbatim.
    var prompt: String
    /// How often to ask it unprompted. Nil is a button and nothing more.
    ///
    /// This is what makes weather, share prices and news the same feature as
    /// each other, and the same feature as anything else somebody watches: a
    /// command they approved, a question about its output, and a cadence.
    /// Building three of them separately would have got three, and the fourth
    /// thing anybody cared about would still be missing.
    var everyMinutes: Int?
    /// When it last ran, so a four-hour cadence is not restarted by a relaunch.
    var lastRunAt: Date?

    var isScheduled: Bool { (everyMinutes ?? 0) > 0 }

    func isDue(now: Date = Date()) -> Bool {
        guard let everyMinutes, everyMinutes > 0 else { return false }
        guard let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= Double(everyMinutes) * 60
    }

    /// The one that works with nothing connected, so the row is not empty on a
    /// fresh install and the idea is visible without having to be explained.
    static let planToday = PetPrompt(
        id: "plan-today",
        title: "Plan today",
        prompt: "Plan the rest of my day from the tasks I already have. "
            + "Overdue first, use find_free_slots, and leave room."
    )

    static let defaults: [PetPrompt] = [planToday]

    /// The word a scheduled prompt answers with when there is nothing worth
    /// interrupting for.
    ///
    /// Something has to mean silence, or every cadence becomes a guarantee of
    /// noise — "the weather is unchanged" every two hours is how a companion
    /// stops being read. A word rather than an empty reply because an empty
    /// reply is indistinguishable from a failure.
    static let silence = "SKIP"

    static func isSilent(_ reply: String) -> Bool {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.uppercased().hasPrefix(silence)
    }

    var isUsable: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension Array where Element == PetPrompt {
    /// Stored as JSON in `UserDefaults` rather than as a plist array of
    /// dictionaries: one shape to read, and adding a field later does not need
    /// a migration of everybody's settings.
    static func decoded(from data: Data?) -> [PetPrompt] {
        guard let data, let decoded = try? JSONDecoder().decode([PetPrompt].self, from: data)
        else { return PetPrompt.defaults }
        return decoded
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }
}
