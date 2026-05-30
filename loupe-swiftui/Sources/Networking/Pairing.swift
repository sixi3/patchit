import Foundation

// MARK: - Pairing
// The QR encodes the daemon URL + a token. Two accepted forms:
//   1. https://<tunnel-or-lan>/?pair=<token>           (host implied by URL)
//   2. loupe://pair?host=<https://…>&token=<token>     (custom scheme)
//
// Token persists in Keychain; host persists in UserDefaults (non-secret).

struct Pairing: Equatable {
    let host: URL      // e.g. https://abc.trycloudflare.com  or  http://192.168.1.5:4173
    let token: String

    /// Parse a scanned QR / deep link into a Pairing.
    static func parse(_ raw: String) -> Pairing? {
        guard let comps = URLComponents(string: raw) else { return nil }

        // Form 2: loupe://pair?host=…&token=…
        if comps.scheme == "loupe" {
            let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            guard let hostStr = q["host"], let host = URL(string: hostStr), let token = q["token"], !token.isEmpty
            else { return nil }
            return Pairing(host: host, token: token)
        }

        // Form 1: https://host/?pair=token
        if comps.scheme == "http" || comps.scheme == "https" {
            guard let token = comps.queryItems?.first(where: { $0.name == "pair" })?.value, !token.isEmpty
            else { return nil }
            var hostComps = comps
            hostComps.query = nil
            hostComps.fragment = nil
            hostComps.path = ""
            guard let host = hostComps.url else { return nil }
            return Pairing(host: host, token: token)
        }
        return nil
    }
}

// MARK: - Persistent pairing store
enum PairingStore {
    private static let tokenKey = "daemon.token"
    private static let hostKey = "daemon.host"

    static func save(_ pairing: Pairing) {
        Keychain.set(pairing.token, for: tokenKey)
        UserDefaults.standard.set(pairing.host.absoluteString, forKey: hostKey)
    }

    static func load() -> Pairing? {
        guard let token = Keychain.get(tokenKey),
              let hostStr = UserDefaults.standard.string(forKey: hostKey),
              let host = URL(string: hostStr) else { return nil }
        return Pairing(host: host, token: token)
    }

    static func clear() {
        Keychain.delete(tokenKey)
        UserDefaults.standard.removeObject(forKey: hostKey)
    }
}
