import Foundation
import Network

/// Local-only reachability (NWPathMonitor). Nothing is sent anywhere; it only reads the system's path state.
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var online = true
    var onReconnect: (() -> Void)?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self = self, self.online != up else { return }
                self.online = up
                if up { self.onReconnect?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "wtb.network"))
    }
}
