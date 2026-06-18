import Foundation
import Observation

// MARK: - InboxStore
// Single source of truth for the homescreen. When paired, loads the live inbox
// from the daemon.
@MainActor
@Observable
final class InboxStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
        case unpaired
    }

    private(set) var items: [InboxItem] = []
    private(set) var prs: [PRSummary] = []
    private(set) var phase: Phase = .unpaired
    private(set) var workstation: String = "Anands-Mac-mini.local"
    private(set) var onlineAgents: [Agent] = [.codex, .claude]
    private(set) var pairing: Pairing?
    private(set) var lastSynced: Date?
    private(set) var githubConnected = true   // flips false on GITHUB_AUTH_REQUIRED
    private(set) var refreshingBlueprintIDs: Set<String> = []
    @ObservationIgnored private var blueprintPollTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    private enum RefreshMode {
        case foreground
        case background
    }

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
        stopLiveUpdates()
        pairing = nil
        items = []
        prs = []
        phase = .unpaired
    }

    func refresh() async {
        await refresh(mode: .foreground)
    }

    private func refresh(mode: RefreshMode) async {
        guard let pairing else {
            items = []
            prs = []
            phase = .unpaired
            return
        }
        // Only show the loader / allow a blank on a cold inbox. When we already
        // have tickets, keep them on screen and swap in the new payload on
        // success — a transient empty/failed/cancelled fetch must never blank
        // the list (the daemon also serves last-known-good as a backstop).
        let isCold = items.isEmpty
        if isCold { phase = .loading }
        let client = LoupeClient(pairing: pairing)
        do {
            let payload = try await client.inbox()
            apply(payload)
            if mode == .foreground {
                refreshWorkstation(from: client)
            }
        } catch LoupeError.api(let e) where e.code == "GITHUB_AUTH_REQUIRED" {
            githubConnected = false
            items = []
            prs = []
            stopLiveUpdates()
            phase = .idle   // RootView will route to ConnectGitHubView
        } catch is CancellationError {
            if isCold, phase == .loading { phase = .idle }   // never .loaded with empty items
        } catch {
            if isCold {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            // Warm: keep the existing list; transient errors shouldn't blank it.
        }
    }

    /// Map a daemon payload into the published state. Shared by `refresh()` and
    /// the live SSE stream so both render tickets identically.
    private func apply(_ payload: InboxPayload) {
        items = payload.assigned.map { $0.toInboxItem() }
        prs = payload.reviews.compactMap { t in
            let parts = t.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return PRSummary(owner: parts[0], repo: parts[1], number: t.number,
                             title: t.title, author: t.author,
                             updatedAt: DaemonTicket.relativeTime(t.updatedAt))
        }
        lastSynced = Date()
        githubConnected = true
        phase = .loaded
        startLiveUpdates()          // ensure the push stream is running once we have data
        scheduleBlueprintPollIfNeeded()
    }

    private func refreshWorkstation(from client: LoupeClient) {
        Task { [weak self] in
            guard let health = try? await client.health() else { return }
            await MainActor.run {
                guard let self else { return }
                if let hostname = health.hostname {
                    self.workstation = hostname
                } else if let cwd = health.cwd {
                    self.workstation = (cwd as NSString).lastPathComponent
                }
            }
        }
    }

    /// Force-regenerate a stale ticket's Blueprint, then reload.
    func refreshBlueprint(_ item: InboxItem) {
        guard let pairing else { return }
        let parts = item.repoFullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        guard !refreshingBlueprintIDs.contains(item.id) else { return }
        refreshingBlueprintIDs.insert(item.id)
        Task {
            let client = LoupeClient(pairing: pairing)
            defer { refreshingBlueprintIDs.remove(item.id) }
            do {
                try await client.refreshBlueprint(owner: parts[0], repo: parts[1], number: item.number)
                await refresh(mode: .background)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    func isRefreshingBlueprint(_ item: InboxItem) -> Bool {
        refreshingBlueprintIDs.contains(item.id)
    }

    /// Hold a persistent SSE subscription to the daemon's inbox stream, applying
    /// pushed payloads live and reconnecting with backoff if the stream drops.
    func startLiveUpdates() {
        guard pairing != nil, liveTask == nil else { return }
        liveTask = Task { [weak self] in
            var backoffSeconds = 1.0
            while !Task.isCancelled {
                guard let self, let pairing = self.pairing else { return }
                do {
                    let client = LoupeClient(pairing: pairing)
                    for try await payload in client.inboxStream() {
                        self.apply(payload)
                        backoffSeconds = 1.0
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // SSE/network drop — fall through to backoff and reconnect.
                }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(backoffSeconds))
                backoffSeconds = min(backoffSeconds * 2, 30)
            }
        }
    }

    func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
    }

    private func scheduleBlueprintPollIfNeeded() {
        // While the live stream is up, the daemon pushes blueprint-ready updates,
        // so the 4s client poll is only a fallback for when the stream is down.
        guard liveTask == nil else {
            blueprintPollTask?.cancel()
            blueprintPollTask = nil
            return
        }
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
                Task { await self?.refresh(mode: .background) }
            }
        }
    }
}
