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
    private(set) var githubConnected = true   // flips false on GITHUB_AUTH_REQUIRED
    @ObservationIgnored private var blueprintPollTask: Task<Void, Never>?

    init() {
        pairing = PairingStore.load()
        phase = pairing == nil ? .unpaired : .idle
        if pairing != nil {
            items = []
        }
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
        blueprintPollTask?.cancel()
        blueprintPollTask = nil
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
            githubConnected = true
            phase = .loaded
            scheduleBlueprintPollIfNeeded()
        } catch LoupeError.api(let e) where e.code == "GITHUB_AUTH_REQUIRED" {
            githubConnected = false
            items = []
            phase = .idle   // RootView will route to ConnectGitHubView
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Force-regenerate a stale ticket's Blueprint, then reload.
    func refreshBlueprint(_ item: InboxItem) {
        guard let pairing else { return }
        let parts = item.repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Task {
            let client = LoupeClient(pairing: pairing)
            try? await client.refreshBlueprint(owner: parts[0], repo: parts[1], number: item.number)
            await refresh()
        }
    }

    private func scheduleBlueprintPollIfNeeded() {
        guard items.contains(where: { $0.isAnalyzing }) else {
            blueprintPollTask?.cancel()
            blueprintPollTask = nil
            return
        }
        guard blueprintPollTask == nil else { return }
        blueprintPollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                self?.blueprintPollTask = nil
                Task { await self?.refresh() }
            }
        }
    }
}
