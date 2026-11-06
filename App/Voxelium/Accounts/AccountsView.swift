import SwiftUI
import VoxeliumCore

/// Accounts: who you play as. The Microsoft account (signed in on Microsoft's page, tokens in
/// the Keychain) and the offline profile; the chosen one is used by every Play button.
struct AccountsView: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var accounts: AccountModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var confirmSignOut = false

    private var playsMicrosoft: Bool { accounts.account != nil && model.settings.useMicrosoftAccount }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PageHeader("Accounts")
                    SectionLabel("Play as")
                    if let acc = accounts.account {
                        AccountRow(title: acc.username, detail: "Microsoft · servers and Realms", systemImage: "person.badge.key.fill",
                                   selected: playsMicrosoft) { model.settings.useMicrosoftAccount = true }
                    }
                    AccountRow(title: model.settings.playerName, detail: "Offline · single-player and LAN", systemImage: "person.fill",
                               selected: !playsMicrosoft) { model.settings.useMicrosoftAccount = false }

                    SectionLabel("Microsoft account").padding(.top, 8)
                    microsoft

                    SectionLabel("Offline profile").padding(.top, 8)
                    TextSetting(title: "Player name", summary: "The name other players see in LAN games.",
                                text: $model.settings.playerName, placeholder: "Player",
                                error: OfflineIdentity.isValidName(model.settings.playerName) ? nil : "3–16 characters: letters, digits and underscore.")
                    Text("Offline profiles can't join online-mode servers or Realms.")
                        .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                }
                .padding(.horizontal, VX.margin(sizeClass)).padding(.bottom, 16)
                .frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .vxPage()
            .toolbar(.hidden, for: .navigationBar)
        }
        .confirmationDialog("Sign out of \(accounts.account?.username ?? "Microsoft")?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { accounts.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Voxelium forgets this account's sign-in. Your worlds and versions stay. Play then uses the offline profile.")
        }
    }

    @ViewBuilder private var microsoft: some View {
        if let acc = accounts.account {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Signed in as", value: acc.username)
                LabeledContent("Sign-in valid until") {
                    Text(acc.minecraftTokenExpiry, format: .dateTime.day().month().hour().minute())
                }
                Text("Voxelium renews the sign-in by itself while you're online.")
                    .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                Button("Sign out") { confirmSignOut = true }
                    .buttonStyle(OutlineButtonStyle(tint: VX.error, height: 40))
            }
            .font(.subheadline).foregroundStyle(VX.onSurface)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
        } else {
            SignInCard()
        }
    }
}

/// One account to play as, checked when it's the one Play uses.
private struct AccountRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowCard(selected: selected) {
                Image(systemName: systemImage).font(.body).foregroundStyle(VX.onSecondaryContainer)
                    .frame(width: 40, height: 40)
                    .background(VX.secondaryContainer, in: RoundedRectangle(cornerRadius: VX.Radius.small))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.vxHeadline).foregroundStyle(VX.onSurface).lineLimit(1)
                    Text(detail).font(.vxCaption).foregroundStyle(selected ? VX.onPrimaryContainer : VX.onSurfaceVariant).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(VX.primary) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Microsoft sign-in: the button, then each step of it (device code or Microsoft's web page).
private struct SignInCard: View {
    @EnvironmentObject var accounts: AccountModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch accounts.signIn {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                Text("Needed for online servers and Realms. The account must own Minecraft: Java Edition. You sign in on Microsoft's own page; the sign-in is kept in the iOS Keychain.")
                    .font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                Button { accounts.startSignIn() } label: {
                    SwiftUI.Label("Sign in with Microsoft", systemImage: "person.badge.key")
                }
                .buttonStyle(PrimaryButtonStyle(height: 48))
            }
            .padding(14)
            .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
        case .working(let message):
            Banner(.progress, message) { cancel }
        case .waitingForUser(let code):
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter this code at \(code.verificationURL.host ?? "microsoft.com/link")").font(.subheadline)
                Text(code.userCode).font(.system(.largeTitle, design: .monospaced).weight(.heavy))
                    .foregroundStyle(VX.primary).textSelection(.enabled)
                    .accessibilityLabel("Code \(code.userCode.map(String.init).joined(separator: " "))")
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to approve…").font(.vxCaption).foregroundStyle(VX.onSurfaceVariant)
                }
                Button {
                    UIPasteboard.general.string = code.userCode
                    openURL(code.verificationURL)
                } label: { SwiftUI.Label("Copy code and open the page", systemImage: "safari") }
                .buttonStyle(PrimaryButtonStyle(height: 48))
                cancel
            }
            .foregroundStyle(VX.onSurface)
            .padding(14)
            .background(VX.surface, in: RoundedRectangle(cornerRadius: VX.Radius.medium))
        case .failed(let message):
            Banner(.error, "Sign-in didn't work", message: message) {
                Button("Try again") { accounts.startSignIn() }.font(.footnote.weight(.bold))
            }
        }
    }

    private var cancel: some View {
        Button("Cancel") { accounts.cancelSignIn() }.font(.footnote.weight(.bold))
    }
}
