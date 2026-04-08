import Foundation

struct RoutingRestorePlan {
    let restoreInputUID: String?
    let restoreOutputUID: String?
    let clearSavedInputUID: Bool
    let clearSavedOutputUID: Bool
}

struct RoutingSafetyState {
    var savedInputUID: String?
    var savedOutputUID: String?
    var inputTakeoverApplied = false
    var outputTakeoverApplied = false

    static func beginLaunch(
        currentInputUID: String?,
        currentOutputUID: String?,
        virtualUIDFragments: [String]
    ) -> RoutingSafetyState {
        RoutingSafetyState(
            savedInputUID: sanitize(uid: currentInputUID, virtualUIDFragments: virtualUIDFragments),
            savedOutputUID: sanitize(uid: currentOutputUID, virtualUIDFragments: virtualUIDFragments)
        )
    }

    static func crashRecoveryPlan(
        savedInputUID: String?,
        savedOutputUID: String?,
        availableUIDs: Set<String>
    ) -> RoutingRestorePlan {
        let restoreInputUID = availableUIDs.contains(savedInputUID ?? "") ? savedInputUID : nil
        let restoreOutputUID = availableUIDs.contains(savedOutputUID ?? "") ? savedOutputUID : nil
        return RoutingRestorePlan(
            restoreInputUID: restoreInputUID,
            restoreOutputUID: restoreOutputUID,
            clearSavedInputUID: restoreInputUID != nil,
            clearSavedOutputUID: restoreOutputUID != nil
        )
    }

    mutating func noteTakeoverApplied(input: Bool) {
        if input {
            inputTakeoverApplied = true
        } else {
            outputTakeoverApplied = true
        }
    }

    func rollbackPlanOnFailure() -> RoutingRestorePlan {
        RoutingRestorePlan(
            restoreInputUID: inputTakeoverApplied ? savedInputUID : nil,
            restoreOutputUID: outputTakeoverApplied ? savedOutputUID : nil,
            clearSavedInputUID: true,
            clearSavedOutputUID: true
        )
    }

    func shutdownRestorePlan() -> RoutingRestorePlan {
        rollbackPlanOnFailure()
    }

    func recoveryPlanAfterRuntimeFailure() -> RoutingRestorePlan {
        rollbackPlanOnFailure()
    }

    private static func sanitize(uid: String?, virtualUIDFragments: [String]) -> String? {
        guard let uid else { return nil }
        guard !virtualUIDFragments.contains(where: { uid.contains($0) }) else { return nil }
        return uid
    }
}
