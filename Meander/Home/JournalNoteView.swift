import SwiftUI

/// A journal entry as a slide in the album. Placeholder styling until the design reference lands.
struct JournalNoteView: View {
    let note: JournalNote

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if note.showsDate {
                Text(note.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.text(.footnote, weight: .medium))
                    .foregroundStyle(Color.meanderDark.opacity(0.6))
            }
            Text(note.text)
                .font(.journal(.title))
                .foregroundStyle(Color.meanderDark)
                .lineSpacing(6)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 140)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.paper)
        .accessibilityElement(children: .combine)
    }
}

/// Write or edit a journal entry, and choose where it sits among the photos.
struct JournalNoteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var note: JournalNote
    let isNew: Bool
    let onSave: (JournalNote) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $note.text)
                    .font(.journal(.title))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal)
                    .overlay(alignment: .topLeading) {
                        if note.text.isEmpty {
                            Text("What happened today?")
                                .font(.journal(.title))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 21)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                Divider()
                VStack(spacing: 12) {
                    Toggle("Show Date on Entry", isOn: $note.showsDate)
                    // The date places the entry among the photos, so it stays even when it isn't shown.
                    DatePicker("Date", selection: $note.date)
                }
                .font(.text(.body))
                .padding()
            }
            .canvas()
            .barTitle(isNew ? "New Journal Entry" : "Edit Journal Entry")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        note.text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(note)
                        dismiss()
                    }
                    .disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
