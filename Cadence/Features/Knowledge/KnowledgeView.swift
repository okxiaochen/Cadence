import SwiftUI

/// What the assistant knows, where you can argue with it.
///
/// This lived under Settings, which was the wrong shape twice over. It is not a
/// setting — nothing here is a preference, it is the assistant's own account of
/// who you are, and the whole point of showing it is that the account can be
/// **wrong** and you are the only one who can say so. And it was buried behind
/// a gear icon, which is where you put things nobody opens; a picture of you
/// that nobody ever looks at goes stale silently and takes every answer drawn
/// from it with it.
///
/// Two lists rather than one, because they are read differently. You open a
/// memory to check whether it is still true about you. You open a skill to
/// check whether the steps are still right.
struct KnowledgeView: View {
    enum Shelf: String, CaseIterable, Identifiable {
        case memories, skills
        var id: String { rawValue }
        var title: String {
            switch self {
            case .memories: "About me"
            // "How things are done" is what it is, and truncates to "How
            // things are do…" at the sidebar's own width.
            case .skills: "Know-how"
            }
        }
        var symbolName: String {
            switch self {
            case .memories: "brain"
            case .skills: "list.bullet.rectangle"
            }
        }
    }

    @Binding var shelf: Shelf

    var body: some View {
        switch shelf {
        case .memories: MemoryList()
        case .skills: SkillList()
        }
    }
}

/// Two shelves, and deliberately nothing else.
///
/// The obvious sidebar here is a list of categories — preferences, projects,
/// interests. It was not built because the counts are small enough that
/// filtering to eleven rows out of thirty is work in exchange for nothing, and
/// a category list implies the categories are the point. They are not; whether
/// the thing is still true is the point.
struct KnowledgeSidebar: View {
    @Binding var shelf: KnowledgeView.Shelf

    var body: some View {
        List(KnowledgeView.Shelf.allCases, selection: $shelf) { shelf in
            Label(shelf.title, systemImage: shelf.symbolName)
                .tag(shelf)
        }
        .listStyle(.sidebar)
    }
}

struct MemoryList: View {
    @Environment(AppModel.self) private var model

    @State private var memories: [Memory] = []
    @State private var editing: Memory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What the assistant remembers")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(memories.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if memories.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing remembered yet.")
                        .foregroundStyle(.secondary)
                    Text("The assistant saves preferences, projects and constraints "
                         + "as it learns them.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(memories) { memory in
                        MemoryRow(memory: memory) { updated in
                            save(updated)
                        } onDelete: {
                            delete(memory)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("Memory is written directly, without review. Everything is "
                     + "editable here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Forget All", role: .destructive) { deleteAll() }
                    .controlSize(.small)
                    .disabled(memories.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        memories = (try? model.database.writer.read { db in try MemoryRepository.all(db) }) ?? []
    }

    private func save(_ memory: Memory) {
        try? model.database.writer.write { db in try MemoryRepository.upsert(db, memory) }
        reload()
    }

    private func delete(_ memory: Memory) {
        try? model.database.writer.write { db in _ = try MemoryRepository.delete(db, id: memory.id) }
        reload()
    }

    private func deleteAll() {
        try? model.database.writer.write { db in try db.execute(sql: "DELETE FROM memory") }
        reload()
    }
}

/// What the assistant has worked out about how things are done here.
///
/// Separate from Memory because the two are different in a way that matters
/// when you are looking at them: a memory is a fact about you, a skill is a
/// procedure, and the reason to open a skill is to check whether the steps are
/// still right.
struct SkillList: View {
    @Environment(AppModel.self) private var model

    @State private var skills: [Skill] = []
    @State private var forked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("How things are done here")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(skills.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if skills.isEmpty {
                VStack(spacing: 6) {
                    Text("No procedures yet.")
                        .foregroundStyle(.secondary)
                    Text("When the assistant works out how to read one of your "
                         + "tools, it writes down what worked so the next run "
                         + "does not start over.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(skills) { skill in
                        SkillRow(
                            skill: skill,
                            isForked: forked.contains(skill.id)
                        ) {
                            delete(skill)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            Text("Built-in procedures ship with Cadence and update with it. "
                 + "Editing one keeps your version until you delete it, which "
                 + "puts the shipped one back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        skills = (try? model.database.writer.read { db in
            try SkillRepository.all(db)
        }) ?? []
        forked = Set((try? model.database.writer.read { db in
            try SkillRepository.forkedFromBuiltIn(db)
        })?.map(\.id) ?? [])
    }

    private func delete(_ skill: Skill) {
        try? model.database.writer.write { db in
            _ = try SkillRepository.delete(db, id: skill.id)
        }
        reload()
    }
}

struct SkillRow: View {
    var skill: Skill
    var isForked: Bool
    var onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.title).font(.callout.weight(.medium))
                    // The line that is always loaded, so it is the line worth
                    // reading: it is what makes the assistant reach for this.
                    Text(skill.whenToUse)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                }

                Spacer(minLength: 0)

                if skill.isStale() {
                    Text("unverified")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.18), in: Capsule())
                }
                Text(skill.isBuiltIn ? "Built in" : skill.source)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)

                // A built-in has no stored row to remove; only an override or
                // something the assistant wrote can be deleted.
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(skill.isBuiltIn)
                .opacity(skill.isBuiltIn ? 0.25 : 1)
            }

            if isForked {
                Label("The version that ships with Cadence has been updated "
                      + "since you changed this one. Deleting yours restores it.",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if isExpanded {
                Text(skill.body.isEmpty ? "No steps recorded." : skill.body)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }
}

struct MemoryRow: View {
    @State var memory: Memory
    var onSave: (Memory) -> Void
    var onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { memory.pinned },
                    set: { memory.pinned = $0; onSave(memory) }
                )) {
                    Image(systemName: memory.pinned ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("Pinned memories are loaded in full every time")

                VStack(alignment: .leading, spacing: 1) {
                    Text(memory.title).font(.callout.weight(.medium))
                    Text(memory.summary).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Text(memory.categoryValue.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Summary", text: $memory.summary, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { onSave(memory) }
                    TextEditor(text: $memory.body)
                        .font(.caption)
                        .frame(minHeight: 60)
                        .border(.quaternary)
                    HStack {
                        Text("key: \(memory.id)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("updated \(Format.date(memory.updatedAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Button("Save") { onSave(memory) }
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 26)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Updates
