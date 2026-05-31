import Foundation
import Observation

// MARK: - SessionsStore
// Persistent registry of dispatched sessions. Owns SessionStore instances so they
// (and their live SSE streams) outlive any screen. The pill counts runningCount;
// the Sessions screen lists `sessions`.
@MainActor
@Observable
final class SessionsStore {
    private(set) var sessions: [SessionStore] = []   // newest first
    private var hydratedPairingHost: URL?

    /// Sessions still working — drives the animated pill count.
    var runningCount: Int { sessions.lazy.filter(\.isRunning).count }

    /// Register + start a dispatch. Returns the store to display full-screen.
    @discardableResult
    func dispatch(item: InboxItem, harness: Agent, pairing: Pairing) -> SessionStore {
        let session = SessionStore(item: item, pairing: pairing, harness: harness)
        sessions.insert(session, at: 0)
        Task { await session.start() }
        return session
    }

    func hydrate(pairing: Pairing, force: Bool = false) async {
        guard force || hydratedPairingHost != pairing.host else { return }
        hydratedPairingHost = pairing.host
        do {
            let snapshots = try await LoupeClient(pairing: pairing).sessions()
            let existing = Dictionary(uniqueKeysWithValues: sessions.compactMap { store in
                store.sessionId.map { ($0, store) }
            })
            let restored = snapshots.map { snapshot in
                existing[snapshot.id] ?? SessionStore(snapshot: snapshot, pairing: pairing)
            }
            sessions = restored
            for session in sessions {
                session.reconnectIfRunning()
            }
        } catch {
            // Sessions are convenience state; inbox connectivity surfaces errors.
        }
    }

    /// Issue ids to hide from the inbox: anything dispatched that hasn't failed
    /// (running, completed, or PR-ready stays out; a failed session lets it return).
    var hiddenIssueIDs: Set<String> {
        Set(sessions.lazy.filter {
            if case .failed = $0.phase { return false }
            return true
        }.map(\.item.id))
    }
}
