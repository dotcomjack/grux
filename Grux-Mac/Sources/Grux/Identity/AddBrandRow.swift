import SwiftUI

/// "Add a brand", the one way into the brand-scoped rows (Phase C, C12). Meta
/// Ads and Social appear in the rail only once a brand exists, so a fresh
/// install would never learn they are there unless something names the door.
/// Onboarding's Connections step and Settings both show this row.
struct AddBrandRow: View {
    @State private var name = ""
    @State private var brands: [String] = BrandRoster.labelsOnDisk()
    @State private var message: String?

    static let title = "Add a brand"
    static let purpose = "Selling something under a name? Add it, and Meta Ads and Social appear for it in the sidebar."
    static func addedCopy(_ label: String) -> String {
        "Added \(label). Meta Ads and Social appear for it the next time Grux starts."
    }
    static let alreadyThereCopy = "That brand is already here."
    static let notANameCopy = "Type the brand's name, for example Harbor Bakery."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.title)
                .font(GruxTheme.Font.body.weight(.semibold))
                .foregroundStyle(GruxTheme.textPrimary)
            Text(Self.purpose)
                .font(.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !brands.isEmpty {
                Text("Your brands: " + brands.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            HStack(spacing: 8) {
                TextField("", text: $name, prompt: Text("brand name"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
            }
        }
    }

    private func add() {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch BrandRoster.add(label: label) {
        case .added:
            message = Self.addedCopy(label)
            name = ""
            brands = BrandRoster.labelsOnDisk()
        case .alreadyThere:
            message = Self.alreadyThereCopy
        case .notAName:
            message = Self.notANameCopy
        }
    }
}
