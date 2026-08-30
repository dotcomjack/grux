import SwiftUI
import Contacts

// Contacts directory UI. Left: searchable list backed by ContactsService's
// in-memory cache. Right: detail card with emails, phones, organization,
// and the linked-voice-profiles affordance (SpeakerContactLinkStore) so a
// diarized meeting speaker can be attached to a real person in one click.
struct ContactsView: View {
    @ObservedObject private var service = ContactsService.shared
    @ObservedObject private var linkStore = SpeakerContactLinkStore.shared
    @ObservedObject private var speakerStore = SpeakerProfileStore.shared

    @State private var searchText = ""
    @State private var selection: String?
    @State private var showingEditor = false
    @State private var editingContact: GruxContact?
    @State private var toast: String?

    var body: some View {
        GruxListDetailScaffold(listWidth: 320) {
            listPane
        } detail: {
            detailPane
        }
        .task { await service.requestAccessAndLoad() }
        .sheet(isPresented: $showingEditor) {
            ContactEditorSheet(contact: editingContact) { message in
                showToast(message)
            }
        }
        .overlay(alignment: .top) {
            if let msg = toast {
                Text(msg)
                    .font(GruxType.caption)
                    .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s - 2)
                    .background(GruxTheme.accentPrimary.opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.top, GruxSpacing.m)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation { toast = nil }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if !service.accessGranted {
                permissionState
            } else if filteredContacts.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(filteredContacts) { contact in
                        contactRow(contact)
                            .tag(contact.id)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            GruxToolbar("Contacts") {
                Spacer()
                Text("\(service.contacts.count)")
                    .font(GruxType.caption.monospacedDigit())
                    .foregroundStyle(GruxTheme.textSecondary)
                    .padding(.horizontal, GruxSpacing.s).padding(.vertical, GruxSpacing.xs - 2)
                    .background(GruxTheme.accentPrimary.opacity(0.15))
                    .clipShape(Capsule())
                Button {
                    Task { await service.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(GruxType.caption)
                }
                .buttonStyle(.borderless)
                .help("Reload from the system address book")
                .disabled(!service.accessGranted || service.isLoading)
                Button {
                    editingContact = nil
                    showingEditor = true
                } label: {
                    Image(systemName: "plus")
                        .font(GruxType.caption)
                }
                .buttonStyle(.borderless)
                .help("New contact")
                .disabled(!service.accessGranted)
            }
            GruxSearchField(placeholder: "Search name, email, phone, org", text: $searchText)
                .padding(.horizontal, GruxSpacing.m)
                .padding(.bottom, GruxSpacing.s)
        }
    }

    private var filteredContacts: [GruxContact] {
        service.search(searchText, limit: 500)
    }

    private func contactRow(_ contact: GruxContact) -> some View {
        HStack(spacing: GruxSpacing.s) {
            avatar(contact, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.fullName)
                    .font(GruxType.body)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                if !contact.organization.isEmpty {
                    Text(contact.organization)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(1)
                } else if let email = contact.emails.first {
                    Text(email)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !linkStore.speakerProfileIds(for: contact.id).isEmpty {
                Image(systemName: "waveform")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.accentCo)
                    .help("Has linked voice profiles")
            }
        }
        .padding(.vertical, GruxSpacing.xs - 2)
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.isLoading {
            VStack(spacing: GruxSpacing.s) {
                Spacer()
                ProgressView()
                Text("Loading contacts")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            GruxEmptyState(
                icon: "person.crop.rectangle.stack",
                line: searchText.isEmpty ? "No contacts found." : "No matches for '\(searchText)'.",
                voiceHint: searchText.isEmpty ? "Grux, add a contact..." : nil,
                compact: true
            )
        }
    }

    @ViewBuilder
    private var permissionState: some View {
        if service.authorization == .notDetermined {
            GruxEmptyState(
                icon: "lock.shield",
                line: "Grux needs permission to read your contacts.",
                ctaTitle: "Grant access",
                ctaAction: { Task { await service.requestAccessAndLoad() } },
                iconColor: GruxTheme.warnAmber
            )
        } else {
            GruxEmptyState(
                icon: "lock.shield",
                line: "Contacts access is denied. Enable it for Grux in System Settings.",
                ctaTitle: "Open System Settings",
                ctaAction: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                        NSWorkspace.shared.open(url)
                    }
                },
                iconColor: GruxTheme.warnAmber
            )
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let id = selection, let contact = service.contact(withIdentifier: id) {
            ScrollView {
                detailCard(contact)
                    .padding(GruxSpacing.l)
            }
        } else {
            GruxEmptyState(
                icon: "person.crop.circle",
                line: "Select a contact"
            )
        }
    }

    private func detailCard(_ contact: GruxContact) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.l) {
            HStack(spacing: GruxSpacing.m) {
                avatar(contact, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.fullName)
                        .font(GruxType.title)
                        .foregroundStyle(GruxTheme.textPrimary)
                    if !contact.organization.isEmpty {
                        Text(contact.organization)
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textSecondary)
                    }
                }
                Spacer()
                Button("Edit") {
                    editingContact = contact
                    showingEditor = true
                }
                .controlSize(.small)
            }

            if !contact.emails.isEmpty {
                fieldSection(title: "Email", values: contact.emails, icon: "envelope.fill")
            }
            if !contact.phones.isEmpty {
                fieldSection(title: "Phone", values: contact.phones, icon: "phone.fill")
            }

            Divider().opacity(0.3)
            voiceProfileSection(contact)
        }
        .padding(GruxSpacing.l)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func fieldSection(title: String, values: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            GruxSectionLabel(title)
            ForEach(values, id: \.self) { value in
                HStack(spacing: GruxSpacing.s - 2) {
                    Image(systemName: icon)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                    Text(value)
                        .font(GruxType.body)
                        .foregroundStyle(GruxTheme.textPrimary)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                        showToast("Copied")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(GruxType.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
        }
    }

    // Linked voice profiles plus link suggestions. This is the bridge from
    // meeting diarization to the address book: enroll a speaker on the
    // Meetings tab, then attach that voice to a real contact here.
    private func voiceProfileSection(_ contact: GruxContact) -> some View {
        let linkedIds = linkStore.speakerProfileIds(for: contact.id)
        let linkedProfiles = linkedIds.compactMap { speakerStore.get(id: $0) }
        let suggestions = linkStore.suggestions(forContactNamed: contact.fullName)
        let unlinked = speakerStore.profiles.filter { !linkStore.isLinked(speakerProfileId: $0.id) }

        return VStack(alignment: .leading, spacing: GruxSpacing.s) {
            GruxSectionLabel("VOICE PROFILES")

            if linkedProfiles.isEmpty {
                Text("No voice profiles linked. Linking one lets meeting transcripts resolve this person's email and details automatically.")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(linkedProfiles) { profile in
                    HStack(spacing: GruxSpacing.s - 2) {
                        Image(systemName: "waveform")
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.accentCo)
                        Text(profile.name)
                            .font(GruxType.body)
                            .foregroundStyle(GruxTheme.textPrimary)
                        Text("\(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                        Spacer()
                        Button {
                            _ = linkStore.unlink(speakerProfileId: profile.id)
                            showToast("Unlinked \(profile.name)")
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(GruxType.caption)
                                .foregroundStyle(GruxTheme.destructiveRose)
                        }
                        .buttonStyle(.borderless)
                        .help("Unlink this voice profile")
                    }
                }
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: GruxSpacing.xs) {
                    Text("Suggested matches")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                    ForEach(suggestions) { s in
                        HStack(spacing: GruxSpacing.s - 2) {
                            Image(systemName: "sparkles")
                                .font(GruxType.caption)
                                .foregroundStyle(GruxTheme.warnAmber)
                            Text(s.speakerName)
                                .font(GruxType.caption)
                                .foregroundStyle(GruxTheme.textPrimary)
                            Spacer()
                            Button("Link") {
                                _ = linkStore.link(speakerProfileId: s.speakerProfileId, contactIdentifier: contact.id)
                                showToast("Linked \(s.speakerName)")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if !unlinked.isEmpty {
                Menu {
                    ForEach(unlinked) { profile in
                        Button(profile.name) {
                            _ = linkStore.link(speakerProfileId: profile.id, contactIdentifier: contact.id)
                            showToast("Linked \(profile.name)")
                        }
                    }
                } label: {
                    Label("Link a voice profile", systemImage: "link")
                        .font(GruxType.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else if speakerStore.profiles.isEmpty {
                Text("No enrolled speakers yet. Record a meeting, then enroll a speaker from its transcript.")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Avatar

    private func avatar(_ contact: GruxContact, size: CGFloat) -> some View {
        Group {
            if let data = contact.thumbnail, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(GruxTheme.iridescent)
                    Text(contact.initials)
                        .font(.system(size: size * 0.38, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// Create / edit sheet. Tight inputs per the app's scale: small controls, compact
// paddings, no chunky chrome. Editing applies name and organization in
// place and appends a new email or phone if one is typed.
private struct ContactEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contact: GruxContact?
    let onDone: (String) -> Void

    @State private var givenName = ""
    @State private var familyName = ""
    @State private var organization = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var saving = false
    @State private var errorMessage: String?

    private var isEditing: Bool { contact != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Text(isEditing ? "Edit Contact" : "New Contact")
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)

            HStack(spacing: GruxSpacing.s) {
                TextField("First name", text: $givenName)
                TextField("Last name", text: $familyName)
            }
            TextField("Organization", text: $organization)
            TextField(isEditing ? "Add email" : "Email", text: $email)
            TextField(isEditing ? "Add phone" : "Phone", text: $phone)

            if let errorMessage {
                Text(errorMessage)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.destructiveRose)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create") { save() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || givenName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(GruxSpacing.l)
        // Same shape as the other sheets: the shipped width becomes the ideal
        // and GruxLayout.sheetMax caps it, so a wider ask can never outgrow the
        // 840pt window floor and clip off both edges. The floor stays 340
        // rather than GruxLayout.sheetMin because this sheet ships narrower
        // than that token, and widening a panel that reads fine today is a
        // design call, not a layout fix.
        .frame(minWidth: 340, idealWidth: 340, maxWidth: GruxLayout.sheetMax)
        .onAppear {
            if let contact {
                givenName = contact.givenName
                familyName = contact.familyName
                organization = contact.organization
            }
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        let given = givenName.trimmingCharacters(in: .whitespaces)
        let family = familyName.trimmingCharacters(in: .whitespaces)
        let org = organization.trimmingCharacters(in: .whitespaces)
        let mail = email.trimmingCharacters(in: .whitespaces)
        let tel = phone.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                if let contact {
                    _ = try await ContactsService.shared.updateContact(
                        identifier: contact.id,
                        givenName: given,
                        familyName: family,
                        organization: org,
                        addEmail: mail.isEmpty ? nil : mail,
                        addPhone: tel.isEmpty ? nil : tel
                    )
                    onDone("Saved \(given)")
                } else {
                    let created = try await ContactsService.shared.createContact(
                        givenName: given,
                        familyName: family,
                        email: mail.isEmpty ? nil : mail,
                        phone: tel.isEmpty ? nil : tel,
                        organization: org.isEmpty ? nil : org
                    )
                    onDone("Created \(created.fullName)")
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}
