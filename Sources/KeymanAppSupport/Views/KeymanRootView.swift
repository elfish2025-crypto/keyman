import SwiftUI
import AppKit
import KeymanCore

public struct KeymanRootView: View {
    @Bindable var model: AppModel
    @State private var showingAddProfile = false
    @State private var importSelection: ImportSelection?
    @State private var showingOutputPolicy = false
    @State private var showingVault = false
    @State private var balanceSetupProfile: ProviderProfile?
    @State private var searchText = ""
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(ProviderKind.allCases, id: \.self) { provider in
                    let matches = Set(ModelCatalog.entries(model.configuration, query: searchText).map(\.profileAlias))
                    let profiles = model.configuration.profiles.filter { $0.provider == provider && matches.contains($0.alias) }
                    if !profiles.isEmpty {
                        Section(providerTitle(provider)) {
                            ForEach(profiles) { profile in
                                NavigationLink(value: profile.id) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(profile.name).font(.headline)
                                            if !profile.isEnabled { Text("已停用").font(.caption).foregroundStyle(.orange) }
                                            Spacer()
                                            BalanceLinkButton(profile: profile) { balanceSetupProfile = profile }
                                            credentialLabel(profile.id)
                                        }
                                        Text(profileSummary(profile))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Keyman")
            .searchable(text: $searchText, prompt: "找账号、模型或用途，例如配音")
            .overlay {
                if model.configuration.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("添加你的第一个账号", systemImage: "key")
                    } description: {
                        Text("保存一次 API Key，让本机 Agent 按配置使用。可以手动添加，也可以导入已有资料。")
                    } actions: {
                        Button("添加账号") { showingAddProfile = true }
                            .buttonStyle(.borderedProminent)
                        Button("导入已有资料") { chooseImportFolder() }
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ProfileDetailView(model: model, profileID: id)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button("凭证库", systemImage: "lock.shield") { showingVault = true }
                    Button("输出规则", systemImage: "checkmark.shield") { showingOutputPolicy = true }
                    Button("刷新", systemImage: "arrow.clockwise") {
                        Task {
                            do { try await model.reload() }
                            catch { model.presentedError = error.localizedDescription }
                        }
                    }
                    Button("导入", systemImage: "square.and.arrow.down") {
                        model.presentedError = nil
                        chooseImportFolder()
                    }
                    Button("添加", systemImage: "plus") {
                        model.presentedError = nil
                        showingAddProfile = true
                    }
                }
            }
            .sheet(isPresented: $showingAddProfile) {
                ProfileEditorView(model: model)
                    .frame(width: 680, height: 700)
            }
            .sheet(item: $balanceSetupProfile) { profile in
                ProfileEditorView(model: model, editing: profile)
                    .frame(width: 680, height: 700)
            }
            .sheet(item: $importSelection) { selection in
                ImportPreviewView(model: model, rootURL: selection.url)
                    .frame(width: 660, height: 580)
            }
            .sheet(isPresented: $showingOutputPolicy) {
                OutputPolicyView(model: model).frame(width: 640, height: 540)
            }
            .sheet(isPresented: $showingVault) {
                CredentialVaultView(model: model).frame(width: 660, height: 590)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                OperationErrorView(model: model)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                do { try await model.reload() }
                catch { model.presentedError = error.localizedDescription }
            }
        }
    }

    private struct ImportSelection: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择已有 API 资料目录"
        panel.prompt = "预览导入"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.presentedError = nil
        importSelection = ImportSelection(url: url)
    }

    private func credentialLabel(_ id: UUID) -> Text {
        Text(model.credentialLabel(id))
    }

    private func providerTitle(_ provider: ProviderKind) -> String {
        switch provider {
        case .volcengineArk: "火山方舟"
        case .alibabaBailian: "阿里百炼"
        case .customREST: "自定义 REST API"
        }
    }

    private func profileSummary(_ profile: ProviderProfile) -> String {
        let scope = profile.workspaceName ?? profile.project ?? profile.region ?? "本机配置"
        return "\(scope) · \(profile.models.count) 个模型"
    }
}
