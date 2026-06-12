import Combine

@MainActor
final class ShareExtensionViewModel: ObservableObject {
    @Published var status = "Adding Episode..."
}
