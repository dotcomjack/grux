import Foundation
import Contacts

// Lightweight value snapshot of a CNContact. Keeps the UI and Claude tools
// decoupled from the Contacts framework's reference types so cached lists
// stay cheap to diff and safe to pass across actors.
struct GruxContact: Identifiable, Equatable, Sendable {
    let id: String                  // CNContact.identifier
    var givenName: String
    var familyName: String
    var organization: String
    var emails: [String]
    var phones: [String]
    var thumbnail: Data?

    var fullName: String {
        let joined = [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !joined.isEmpty { return joined }
        if !organization.isEmpty { return organization }
        return emails.first ?? "Unnamed"
    }

    var initials: String {
        let parts = [givenName, familyName].filter { !$0.isEmpty }
        if parts.isEmpty {
            return String(fullName.prefix(1)).uppercased()
        }
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    init(id: String, givenName: String, familyName: String, organization: String = "",
         emails: [String] = [], phones: [String] = [], thumbnail: Data? = nil) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.emails = emails
        self.phones = phones
        self.thumbnail = thumbnail
    }

    init(_ contact: CNContact) {
        self.id = contact.identifier
        self.givenName = contact.givenName
        self.familyName = contact.familyName
        self.organization = contact.organizationName
        self.emails = contact.emailAddresses.map { String($0.value) }
        self.phones = contact.phoneNumbers.map { $0.value.stringValue }
        self.thumbnail = contact.thumbnailImageData
    }
}

enum ContactsServiceError: LocalizedError {
    case accessDenied
    case notFound(String)
    case mutationFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Contacts access is not authorized. Grant it in System Settings, Privacy and Security, Contacts."
        case .notFound(let id):
            return "No contact with identifier \(id)."
        case .mutationFailed(let why):
            return "Contact save failed: \(why)"
        }
    }
}

// CNContactStore wrapper. Holds an in-memory cache of every contact (name,
// emails, phones, organization, thumbnail) so search stays instant and the
// Claude tools never block on a full enumeration. First access triggers the
// TCC grant; CNContactStoreDidChange keeps the cache fresh after external
// edits (iCloud sync, Contacts.app).
@MainActor
final class ContactsService: ObservableObject {
    static let shared = ContactsService()

    @Published private(set) var contacts: [GruxContact] = []
    @Published private(set) var authorization: CNAuthorizationStatus =
        CNContactStore.authorizationStatus(for: .contacts)
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var changeObserver: NSObjectProtocol?

    private init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                if ContactsService.shared.authorization == .authorized {
                    await ContactsService.shared.refresh()
                }
            }
        }
    }

    // MARK: - Access

    var accessGranted: Bool { authorization == .authorized }

    // Request access if undetermined, then report whether we can read.
    // Never re-prompts after a denial; callers surface the System Settings
    // deep link instead.
    @discardableResult
    func ensureAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        authorization = status
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
            authorization = CNContactStore.authorizationStatus(for: .contacts)
            return granted
        default:
            return false
        }
    }

    // Lazy first load: prompt if needed, then populate the cache once.
    func requestAccessAndLoad() async {
        guard await ensureAccess() else { return }
        if contacts.isEmpty { await refresh() }
    }

    // MARK: - Fetch

    func refresh() async {
        guard accessGranted else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Task.detached(priority: .userInitiated) {
                try Self.fetchAllContacts()
            }.value
            contacts = fetched
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func contact(withIdentifier id: String) -> GruxContact? {
        contacts.first { $0.id == id }
    }

    // In-memory search across name, emails, phones, and organization.
    // Name hits rank above email hits, which rank above org/phone hits.
    func search(_ query: String, limit: Int = 25) -> [GruxContact] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(contacts.prefix(limit)) }
        let scored: [(GruxContact, Int)] = contacts.compactMap { c in
            let name = c.fullName.lowercased()
            if name.hasPrefix(q) { return (c, 4) }
            if name.contains(q) { return (c, 3) }
            if c.emails.contains(where: { $0.lowercased().contains(q) }) { return (c, 2) }
            if c.organization.lowercased().contains(q) { return (c, 1) }
            if c.phones.contains(where: { $0.replacingOccurrences(of: " ", with: "").contains(q) }) { return (c, 1) }
            return nil
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.fullName.localizedCaseInsensitiveCompare(rhs.0.fullName) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.0 }
    }

    // MARK: - Mutations

    @discardableResult
    func createContact(givenName: String, familyName: String, email: String? = nil,
                       phone: String? = nil, organization: String? = nil) async throws -> GruxContact {
        guard await ensureAccess() else { throw ContactsServiceError.accessDenied }
        let created = try await Task.detached(priority: .userInitiated) {
            try Self.performCreate(
                given: givenName, family: familyName,
                email: email, phone: phone, organization: organization
            )
        }.value
        upsertCache(created)
        return created
    }

    // Update name and organization in place; append a new email or phone if
    // not already present. Nil fields are left untouched.
    @discardableResult
    func updateContact(identifier: String, givenName: String? = nil, familyName: String? = nil,
                       organization: String? = nil, addEmail: String? = nil,
                       addPhone: String? = nil) async throws -> GruxContact {
        guard await ensureAccess() else { throw ContactsServiceError.accessDenied }
        let updated = try await Task.detached(priority: .userInitiated) {
            try Self.performUpdate(
                identifier: identifier, given: givenName, family: familyName,
                organization: organization, addEmail: addEmail, addPhone: addPhone
            )
        }.value
        upsertCache(updated)
        return updated
    }

    private func upsertCache(_ contact: GruxContact) {
        if let idx = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[idx] = contact
        } else {
            contacts.append(contact)
            contacts.sort {
                $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
            }
        }
    }

    // MARK: - Framework plumbing (off main actor)

    nonisolated private static var fetchKeys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
            CNContactThumbnailImageDataKey
        ].map { $0 as CNKeyDescriptor }
    }

    nonisolated private static func fetchAllContacts() throws -> [GruxContact] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: fetchKeys)
        request.unifyResults = true
        var out: [GruxContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            out.append(GruxContact(contact))
        }
        out.sort { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        return out
    }

    nonisolated private static func performCreate(given: String, family: String, email: String?,
                                                  phone: String?, organization: String?) throws -> GruxContact {
        let contact = CNMutableContact()
        contact.givenName = given
        contact.familyName = family
        if let organization, !organization.isEmpty {
            contact.organizationName = organization
        }
        if let email, !email.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        if let phone, !phone.isEmpty {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))]
        }
        let store = CNContactStore()
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw ContactsServiceError.mutationFailed(error.localizedDescription)
        }
        if let saved = try? store.unifiedContact(withIdentifier: contact.identifier, keysToFetch: fetchKeys) {
            return GruxContact(saved)
        }
        return GruxContact(contact)
    }

    nonisolated private static func performUpdate(identifier: String, given: String?, family: String?,
                                                  organization: String?, addEmail: String?,
                                                  addPhone: String?) throws -> GruxContact {
        let store = CNContactStore()
        let existing: CNContact
        do {
            existing = try store.unifiedContact(withIdentifier: identifier, keysToFetch: fetchKeys)
        } catch {
            throw ContactsServiceError.notFound(identifier)
        }
        guard let mutable = existing.mutableCopy() as? CNMutableContact else {
            throw ContactsServiceError.mutationFailed("could not make contact mutable")
        }
        if let given { mutable.givenName = given }
        if let family { mutable.familyName = family }
        if let organization { mutable.organizationName = organization }
        if let addEmail, !addEmail.isEmpty {
            let alreadyHas = mutable.emailAddresses.contains {
                String($0.value).caseInsensitiveCompare(addEmail) == .orderedSame
            }
            if !alreadyHas {
                mutable.emailAddresses.append(CNLabeledValue(label: CNLabelHome, value: addEmail as NSString))
            }
        }
        if let addPhone, !addPhone.isEmpty {
            let normalized = addPhone.filter { $0.isNumber }
            let alreadyHas = mutable.phoneNumbers.contains {
                $0.value.stringValue.filter { $0.isNumber } == normalized
            }
            if !alreadyHas {
                mutable.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: addPhone)))
            }
        }
        let request = CNSaveRequest()
        request.update(mutable)
        do {
            try store.execute(request)
        } catch {
            throw ContactsServiceError.mutationFailed(error.localizedDescription)
        }
        if let reloaded = try? store.unifiedContact(withIdentifier: identifier, keysToFetch: fetchKeys) {
            return GruxContact(reloaded)
        }
        return GruxContact(mutable)
    }
}
