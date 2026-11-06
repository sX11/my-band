import SwiftUI

// MARK: - BodySection
//
// Height and weight, edited in the Health sheet. Height is kept locally (ScaleManager uses it for an
// instant BMI) and written to Apple Health; a weight typed here is written like a scale weighing.

struct BodySection: View {

    @Environment(ScaleManager.self) private var scale

    @AppStorage(ProfileDefaults.heightCmKey) private var storedHeightCm: Double = 0

    @State private var heightInput = ""
    @State private var weightInput = ""
    @State private var healthWeightKg: Double?
    @State private var message: String?
    @State private var isError = false
    @State private var saving = false
    @FocusState private var focus: Field?

    private enum Field { case height, weight }

    let now: Date

    private var knownWeightKg: Double? { scale.lastWeightKg ?? healthWeightKg }

    // Compared as displayed: the field shows one decimal, so 72.34 kg on record is not an edit.
    private var heightChanged: Bool { Self.changed(heightInput, from: storedHeightCm > 0 ? storedHeightCm : nil) }
    private var weightChanged: Bool { Self.changed(weightInput, from: knownWeightKg) }

    var body: some View {
        Section {
            field(.height, "Height", text: $heightInput, unit: "cm", placeholder: "180")
            field(.weight, "Weight", text: $weightInput, unit: "kg", placeholder: "75.0",
                  detail: scale.lastWeightDate.map { "Updated \(MBFormat.ago($0, now: now))" })
            if heightChanged || weightChanged || saving {
                Button(saving ? "Saving…" : "Save to Apple Health", action: save)
                    .disabled(saving)
            }
            if let message {
                Text(message).font(.mbFootnote).foregroundStyle(isError ? MB.danger : MB.textTertiary)
            }
        } header: {
            Text("Body")
        } footer: {
            Text("Height lets Apple Health work out BMI from each weight.")
        }
        .listRowBackground(MB.surfaceCard)
        .task { await prefill() }
        .onChange(of: scale.lastWeightKg) { _, kg in
            if let kg, !saving, focus != .weight { weightInput = Self.format(kg) }
        }
    }

    private func field(_ id: Field, _ label: String, text: Binding<String>, unit: String, placeholder: String,
                       detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.mbBody).foregroundStyle(MB.textPrimary)
                if let detail { Text(detail).font(.mbFootnote).foregroundStyle(MB.textTertiary) }
            }
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(.decimalPad)
                .focused($focus, equals: id)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: 90)
            Text(unit).font(.mbBody).foregroundStyle(MB.textTertiary)
        }
    }

    private func prefill() async {
        if heightInput.isEmpty, storedHeightCm > 0 { heightInput = Self.format(storedHeightCm) }
        if scale.lastWeightKg == nil {
            try? await HealthKitManager.shared.requestAuthorization()
            healthWeightKg = (try? await HealthKitManager.shared.latestBodyMassKg()) ?? nil
        }
        if weightInput.isEmpty, let kg = knownWeightKg { weightInput = Self.format(kg) }
    }

    private func save() {
        let cm = heightInput.isEmpty ? nil : Self.parse(heightInput)
        let kg = weightInput.isEmpty ? nil : Self.parse(weightInput)
        if !heightInput.isEmpty, cm.map({ (50...260).contains($0) }) != true {
            return fail("Enter a height between 50 and 260 cm.")
        }
        if !weightInput.isEmpty, kg.map({ (2...500).contains($0) }) != true {
            return fail("Enter a weight between 2 and 500 kg.")
        }
        let newHeight = heightChanged ? cm : nil
        let newWeight = weightChanged ? kg : nil
        saving = true
        message = nil
        Task {
            do {
                let health = HealthKitManager.shared
                try await health.requestAuthorization()
                var refused = false
                if let cm = newHeight {
                    if try await health.writeHeight(meters: cm / 100) > 0 { storedHeightCm = cm } else { refused = true }
                }
                if !refused, let kg = newWeight {
                    if try await scale.recordManual(kg) > 0 { healthWeightKg = kg } else { refused = true }
                } else if !refused, newHeight != nil, let m = ProfileDefaults.heightMeters {
                    // Same sync identifier as the weighing, so its BMI is replaced rather than duplicated.
                    if let kg = scale.lastWeightKg, let date = scale.lastWeightDate {
                        try await health.writeBodyMass(kg, date: date, heightMeters: m)
                    } else if let kg = healthWeightKg {
                        try await health.writeBodyMassIndex(weightKg: kg, heightMeters: m)
                    }
                }
                isError = refused
                message = refused
                    ? "Apple Health didn't accept it. Allow My Band to write height and weight in Settings › Health."
                    : "Saved to Apple Health."
            } catch {
                isError = true
                message = error.localizedDescription
            }
            saving = false
        }
    }

    private func fail(_ text: String) {
        isError = true
        message = text
    }

    private static func parse(_ input: String) -> Double? {
        Double(input.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private static func changed(_ input: String, from known: Double?) -> Bool {
        guard let value = parse(input) else { return !input.isEmpty }
        return format(value) != known.map(format)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
