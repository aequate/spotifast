import SwiftUI
import UIKit

struct JamView: View {
    @State private var draft = ""
    @State private var invite: JamInvite?
    @State private var failure: String?
    @FocusState private var editing: Bool
    var body: some View {
        Form {
            Section {
                Text("Start a Jam in Spotify, then share its invitation here.").font(.headline)
                Text("Open Spotify, choose Start a Jam from its device menu, then Invite → Share link. Hosting requires Spotify Premium.").foregroundStyle(.secondary)
                Button("Open Spotify", systemImage: "arrow.up.forward.app") { openSpotify() }.frame(minHeight: 44)
                Link("Spotify's Jam guide", destination: URL(string: "https://support.spotify.com/article/jam/")!)
            } header: { Text("Listen together") } footer: {
                Text("Spotifast can share an existing invite. Creating, hosting and joining the Jam happen in Spotify.")
            }
            Section {
                TextField("Paste the Jam invite link", text: $draft, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($editing).privacySensitive().accessibilityLabel("Spotify Jam invite link")
                    .onSubmit { showInvite() }
                PasteButton(payloadType: String.self) { values in if let text = values.first { draft = text; failure = nil } }
                if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Button("Show QR and share", systemImage: "qrcode") { showInvite() }
                    .frame(minHeight: 44).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("Your invite") } footer: {
                Text("The QR code is created on your iPhone. This screen keeps the invite only while it is open and does not check whether the Jam is still active.")
            }
        }.navigationTitle("Jam invites").scrollDismissesKeyboard(.interactively)
        .onChange(of: draft) { _, _ in failure = nil }
        .sheet(item: $invite) { value in
            NavigationStack { JamInviteView(invite: value) }.modifier(StoreErrorPresenter())
        }
    }
    private func showInvite() {
        do { invite = try JamInvite(draft); failure = nil; editing = false }
        catch { failure = error.localizedDescription }
    }
    private func openSpotify() {
        guard let address = URL(string: "spotify:"), UIApplication.shared.canOpenURL(address) else {
            failure = "Install Spotify to start a Jam, or paste an invite you already have."; return
        }
        UIApplication.shared.open(address, options: [:]) { opened in
            if !opened { Task { @MainActor in failure = "Spotify could not open. Try again, or start the Jam directly in Spotify." } }
        }
    }
}

struct JamInviteView: View {
    let invite: JamInvite
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var rendering = false
    @State private var copied = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Share a Jam invite").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("Scan with a camera to open the invitation in Spotify.").foregroundStyle(.secondary)
                    if let image {
                        JamQRCard(image: image)
                            .frame(maxWidth: max(144, min(320, geometry.size.height - 56)))
                            .frame(maxWidth: .infinity)
                    } else if rendering { ProgressView("Creating QR code").frame(maxWidth: .infinity, minHeight: 140) }
                    if let failure {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Try QR again") { Task { await render() } }.frame(minHeight: 44)
                    }
                    let layout = typeSize >= .xxxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        ShareLink(item: invite.url, preview: SharePreview("Spotify Jam invitation", image: Image(systemName: "person.2"))) { Label("Share link", systemImage: "square.and.arrow.up").frame(minHeight: 44) }.buttonStyle(.borderedProminent)
                        Button { copyLink() } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc").frame(minHeight: 44) }.buttonStyle(.bordered)
                    }
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Spotify Jam invitation", image: Image(uiImage: image))) {
                            Label("Share QR image", systemImage: "qrcode").frame(minHeight: 44)
                        }
                    }
                    Text(invite.link).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled).privacySensitive()
                    if invite.shortened { Text("Spotify short links can also open music. Use the link copied from your Jam's Invite screen.").font(.footnote).foregroundStyle(.secondary) }
                    Text("Spotify decides whether this invitation is still valid. If the Jam has ended, start another in Spotify and copy its new invite.").font(.footnote).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.navigationTitle("Share Jam").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task(id: invite) { await render() }
    }
    private func render() async {
        guard !rendering else { return }; rendering = true; failure = nil
        defer { rendering = false }
        do { let result = try await JamQRRenderer.shared.image(for: invite); try Task.checkCancellation(); image = result }
        catch is CancellationError { }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    private func copyLink() {
        UIPasteboard.general.setItems([["public.utf8-plain-text": invite.link]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(3600)])
        copied = true
    }
}

struct JamQRCard: View {
    let image: UIImage
    var body: some View {
        Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            .padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Spotify Jam invite QR code")
            .accessibilityHint("Use Share link or Copy link to send the invitation without scanning")
    }
}
