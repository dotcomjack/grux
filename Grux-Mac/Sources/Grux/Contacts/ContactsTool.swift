import Foundation

// Claude-tool adapter for the contacts directory. Parallel to SpeakerTool:
// thin switch into ContactsService plus SpeakerContactLinkStore so lookups
// surface linked voice profiles inline.
enum ContactsTool {

    static let toolNames: Set<String> = ["lookup_contact", "create_contact"]

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "lookup_contact",
                description: "Search the user's macOS Contacts by name, email, phone, or organization. Returns matching contacts with emails, phones, organization, and any linked voice profiles (enrolled meeting speakers). Use when they ask 'what's Sarah's email', 'do I have a contact for X', or when an email or meeting needs a recipient resolved.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Name, email fragment, phone fragment, or organization to search for."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max results to return. Default 5."
                        ]
                    ],
                    "required": ["query"]
                ]
            ),
            ClaudeTool(
                name: "create_contact",
                description: "Create a new contact in the user's macOS Contacts. Use when they say 'add X to my contacts' or after a meeting introduces someone new they want saved. Triggers the system Contacts permission prompt on first use.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Full display name, e.g. 'Sarah Chen'. First token becomes the given name, the rest the family name."
                        ],
                        "email": [
                            "type": "string",
                            "description": "Optional email address."
                        ],
                        "phone": [
                            "type": "string",
                            "description": "Optional phone number."
                        ],
                        "organization": [
                            "type": "string",
                            "description": "Optional company or organization name."
                        ]
                    ],
                    "required": ["name"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "lookup_contact":
            guard let rawQuery = input["query"] as? String,
                  !rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "error: 'query' is required and must be non-empty"
            }
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = max(1, min((input["limit"] as? Int) ?? 5, 25))

            let granted = await ContactsService.shared.ensureAccess()
            guard granted else {
                return "error: Contacts access not authorized. Grant it in System Settings, Privacy and Security, Contacts."
            }
            if await ContactsService.shared.contacts.isEmpty {
                await ContactsService.shared.refresh()
            }
            let hits = await ContactsService.shared.search(query, limit: limit)
            if hits.isEmpty {
                return "(no contacts matching '\(query)')"
            }
            var lines: [String] = []
            for c in hits {
                lines.append(await formatContact(c))
            }
            return lines.joined(separator: "\n")

        case "create_contact":
            guard let rawName = input["name"] as? String,
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "error: 'name' is required and must be non-empty"
            }
            let fullName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = fullName.split(separator: " ").map(String.init)
            let given = parts.first ?? fullName
            let family = parts.dropFirst().joined(separator: " ")
            let email = (input["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = (input["phone"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let organization = (input["organization"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            do {
                let created = try await ContactsService.shared.createContact(
                    givenName: given,
                    familyName: family,
                    email: (email?.isEmpty == false) ? email : nil,
                    phone: (phone?.isEmpty == false) ? phone : nil,
                    organization: (organization?.isEmpty == false) ? organization : nil
                )
                var summary = "ok: created contact id=\(created.id) name=\(created.fullName)"
                if !created.emails.isEmpty { summary += " email=\(created.emails.joined(separator: ", "))" }
                if !created.phones.isEmpty { summary += " phone=\(created.phones.joined(separator: ", "))" }
                if !created.organization.isEmpty { summary += " org=\(created.organization)" }
                return summary
            } catch {
                return "error: \(error.localizedDescription)"
            }

        default:
            return "error: unknown contacts tool '\(name)'"
        }
    }

    // One contact as a single result line, with linked voice profiles
    // resolved to names so Claude can connect meetings to people.
    @MainActor
    private static func formatContact(_ c: GruxContact) -> String {
        var fields: [String] = ["- id=\(c.id)", c.fullName]
        if !c.organization.isEmpty { fields.append(c.organization) }
        if !c.emails.isEmpty { fields.append("emails: \(c.emails.joined(separator: ", "))") }
        if !c.phones.isEmpty { fields.append("phones: \(c.phones.joined(separator: ", "))") }
        let linkedIds = SpeakerContactLinkStore.shared.speakerProfileIds(for: c.id)
        if !linkedIds.isEmpty {
            let names = linkedIds.compactMap { SpeakerProfileStore.shared.get(id: $0)?.name }
            if !names.isEmpty {
                fields.append("linked voices: \(names.joined(separator: ", "))")
            }
        }
        return fields.joined(separator: " · ")
    }
}
