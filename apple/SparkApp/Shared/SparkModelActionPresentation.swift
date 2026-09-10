import Foundation
import SparkAPI

/// The one model action a dashboard header offers, from what the Spark is doing right now.
enum SparkModelActionPresentation {
    enum Action: Equatable {
        case launch
        case switchModel
        case loading(line: String, fraction: Double?)
    }

    static func action(
        inference: ActiveInference?,
        lifecycle: ModelLifecycleState?,
        modelName: String?
    ) -> Action {
        let name = modelName ?? inference?.modelID
        if let lifecycle, lifecycle.isRunning, lifecycle.action == .load {
            let stage = lifecycle.operation.map {
                SparkDashboardOwnerPresentation.operationStageLabel($0.stage, action: .load)
            }
            let fraction = lifecycle.operation.flatMap(
                SparkDashboardOwnerPresentation.determinateProgress
            )
            return .loading(
                line: loadingLine(name: name, stage: stage, fraction: fraction),
                fraction: fraction
            )
        }
        if inference?.state == .loading {
            return .loading(line: loadingLine(name: name, stage: nil, fraction: nil), fraction: nil)
        }
        if inference?.modelID != nil { return .switchModel }
        return .launch
    }

    static func loadingLine(name: String?, stage: String?, fraction: Double?) -> String {
        let subject = name ?? String(localized: "the model")
        guard let stage else { return String(localized: .loadingModel(subject)) }
        guard let fraction else {
            return String(localized: .loadingModelStage(subject, stage: stage))
        }
        return String(
            localized: .loadingModelStagePercent(
                subject,
                stage: stage,
                percent: fraction.percentFloor
            )
        )
    }
}
