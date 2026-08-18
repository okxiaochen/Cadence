import Foundation

/// Who the companion is, as against what it can do.
///
/// Everything else about the assistant is a capability — it can find a slot, it
/// can read a feed, it can remember that you dislike morning meetings. None of
/// that is company. What makes something company is that it sounds like
/// somebody, and sounds like the *same* somebody tomorrow.
///
/// The character is a **voice, never a behaviour**. That line is enforced in the
/// prompt rather than trusted to the wording of each persona, because it is the
/// failure that would matter: a blunt character that decides the user does not
/// need to be told about a conflict has stopped being a character and started
/// being a bug. Tone is the whole of what this changes.
///
/// `dailyRemarks` lives here rather than in settings because how much somebody
/// talks is not a preference about them, it *is* them. A quiet character with a
/// chatty slider is neither.
struct Persona: Identifiable, Codable, Hashable {

    /// Stable across launches and across app versions: it is what
    /// `Preferences.personaID` points at, and renaming one would silently move
    /// somebody onto a different character.
    var id: String
    var name: String
    /// One line, shown beside the name when choosing. What it is like to live
    /// with this one — not a list of adjectives.
    var tagline: String
    /// The paragraph handed to the model, written in the second person.
    ///
    /// Each of the built-ins carries at least one *negative* rule — something
    /// this character does not do. That is the part that actually moves a
    /// model's register; "be warm and friendly" produces the same assistant
    /// voice every model already defaults to, whereas "never two questions at
    /// once" is audible from the first reply.
    var voice: String
    /// How many unprompted remarks a day this one has in it.
    ///
    /// Counted against what actually gets *said*, not what gets checked — see
    /// `ScheduledPrompts`. A character that spends its budget staying silent
    /// about the weather has nothing left for the thing worth saying.
    var dailyRemarks: Int
    /// Set only on a copy, to the built-in it was made from. Lets the editor
    /// say what this started as, and lets "reset" mean something.
    var basedOn: String?

    var isBuiltIn: Bool { Persona.builtIns.contains { $0.id == id } }

    var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !voice.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A copy somebody can edit. Built-ins are code, so they cannot be written
    /// to; customising one means taking a copy under a new id and pointing at
    /// that, exactly as an overridden `Skill` does.
    func copyForEditing() -> Persona {
        Persona(
            id: UUID().uuidString,
            name: "\(name) (yours)",
            tagline: tagline,
            voice: voice,
            dailyRemarks: dailyRemarks,
            basedOn: isBuiltIn ? id : basedOn
        )
    }

    // MARK: - The ones that ship

    /// Four, differing along the two axes anybody actually notices: how much
    /// they say, and whether they are looking at the work or at you.
    static let builtIns: [Persona] = [mo, pip, sable, yuna]

    static let mo = Persona(
        id: "mo",
        name: "Mo",
        tagline: "Says little, and means it.",
        voice: """
        You are Mo. You have sat beside this person long enough to know when \
        not to speak. Short sentences. No exclamation marks, no opening \
        pleasantries, and never a summary of what you just did. You state the \
        thing and stop. When you disagree you say so once, plainly, and then \
        let it go. Warmth from you is accuracy: you show you were paying \
        attention by getting the detail right, not by saying that you care.
        """,
        dailyRemarks: 2
    )

    static let pip = Persona(
        id: "pip",
        name: "Pip",
        tagline: "Wants to know how it went.",
        voice: """
        You are Pip, and you are openly curious about this person's life. You \
        ask short follow-up questions about things they mentioned before — not \
        to be useful, but because you want to know how it turned out. You are \
        warm and a little informal, and you use their own words back at them. \
        You never ask two questions at once, and you drop a thread the moment \
        they do not pick it up.
        """,
        dailyRemarks: 6
    )

    static let sable = Persona(
        id: "sable",
        name: "Sable",
        tagline: "Will tell you when you are stalling.",
        voice: """
        You are Sable. You are fond of this person and completely unwilling to \
        flatter them. Dry, brief, and willing to name the thing they are \
        avoiding — once, without repeating it and without moralising. You never \
        put a compliment in front of bad news to soften it. When they do \
        something well you say so in four words and move on, which from you \
        means a great deal.
        """,
        dailyRemarks: 3
    )

    static let yuna = Persona(
        id: "yuna",
        name: "Yuna",
        tagline: "Notices when you have not moved.",
        voice: """
        You are Yuna, and you pay more attention to the person than to the \
        backlog. You notice the hour, the sitting, the third late night this \
        week, and you mention it gently and without instructing. You never \
        chain a piece of care to a piece of work — "have some water, and by the \
        way you are behind" is two things, and you say only the first. You are \
        calm; nothing you say carries urgency.
        """,
        dailyRemarks: 4
    )

    static let fallback = mo

    // MARK: - Prompt rendering

    /// The character, plus the one rule that keeps it a character.
    ///
    /// The rule is not optional and not per-persona: a voice that can decline
    /// to mention a clash, or round a time off because precision is out of
    /// character, has become a defect wearing a name.
    var promptSection: String {
        """
        \(voice.trimmingCharacters(in: .whitespacesAndNewlines))

        Your character is how you speak. It is never what you do. It does not \
        change a time, a fact, or a decision, and it is never a reason to keep \
        back something they need to know — a cat with opinions about tone still \
        reads the calendar correctly. Where the two pull against each other, \
        the fact wins and you say it in your own voice.
        """
    }
}

extension Array where Element == Persona {
    /// JSON in `UserDefaults`, the same shape `PetPrompt` uses: one thing to
    /// read, and a field added later needs no migration of anybody's settings.
    static func decodedPersonas(from data: Data?) -> [Persona] {
        guard let data, let decoded = try? JSONDecoder().decode([Persona].self, from: data)
        else { return [] }
        return decoded
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }
}
