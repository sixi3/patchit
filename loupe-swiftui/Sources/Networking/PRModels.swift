import Foundation

// MARK: - PR detail (from fetchPullRequestDetail in daemon.js)

struct PRDetail: Decodable {
    let repo: String
    let number: Int
    let title: String
    let body: String
    let url: String
    let state: String
    let draft: Bool
    let merged: Bool
    let mergeable: Bool?
    let mergeableState: String?
    let author: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let checkState: String?
    let files: [PRFile]
    let reviews: [PRReview]

    struct PRFile: Decodable, Identifiable {
        let filename: String
        let status: String          // added | modified | removed | renamed
        let additions: Int
        let deletions: Int
        let changes: Int
        let patch: String
        var id: String { filename }
    }

    struct PRReview: Decodable, Identifiable {
        let id: Int
        let user: String?
        let state: String           // APPROVED | CHANGES_REQUESTED | COMMENTED
        let body: String
        let submittedAt: String?
    }
}

/// Result of a merge action.
struct MergeResult: Decodable {
    let merged: Bool?
    let message: String?
    let sha: String?
}
