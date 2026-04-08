import Foundation

private var testsRun = 0
private var testsPassed = 0

private func run(_ name: String, _ body: () throws -> Void) {
    testsRun += 1
    print("  \(name)".padding(toLength: 60, withPad: " ", startingAt: 0), terminator: "")
    do {
        try body()
        print("OK")
        testsPassed += 1
    } catch {
        print("FAIL: \(error.localizedDescription)")
    }
}

private func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
struct RoutingTests {
    static func main() {
        print("=== Routing Safety Tests ===")

        run("test_launch_saves_non_virtual_defaults") {
            let state = RoutingSafetyState.beginLaunch(
                currentInputUID: "BuiltInMic",
                currentOutputUID: "BuiltInSpeaker",
                virtualUIDFragments: ["PouetMicrophone", "PouetSpeaker"]
            )

            try assert(state.savedInputUID == "BuiltInMic", "expected input default to be captured")
            try assert(state.savedOutputUID == "BuiltInSpeaker", "expected output default to be captured")
            try assert(!state.inputTakeoverApplied, "input takeover should start false")
            try assert(!state.outputTakeoverApplied, "output takeover should start false")
        }

        run("test_launch_ignores_virtual_defaults") {
            let state = RoutingSafetyState.beginLaunch(
                currentInputUID: "PouetMicrophone_UID",
                currentOutputUID: "PouetSpeaker_UID",
                virtualUIDFragments: ["PouetMicrophone", "PouetSpeaker"]
            )

            try assert(state.savedInputUID == nil, "virtual input should not be persisted as restore target")
            try assert(state.savedOutputUID == nil, "virtual output should not be persisted as restore target")
        }

        run("test_partial_takeover_failure_requests_precise_rollback") {
            var state = RoutingSafetyState.beginLaunch(
                currentInputUID: "BuiltInMic",
                currentOutputUID: "BuiltInSpeaker",
                virtualUIDFragments: ["PouetMicrophone", "PouetSpeaker"]
            )
            state.noteTakeoverApplied(input: true)

            let plan = state.rollbackPlanOnFailure()
            try assert(plan.restoreInputUID == "BuiltInMic", "input should be restored after partial failure")
            try assert(plan.restoreOutputUID == nil, "output should not be restored when not taken over")
            try assert(plan.clearSavedInputUID, "input saved UID should be cleared after rollback")
            try assert(plan.clearSavedOutputUID, "output saved UID should be cleared after rollback")
        }

        run("test_clean_shutdown_restores_only_applied_routes") {
            var state = RoutingSafetyState.beginLaunch(
                currentInputUID: "BuiltInMic",
                currentOutputUID: "BuiltInSpeaker",
                virtualUIDFragments: ["PouetMicrophone", "PouetSpeaker"]
            )
            state.noteTakeoverApplied(input: true)
            state.noteTakeoverApplied(input: false)

            let plan = state.shutdownRestorePlan()
            try assert(plan.restoreInputUID == "BuiltInMic", "shutdown should restore input")
            try assert(plan.restoreOutputUID == "BuiltInSpeaker", "shutdown should restore output")
            try assert(plan.clearSavedInputUID, "shutdown should clear saved input UID")
            try assert(plan.clearSavedOutputUID, "shutdown should clear saved output UID")
        }

        run("test_crash_recovery_only_clears_restored_uids") {
            let plan = RoutingSafetyState.crashRecoveryPlan(
                savedInputUID: "BuiltInMic",
                savedOutputUID: "BuiltInSpeaker",
                availableUIDs: ["BuiltInMic"]
            )

            try assert(plan.restoreInputUID == "BuiltInMic", "available saved input should be restored")
            try assert(plan.restoreOutputUID == nil, "missing saved output should not be restored")
            try assert(plan.clearSavedInputUID, "restored input UID should be cleared")
            try assert(!plan.clearSavedOutputUID, "missing output UID should be kept for later recovery")
        }

        run("test_resume_failure_restores_original_routes") {
            var state = RoutingSafetyState.beginLaunch(
                currentInputUID: "BuiltInMic",
                currentOutputUID: "BuiltInSpeaker",
                virtualUIDFragments: ["PouetMicrophone", "PouetSpeaker"]
            )
            state.noteTakeoverApplied(input: true)
            state.noteTakeoverApplied(input: false)

            let plan = state.recoveryPlanAfterRuntimeFailure()
            try assert(plan.restoreInputUID == "BuiltInMic", "runtime failure should restore input")
            try assert(plan.restoreOutputUID == "BuiltInSpeaker", "runtime failure should restore output")
        }

        print("\n\(testsPassed)/\(testsRun) routing tests passed")
        exit(testsPassed == testsRun ? 0 : 1)
    }
}
