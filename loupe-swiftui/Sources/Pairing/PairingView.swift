import SwiftUI

// MARK: - PairingView
// First-run setup: scan the QR printed by `loupe start`, or paste the link.
struct PairingView: View {
    let store: InboxStore
    @State private var showScanner = false
    @State private var pasted = ""
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: LoupeSpace.xl) {
                Spacer().frame(height: 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair your Mac")
                        .font(LoupeFont.largeTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text("Run `loupe start` on your Mac, then scan the QR it prints.")
                        .font(LoupeFont.body)
                        .foregroundStyle(Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Scan
                Button {
                    errorText = nil
                    showScanner = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 20, weight: .bold))
                        Text("Scan QR code").font(LoupeFont.button)
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: LoupeRadius.control).fill(Color.accent))
                }
                .buttonStyle(.plain)

                // Paste fallback
                VStack(alignment: .leading, spacing: 8) {
                    Text("OR PASTE LINK")
                        .font(LoupeFont.label).foregroundStyle(Color.textMuted)
                    HStack(spacing: 8) {
                        TextField("https://…/?pair=…", text: $pasted)
                            .font(LoupeFont.code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.surface))
                            .overlay(RoundedRectangle(cornerRadius: LoupeRadius.chip).stroke(Color.hairline, lineWidth: 1))
                        Button("Pair") { submit(pasted) }
                            .font(LoupeFont.button)
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: LoupeRadius.chip).fill(Color.chipFill))
                            .disabled(pasted.isEmpty)
                    }
                }

                if let errorText {
                    Text(errorText).font(LoupeFont.caption).foregroundStyle(Color.riskAlert)
                }

                Spacer()
            }
            .padding(.horizontal, LoupeSpace.xl)
        }
        .sheet(isPresented: $showScanner) {
            scannerSheet
        }
    }

    @ViewBuilder
    private var scannerSheet: some View {
        ZStack(alignment: .topTrailing) {
            if QRScannerView.isSupported {
                QRScannerView { payload in
                    showScanner = false
                    submit(payload)
                }
                .ignoresSafeArea()
            } else {
                Color.canvas.ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill").font(.system(size: 32)).foregroundStyle(Color.textMuted)
                    Text("Camera scanning isn't available here.\nPaste the link instead.")
                        .multilineTextAlignment(.center)
                        .font(LoupeFont.body).foregroundStyle(Color.textSecondary)
                }
            }
            Button { showScanner = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28)).foregroundStyle(.white, .black.opacity(0.4))
                    .padding()
            }
        }
    }

    private func submit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Pairing.parse(trimmed) != nil else {
            errorText = "That doesn't look like a Loupe pairing link."
            return
        }
        store.pair(with: trimmed)
    }
}
