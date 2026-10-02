import SwiftUI

// MARK: - MBListRow
//
// A label and its value in a grouped list row, value right-aligned in tabular digits.

struct MBListRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.mbBody).foregroundStyle(MB.textPrimary)
            Spacer()
            Text(value).font(.mbBody).monospacedDigit().foregroundStyle(MB.textPrimary)
        }
    }
}
