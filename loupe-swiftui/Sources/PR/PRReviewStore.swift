import Foundation
import Observation

@MainActor
@Observable
final class PRReviewStore {
    enum Phase: Equatable {
        case loading
        case loaded
        case acting(String)       // "Merging…", "Approving…"
        case done(String)         // terminal message
        case failed(String)
    }

    let ref: SessionStore.PRRef
    private let pairing: Pairing

    private(set) var phase: Phase = .loading
    private(set) var pr: PRDetail?

    init(ref: SessionStore.PRRef, pairing: Pairing) {
        self.ref = ref
        self.pairing = pairing
    }

    private var client: LoupeClient { LoupeClient(pairing: pairing) }

    func load() async {
        phase = .loading
        do {
            pr = try await client.prDetail(owner: ref.owner, repo: ref.repo, number: ref.number)
            phase = .loaded
        } catch { fail(error) }
    }

    func merge() async {
        phase = .acting(pr?.draft == true ? "Marking ready and merging…" : "Merging…")
        do {
            let result = try await client.mergePR(owner: ref.owner, repo: ref.repo, number: ref.number)
            phase = .done(result.merged == true ? "Merged ✓" : (result.message ?? "Merge requested."))
        } catch { fail(error) }
    }

    func approve() async {
        phase = .acting("Approving…")
        do {
            try await client.reviewPR(owner: ref.owner, repo: ref.repo, number: ref.number, approve: true, comment: "Approved from Loupe.")
            await load()
        } catch { fail(error) }
    }

    func reject(reason: String) async {
        phase = .acting("Rejecting…")
        do {
            try await client.rejectPR(owner: ref.owner, repo: ref.repo, number: ref.number, reason: reason)
            phase = .done("Rejected.")
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
    }
}
