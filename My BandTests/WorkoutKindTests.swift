import Testing
@testable import My_Band

struct WorkoutKindTests {

    @Test func badmintonCodeMapsToBadminton() {
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 608) == .badminton)
    }

    @Test func sportsSharingAHealthTypeFoldOntoOneKind() {
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 404) == .dance)
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 621) == .soccer)
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 704) == .hockey)
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 315) == .functionalStrength)
    }

    @Test func outdoorSportsKeepGpsAtWorkoutStart() {
        for code in [100, 105, 200, 600, 606, 619, 708, 709, 802] {
            #expect(WorkoutSummaryParser.workoutKind(fromCode: code)?.usesGps == true, "code \(code)")
        }
    }

    @Test func unknownCodeStaysUnmapped() {
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 9999) == nil)
    }

    @Test func outdoorCodesWithOnlyAnIndoorKindStayUnmapped() {
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 203) == nil)
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 617) == nil)
    }

    @Test func onlyCode308StartsStrengthRecording() {
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 308) == .strengthTraining)
        #expect(WorkoutSummaryParser.workoutKind(fromCode: 313) == .functionalStrength)
    }
}
