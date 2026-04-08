import Foundation

protocol RoutingAudioBackend {
    func allDeviceUIDs() -> [String]
    func defaultDeviceUID(input: Bool) -> String?
    func setSystemDefaultDevice(input: Bool, uid: String) -> Bool
    func virtualDeviceUID(input: Bool) -> String?
}

struct RoutingPersistenceState {
    var savedInputDefaultUID: String?
    var savedOutputDefaultUID: String?
}

struct RoutingCoordinator {
    private(set) var state = RoutingSafetyState(savedInputUID: nil, savedOutputUID: nil)
    private let virtualUIDFragments = ["PouetMicrophone", "PouetSpeaker"]

    mutating func restoreCrashRecovery(
        persistence: inout RoutingPersistenceState,
        audio: RoutingAudioBackend
    ) {
        let plan = RoutingSafetyState.crashRecoveryPlan(
            savedInputUID: persistence.savedInputDefaultUID,
            savedOutputUID: persistence.savedOutputDefaultUID,
            availableUIDs: Set(audio.allDeviceUIDs())
        )
        apply(plan: plan, persistence: &persistence, audio: audio)
    }

    mutating func beginLaunch(
        persistence: inout RoutingPersistenceState,
        audio: RoutingAudioBackend
    ) {
        state = RoutingSafetyState.beginLaunch(
            currentInputUID: audio.defaultDeviceUID(input: true),
            currentOutputUID: audio.defaultDeviceUID(input: false),
            virtualUIDFragments: virtualUIDFragments
        )
        persistence.savedInputDefaultUID = state.savedInputUID
        persistence.savedOutputDefaultUID = state.savedOutputUID
    }

    mutating func applyAutomaticTakeover(audio: RoutingAudioBackend) -> Bool {
        guard let inputUID = audio.virtualDeviceUID(input: true),
              let outputUID = audio.virtualDeviceUID(input: false) else {
            return false
        }

        guard audio.setSystemDefaultDevice(input: true, uid: inputUID) else {
            return false
        }
        state.noteTakeoverApplied(input: true)

        guard audio.setSystemDefaultDevice(input: false, uid: outputUID) else {
            return false
        }
        state.noteTakeoverApplied(input: false)
        return true
    }

    mutating func rollbackAfterStartupFailure(
        persistence: inout RoutingPersistenceState,
        audio: RoutingAudioBackend
    ) {
        apply(plan: state.rollbackPlanOnFailure(), persistence: &persistence, audio: audio)
    }

    mutating func restoreOnShutdown(
        persistence: inout RoutingPersistenceState,
        audio: RoutingAudioBackend
    ) {
        apply(plan: state.shutdownRestorePlan(), persistence: &persistence, audio: audio)
    }

    mutating func restoreAfterRuntimeFailure(
        persistence: inout RoutingPersistenceState,
        audio: RoutingAudioBackend
    ) {
        apply(plan: state.recoveryPlanAfterRuntimeFailure(), persistence: &persistence, audio: audio)
    }

    private func apply(
        plan: RoutingRestorePlan,
        persistence: inout RoutingPersistenceState,
        audio: RoutingAudioBackend
    ) {
        if let restoreInputUID = plan.restoreInputUID {
            _ = audio.setSystemDefaultDevice(input: true, uid: restoreInputUID)
        }
        if let restoreOutputUID = plan.restoreOutputUID {
            _ = audio.setSystemDefaultDevice(input: false, uid: restoreOutputUID)
        }
        if plan.clearSavedInputUID {
            persistence.savedInputDefaultUID = nil
        }
        if plan.clearSavedOutputUID {
            persistence.savedOutputDefaultUID = nil
        }
    }
}
