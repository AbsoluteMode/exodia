import SwiftUI

/// Collapsible project header: chevron, name, key count, pencil and (except
/// General) trash. Dropping a dragged key on it moves the key here.
struct IslandCaseProjectRow: View {
    static let edit = IslandCaseRowAction(systemImage: "pencil", accessibilityIdentifier: "case.project.edit", accessibilityLabel: "Edit project")
    static let delete = IslandCaseRowAction(systemImage: "trash", accessibilityIdentifier: "case.project.delete", accessibilityLabel: "Delete project")

    /// General is built in and cannot be deleted.
    static func actions(isGeneral: Bool) -> [IslandCaseRowAction] {
        isGeneral ? [edit] : [edit, delete]
    }

    /// «Удалить проект <name> и N ключей?» with the Russian plural of «ключ».
    static func deleteConfirmation(name: String, keyCount: Int) -> String {
        "Удалить проект \(name) и \(keyCount) \(keyNoun(keyCount))?"
    }

    static func keyNoun(_ count: Int) -> String {
        let lastTwo = abs(count) % 100
        let last = lastTwo % 10
        if (11...14).contains(lastTwo) { return "ключей" }
        switch last {
        case 1: return "ключ"
        case 2...4: return "ключа"
        default: return "ключей"
        }
    }

    let section: CaseProjectSection
    let isExpanded: Bool
    let isDropTargeted: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.52))
                        .frame(width: 10)

                    Text(section.name)
                        .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)

                    Text("\(section.keyCount)")
                        .font(.system(size: IslandCaseVaultStyle.descriptionFontSize, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .fixedSize()

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(section.name)
            .accessibilityValue("\(section.keyCount)")
            .accessibilityIdentifier("case.project.header")

            HStack(spacing: 4) {
                ForEach(Self.actions(isGeneral: section.isGeneral)) { action in
                    IslandCaseIconButton(action: action, perform: action == Self.edit ? onEdit : onDelete)
                }
            }
            .fixedSize()
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: IslandCaseVaultStyle.rowHeight)
        .background(RoundedRectangle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius, style: .continuous)
            .fill(Color.white.opacity(isDropTargeted ? 0.18 : 0.10)))
        .overlay(RoundedRectangle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius, style: .continuous)
            .stroke(Color.white.opacity(isDropTargeted ? 0.30 : 0.10), lineWidth: 0.7))
    }
}

/// Inline confirm under a project header; deleting removes its keys too.
struct IslandCaseProjectDeleteConfirmation: View {
    let name: String
    let keyCount: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(IslandCaseProjectRow.deleteConfirmation(name: name, keyCount: keyCount))
                .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    pill("Отмена", fill: Color.white.opacity(0.10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("case.project.delete.cancel")

                Button(action: onConfirm) {
                    pill("Удалить", fill: Color.red.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("case.project.delete.confirm")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius, style: .continuous)
            .fill(Color.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: IslandCaseVaultStyle.rowCornerRadius, style: .continuous)
            .stroke(Color.red.opacity(0.30), lineWidth: 0.7))
    }

    private func pill(_ title: String, fill: Color) -> some View {
        Text(title)
            .font(.system(size: IslandCaseVaultStyle.nameFontSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(fill))
    }
}
