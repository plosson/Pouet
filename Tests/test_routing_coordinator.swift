import Foundation

private final class FakeRoutingAudioBackend: RoutingAudioBackend {
    let availableUIDs: Set<String>
    let currentInputUID: String?
    let currentOutputUID: String?
    let virtualInputUID: String?
    let virtualOutputUID: String?
    let failingUIDs: Set<String>
    private(set) var setCalls: [(Bool, String)] = []

    init(
        availableUIDs: Set<String>,
        currentInputUID: String?,
        currentOutputUID: String?,
        virtualInputUID: String?,
        virtualOutputUID: String?,
        failingUIDs: Set<String> = []
    ) {
        self.availableUIDs = availableUIDs
        self.currentInputUID = currentInputUID
        self.currentOutputUID = currentOutputUID
        self.virtualInputUID = virtualInputUID
        self.virtualOutputUID = virtualOutputUID
        self.failingUIDs = failingUIDs
    }

    func allDeviceUIDs() -> [String] { Array(availableUIDs) }
    func defaultDeviceUID(input: Bool) -> String? { input ? currentInputUID : currentOutputUID }
    func virtualDeviceUID(input: Bool) -> String? { input ? virtualInputUID : virtualOutputUID }

    func setSystemDefaultDevice(input: Bool, uid: String) -> Bool {
        setCalls.append((input, uid))
        return !failingUIDs.contains(uid)
    }
}

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
struct RoutingCoordinatorTests {
    static func main() {
        print("=== Routing Coordinator Tests ===")

        run("test_crash_recovery_restores_available_defaults") {
            let audio = FakeRoutingAudioBackend(
                availableUIDs: ["BuiltInMic", "BuiltInSpeaker"],
                currentInputUID: nil,
                currentOutputUID: nil,
                virtualInputUID: nil,
                virtualOutputUID: nil
            )
            var persistence = RoutingPersistenceState(
                savedInputDefaultUID: "BuiltInMic",
                savedOutputDefaultUID: "BuiltInSpeaker"
            )
            var coordinator = RoutingCoordinator()

            coordinator.restoreCrashRecovery(persistence: &persistence, audio: audio)

            let calls = audio.setCalls
            try assert(calls.count == 2, "expected both defaults to be restored")
            try assert(calls[0].0 && calls[0].1 == "BuiltInMic", "expected input restore first")
            try assert(!calls[1].0 && calls[1].1 == "BuiltInSpeaker", "expected output restore second")
            try assert(persistence.savedInputDefaultUID == nil, "restored input should be cleared")
            try assert(persistence.savedOutputDefaultUID == nil, "restored output should be cleared")
        }

        run("test_begin_launch_persists_current_non_virtual_defaults") {
            let audio = FakeRoutingAudioBackend(
                availableUIDs: [],
                currentInputUID: "BuiltInMic",
                currentOutputUID: "BuiltInSpeaker",
                virtualInputUID: nil,
                virtualOutputUID: nil
            )
            var persistence = RoutingPersistenceState(savedInputDefaultUID: nil, savedOutputDefaultUID: nil)
            var coordinator = RoutingCoordinator()

            coordinator.beginLaunch(persistence: &persistence, audio: audio)

            try assert(persistence.savedInputDefaultUID == "BuiltInMic", "launch should capture input")
            try assert(persistence.savedOutputDefaultUID == "BuiltInSpeaker", "launch should capture output")
        }

        run("test_takeover_failure_rolls_back_input_only") {
            let audio = FakeRoutingAudioBackend(
                availableUIDs: ["BuiltInMic", "BuiltInSpeaker", "PouetMicrophone_UID", "PouetSpeaker_UID"],
                currentInputUID: "BuiltInMic",
                currentOutputUID: "BuiltInSpeaker",
                virtualInputUID: "PouetMicrophone_UID",
                virtualOutputUID: "PouetSpeaker_UID",
                failingUIDs: ["PouetSpeaker_UID"]
            )
            var persistence = RoutingPersistenceState(savedInputDefaultUID: nil, savedOutputDefaultUID: nil)
            var coordinator = RoutingCoordinator()
            coordinator.beginLaunch(persistence: &persistence, audio: audio)

            let takeover = coordinator.applyAutomaticTakeover(audio: audio)
            try assert(!takeover, "takeover should fail when output switch fails")

            coordinator.rollbackAfterStartupFailure(persistence: &persistence, audio: audio)
            let calls = audio.setCalls
            try assert(calls.count == 3, "expected three routing calls")
            try assert(calls[0].0 && calls[0].1 == "PouetMicrophone_UID", "expected virtual mic takeover first")
            try assert(!calls[1].0 && calls[1].1 == "PouetSpeaker_UID", "expected virtual speaker takeover second")
            try assert(calls[2].0 && calls[2].1 == "BuiltInMic", "expected input rollback last")
            try assert(persistence.savedInputDefaultUID == nil, "rollback should clear saved input")
            try assert(persistence.savedOutputDefaultUID == nil, "rollback should clear saved output")
        }

        print("\n\(testsPassed)/\(testsRun) routing coordinator tests passed")
        exit(testsPassed == testsRun ? 0 : 1)
    }
}
