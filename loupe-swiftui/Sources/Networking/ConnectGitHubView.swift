import SwiftUI

// MARK: - ConnectGitHubView
// GitHub Device Flow for alpha: no callback URL, no tunnel dependency.
struct ConnectGitHubView: View {
    let store: InboxStore

    @Environment(\.openURL) private var openURL
    @State private var flow: GitHubDeviceFlow?
    @State private var statusText = "Preparing GitHub sign in..."
    @State private var isPolling = false
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: LoupeSpace.xl) {
                Spacer().frame(height: 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect GitHub")
                        .font(LoupeFont.largeTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text("Loupe needs GitHub access to load assigned issues and open pull requests from your Mac.")
                        .font(LoupeFont.body)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let flow {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ENTER CODE")
                            .font(LoupeFont.label)
                            .foregroundStyle(Color.textMuted)
                        Text(flow.userCode)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.surface))
                            .overlay(RoundedRectangle(cornerRadius: LoupeRadius.control).stroke(Color.hairline, lineWidth: 1))
                    }

                    Button {
                        if let url = URL(string: flow.verificationUri) {
                            openURL(url)
                        }
                        beginPolling()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.right.square.fill")
                                .font(.system(size: 18, weight: .bold))
                            Text("Open GitHub").font(LoupeFont.button)
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.accent))
                    }
                    .buttonStyle(.plain)
                } else {
                    ProgressView()
                        .tint(Color.accent)
                }

                HStack(spacing: 8) {
                    if isPolling {
                        ProgressView().scaleEffect(0.8).tint(Color.accent)
                    }
                    Text(statusText)
                        .font(LoupeFont.body)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let errorText {
                    Text(errorText)
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.riskAlert)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("Retry") { startFlow() }
                        .font(LoupeFont.caption)
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.chipFill))
                    Button("Re-pair Mac") { store.unpair() }
                        .font(LoupeFont.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accent))
                }

                Spacer()
            }
            .padding(.horizontal, LoupeSpace.xl)
        }
        .task { startFlow() }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startFlow() {
        pollTask?.cancel()
        pollTask = nil
        flow = nil
        errorText = nil
        isPolling = false
        statusText = "Preparing GitHub sign in..."

        guard let pairing = store.pairing else {
            errorText = "Pair your Mac first."
            return
        }

        Task {
            let client = LoupeClient(pairing: pairing)
            do {
                let response = try await client.githubDeviceStart()
                guard response.ok,
                      let flowId = response.flowId,
                      let userCode = response.userCode,
                      let verificationUri = response.verificationUri else {
                    errorText = response.error ?? "GitHub sign in could not start."
                    statusText = "GitHub is not connected."
                    return
                }
                flow = GitHubDeviceFlow(
                    id: flowId,
                    userCode: userCode,
                    verificationUri: verificationUri,
                    interval: max(5, response.interval ?? 5)
                )
                statusText = "Open GitHub, enter the code, then return to Loupe."
                beginPolling()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                statusText = "GitHub is not connected."
            }
        }
    }

    private func beginPolling() {
        guard let flow, let pairing = store.pairing, pollTask == nil else { return }
        isPolling = true
        statusText = "Waiting for GitHub authorization..."

        pollTask = Task {
            let client = LoupeClient(pairing: pairing)
            var interval = flow.interval

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                do {
                    let response = try await client.githubDevicePoll(flowId: flow.id)
                    interval = max(5, response.interval ?? interval)
                    switch response.status {
                    case "authorized":
                        isPolling = false
                        statusText = response.login.map { "Connected as \($0)." } ?? "GitHub connected."
                        await store.refresh()
                        return
                    case "expired":
                        isPolling = false
                        errorText = response.error ?? "GitHub code expired. Start again."
                        statusText = "GitHub is not connected."
                        return
                    case "waiting", "pending", nil:
                        statusText = "Waiting for GitHub authorization..."
                    default:
                        isPolling = false
                        errorText = response.error ?? "GitHub authorization failed."
                        statusText = "GitHub is not connected."
                        return
                    }
                } catch {
                    isPolling = false
                    errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    statusText = "GitHub is not connected."
                    return
                }
            }
        }
    }
}

private struct GitHubDeviceFlow: Equatable {
    let id: String
    let userCode: String
    let verificationUri: String
    let interval: Int
}
