import Testing

@testable import SparkAppComposition

/// UX-04: the Spark's stage and percent reach the chat launch line.
struct SparkProgressLineTests {
    @Test func chatLaunchProgressShowsStageAndPercent() {
        #expect(
            SparkModelLaunchProgress(stage: "Pulling weights", fraction: 0.426).line
                == "Pulling weights · 42%"
        )
        #expect(
            SparkModelLaunchProgress(stage: "Starting engine", fraction: nil).line
                == "Starting engine"
        )
    }
}

struct ModelProgressGuidanceTests {
    @Test func unknownStagesHaveNoInventedMilestones() {
        #expect(SparkDashboardOwnerPresentation.operationStageDetail(nil) == nil)
        #expect(SparkDashboardOwnerPresentation.operationStageDetail("future_stage") == nil)
        #expect(SparkModelLaunchProgress(stage: "Checking", fraction: nil).detail == nil)
    }

    @Test func recoveryDistinguishesUncertainWorkFromAStoppedOperation() {
        #expect(ModelOperationRecoveryAction.retryStatus.guidance.contains("may still be working"))
        #expect(
            ModelOperationRecoveryAction.retryTerminalFailure.guidance.contains("action stopped")
        )
        #expect(
            ModelOperationRecoveryAction.restartSpark.guidance.contains("Restart the Spark first")
        )
    }
}
