import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionItem: Identifiable {
    enum State: Equatable {
        case idle
        case queued
        case preparingModel
        case downloadingModel(progress: Double?) // nil for indeterminate
        case analyzing
        case saving
        case finished
        case failed(error: String)
        case cancelled
    }

    let id = UUID()
    let episodeID: UUID
    let sourceURL: URL

    var isTranscribing: Bool = false
    var progress: Double = 0.0 // 0...1 (best-effort; may be indeterminate)
    var state: State = .idle
    var statusText: String = ""

    init(episodeID: UUID, sourceURL: URL) {
        self.episodeID = episodeID
        self.sourceURL = sourceURL
    }

    func setState(_ newState: State, progress: Double? = nil, status: String? = nil) {
        state = newState
        if let p = progress { self.progress = p }
        isTranscribing = {
            switch newState {
            case .finished, .failed, .cancelled, .idle:
                return false
            default:
                return true
            }
        }()
        if let status { statusText = status }
    }
}
