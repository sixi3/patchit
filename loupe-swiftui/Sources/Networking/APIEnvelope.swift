import Foundation

// MARK: - Daemon response envelope
// Every /api/v1 endpoint returns { ok, data, error }. Mirror it exactly.

struct APIError: Codable, Error, LocalizedError {
    let code: String
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}

struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: APIError?
}

enum LoupeError: Error, LocalizedError {
    case notPaired
    case badURL
    case http(Int)
    case api(APIError)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notPaired:          return "This phone isn't paired to a Mac yet."
        case .badURL:             return "Invalid daemon URL."
        case .http(let code):     return "Server returned HTTP \(code)."
        case .api(let e):         return e.message
        case .decoding(let d):    return "Couldn't read the response: \(d)"
        case .transport(let t):   return t
        }
    }
}
