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

    /// The one that is actually companionship rather than a service.
    ///
    /// Weather and news are the same shape as each other: fetch something, tell
    /// me if it matters. This one fetches nothing. Its whole input is what the
    /// assistant has learned about the person, which makes it the only prompt
    /// here that cannot be written by somebody who has just installed the app —
    /// it is worth nothing on day one and more every week after.
    ///
    /// The rule that keeps it honest is "name the thing you know". Without it a
    /// model asked to say something personal produces flattery — "thought you
    /// might enjoy" — which is indistinguishable from a horoscope and reads as
    /// one. Forced to cite the memory it is acting on, it either has a reason
    /// or falls silent.
    static let somethingPersonal = PetPrompt(
        id: "something-personal",
        // Short because the row is four capsules wide at 300pt and the fourth
        // one falls off the end otherwise — into a horizontal scroll view with
        // no indicator, which is the same as not being there. It also happens
        // to be what you would actually say to somebody: not a command for a
        // report, an opening.
        title: "Anything?",
        prompt: "Call search_memories for what I am interested in, what I keep "
            + "coming back to, and anything I said I wanted to do.\n\n"
            + "Say one thing that follows from something you actually know "
            + "about me. Something I would want to hear — a thought about a "
            + "thing I care about, a question about something I mentioned and "
            + "never came back to, a connection between two things I have said. "
            + "Talk to me like somebody who has been paying attention.\n\n"
            + "Name the thing you know — \"you said in March you wanted to see "
            + "it\", never \"I thought you might like\".\n\n"
            + "This is not about my schedule. Do not plan anything, do not "
            + "suggest how to fill my time, and do not tell me what I should be "
            + "doing. No small talk, and nothing I could have got from a search "
            + "engine. If nothing you know about me is worth saying right now, "
            + "reply SKIP.",
        everyMinutes: 240
    )

    static let defaults: [PetPrompt] = [planToday, weather, news, somethingPersonal]

    /// What shipped before questions were recorded one id at a time. Frozen: it
    /// is a record of what a particular old flag meant, not a list to keep up
    /// to date, and adding to it would re-offer a question somebody deleted.
    static let originalDefaultIDs: Set<String> = ["plan-today", "weather", "news"]

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
        guard !trimmed.isEmpty else { return true }

        // Models decorate. `**SKIP**`, `"SKIP"`, `> SKIP` and `SKIP.` are the
        // same answer as a bare one, and the ones that got through unstripped
        // were shown to the user as a message reading "SKIP" — which is the
        // single most confusing thing a companion can say.
        let bare = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_`\"'#>.-— \n\t"))
        if bare.uppercased().hasPrefix(silence) { return true }

        // And they preface. "Nothing worth reporting — SKIP" is silence with a
        // note about itself attached, and the note is not for anybody.
        //
        // Bounded by length so a real remark that happens to mention the word
        // is not swallowed, and deliberately **case-sensitive**: the prompt
        // asks for the token, so "I would skip the gym today" is a sentence and
        // "SKIP" is an answer.
        return bare.count <= 80 && bare.contains(silence)
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
