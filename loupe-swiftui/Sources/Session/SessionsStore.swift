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
        do {
            let snapshots = try await LoupeClient(pairing: pairing).sessions()
            let existing = Dictionary(uniqueKeysWithValues: sessions.compactMap { store in
                store.sessionId.map { ($0, store) }
            })
            let restored = snapshots.map { snapshot in
                if let store = existing[snapshot.id] {
                    store.apply(snapshot: snapshot)
                    return store
                }
                return SessionStore(snapshot: snapshot, pairing: pairing)
            }
            sessions = restored
            for session in sessions {
                session.reconnectIfRunning()
            }
            hydratedPairingHost = pairing.host
        } catch {
            hydratedPairingHost = nil
            // Sessions are convenience state; inbox connectivity surfaces errors.
        }
    }

    /// Issue ids to hide from the inbox because they are in progress or have a
    /// successful/PR-ready result. Failed or inconclusive sessions let the issue
    /// return so the user can retry or handle it manually.
    var hiddenIssueIDs: Set<String> {
        Set(sessions.lazy.filter(\.hidesSourceIssueInInbox).map(\.item.id))
    }
}
