import SwiftUI
import AppKit
import KeymanCore

/// Opens the provider's balance page in the default browser. Keyman never loads the page itself.
struct BalanceLinkButton: View {
    let profile: ProviderProfile
    var showsTitle = false
    let setUp: () -> Void

    var body: some View {
        if let link = BalanceLink.resolve(profile) {
            Button { open(link.url) } label: {
                if showsTitle { Label("打开余额页", systemImage: "creditcard") }
                else { Label("余额", systemImage: "creditcard") }
            }
            .buttonStyle(.borderless)
            .help("在浏览器中打开 \(link.url.host ?? "")（Keyman 不读取余额）")
            .accessibilityLabel("打开\(profile.name)的余额页")
        } else {
            Button(action: setUp) {
                if showsTitle { Label("添加余额页链接", systemImage: "plus.circle") }
                else { Label("设置余额页", systemImage: "plus.circle") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("这个服务商没有内置的余额页链接，点击后填写")
        }
    }

    private func open(_ url: URL) {
        guard (try? BalanceLink.validate(url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}
