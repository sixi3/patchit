import Foundation
import Observation

// MARK: - InboxStore
// Single source of truth for the homescreen. When paired, loads the live inbox
// from the daemon; otherwise serves SampleInbox so the screen is always demoable.
@MainActor
@Observable
final class InboxStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        case unpaired   // showing sample data
    }

    private(set) var items: [InboxItem] = SampleInbox.items
    private(set) var phase: Phase = .unpaired
    private(set) var workstation: String = "Anands-Mac-mini.local"
    private(set) var onlineAgents: [Agent] = [.codex, .claude]
    private(set) var pairing: Pairing?

    init() {
        pairing = PairingStore.load()
        phase = pairing == nil ? .unpaired : .idle
    }

    var isPaired: Bool { pairing != nil }

    func pair(with raw: String) {
        guard let p = Pairing.parse(raw) else {
            phase = .failed("That QR code isn't a Loupe pairing code.")
            return
        }
        PairingStore.save(p)
        pairing = p
        Task { await refresh() }
    }

    func unpair() {
        PairingStore.clear()
        pairing = nil
        items = SampleInbox.items
        phase = .unpaired
    }

    func refresh() async {
        guard let pairing else { phase = .unpaired; return }
        phase = .loading
        let client = LoupeClient(pairing: pairing)
        do {
            // Health first to confirm reachability + workstation identity.
            if let health = try? await client.health(), let cwd = health.cwd {
                workstation = (cwd as NSString).lastPathComponent
            }
            let payload = try await client.inbox()
            items = payload.assigned.map { $0.toInboxItem() }
            phase = .loaded
        } catch {
            // Keep showing whatever we have; surface the reason.
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
