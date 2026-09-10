import Foundation
import SparkAPI
import SparkCore

/// Which card, service or operation a screen asked the dashboard to bring into view.
extension SparkDashboardModel {
    public func requestModelFocus(_ modelID: String) { operations.requestModelFocus(modelID) }

    public func requestServiceManagement(serviceID: String) {
        operations.requestServiceManagement(serviceID: serviceID)
    }

    public func clearRequestedServiceFocus() { operations.clearRequestedServiceFocus() }

    public var canShowDownloadActivity: Bool { operations.canShowDownloadActivity }

    public func showDownloadActivity(modelID: String) {
        operations.showDownloadActivity(modelID: modelID)
    }

    public func requestOperationFocus(_ operationID: SparkOperationID) {
        operations.requestOperationFocus(operationID)
    }

    public func clearRequestedModelFocus() { operations.clearRequestedModelFocus() }
}
