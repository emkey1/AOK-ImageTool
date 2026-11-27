import SwiftUI

/// How a model's download is going, for a sheet that asked for it: the window says so too, but behind the
/// sheet. Shows nothing when there's nothing to say.
struct ModelDownloadNote: View {
    let model: DownloadableModel

    /// Whether the model is on its way.
    static func isFetching(_ model: DownloadableModel) -> Bool { ModelDownloads.shared.status[model.id] != nil }

    var body: some View {
        let downloads = ModelDownloads.shared
        switch downloads.status[model.id] {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 120)
                Text("Downloading the \(model.purpose) model… \(Int(fraction * 100))%").foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing the \(model.purpose) model…").foregroundStyle(.secondary)
            }
        case nil:
            if let failure = downloads.failure[model.id] {
                Text("Couldn't download the \(model.purpose) model. \(failure)").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
