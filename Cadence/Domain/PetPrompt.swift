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

    /// Checks the weather and says nothing most of the time.
    ///
    /// The command is named in the prompt rather than run behind the scenes:
    /// the first run asks to be allowed, once, and after that it is one of
    /// yours — visible under Allowed commands and revocable there.
    static let weather = PetPrompt(
        id: "weather",
        title: "Weather",
        prompt: "Use run_command with: curl -s 'wttr.in/PLACE?format=j1', "
            + "where PLACE is where I am — you were told above; write spaces "
            + "as +. Drop it only if you were not told.\n\n"
            + "Tell me only about something I would act on — rain arriving "
            + "before I go out, a severe alert, a big swing in temperature. "
            + "Not the forecast, and not that it is unchanged.",
        everyMinutes: 120
    )

    /// Earlier wordings of the shipped weather question, replaced on launch
    /// while they are still untouched. The first one named a URL with no place
    /// in it, so wttr.in answered by geolocating the connection and reported
    /// the exchange it came out of.
    static let supersededWeather: Set<String> = [
        "Use run_command with: curl -s 'wttr.in/?format=j1'\n\n"
            + "Tell me only about something I would act on — rain arriving "
            + "before I go out, a severe alert, a big swing in temperature. "
            + "Not the forecast, and not that it is unchanged."
    ]

    /// The feed is a starting point and meant to be replaced; what it is
    /// filtered *against* is the interesting part, and that lives in memory
    /// rather than here, because it is different for everybody.
    static let news = PetPrompt(
        id: "news",
        title: "News",
        prompt: "Use run_command with: curl -s "
            + "'https://feeds.bbci.co.uk/news/world/rss.xml'\n\n"
            + "First call search_memories for what I care about. Tell me only "
            + "what touches it, or what would change my plans. If nothing "
            + "does, say nothing — a headline I would not have looked up is "
            + "not worth interrupting me for.",
        everyMinutes: 240
    )

    static let defaults: [PetPrompt] = [planToday, weather, news]

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
