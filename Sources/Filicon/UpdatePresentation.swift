import Foundation
import FiliconUpdater

enum UpdatePresentationAction: Equatable {
    case check
    case download
    case install
}

struct UpdatePillPresentation: Equatable {
    let label: String
    let symbolName: String
    let action: UpdatePresentationAction?
    let isError: Bool

    static func make(state: UpdateState) -> Self? {
        switch state {
        case .idle, .upToDate: nil
        case .checking: .init(label: "Checking for updates…", symbolName: "arrow.triangle.2.circlepath", action: nil, isError: false)
        case .available(let release): .init(label: "Update \(release.version)", symbolName: "arrow.down.circle", action: .download, isError: false)
        case .downloading: .init(label: "Downloading update…", symbolName: "arrow.down.circle", action: nil, isError: false)
        case .staged: .init(label: "Install Update", symbolName: "arrow.clockwise.circle.fill", action: .install, isError: false)
        case .installing: .init(label: "Installing update…", symbolName: "arrow.triangle.2.circlepath", action: nil, isError: false)
        case .failed: .init(label: "Update failed — Retry", symbolName: "exclamationmark.triangle.fill", action: .check, isError: true)
        }
    }
}

struct RequiredUpdatePresentation: Equatable {
    let status: String
    let actionLabel: String?
    let action: UpdatePresentationAction?
    let isError: Bool

    static func make(state: UpdateState) -> Self {
        switch state {
        case .idle, .upToDate:
            .init(status: "A required update must be installed to continue.", actionLabel: "Check for Update", action: .check, isError: false)
        case .checking:
            .init(status: "Preparing the required update…", actionLabel: nil, action: nil, isError: false)
        case .available:
            .init(status: "The required update is ready to download.", actionLabel: "Download Update", action: .download, isError: false)
        case .downloading:
            .init(status: "Downloading the required update…", actionLabel: nil, action: nil, isError: false)
        case .staged:
            .init(status: "The required update is verified and ready.", actionLabel: "Install and Relaunch", action: .install, isError: false)
        case .installing:
            .init(status: "Installing the required update…", actionLabel: nil, action: nil, isError: false)
        case .failed:
            .init(status: "The required update could not be prepared.", actionLabel: "Retry", action: .check, isError: true)
        }
    }
}
