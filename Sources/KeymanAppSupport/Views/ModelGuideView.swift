import SwiftUI
import KeymanCore

struct ModelGuideView: View {
    let packet: ModelUsagePacket
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(packet.guide?.summary ?? "尚未填写模型用途。").font(.title3)
                    Label(packet.requestReady ? "调用资料齐备" : "调用资料待补齐", systemImage: packet.requestReady ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(packet.requestReady ? .green : .orange)
                    if let guide = packet.guide {
                        item("适用任务", guide.useCases.joined(separator: "、"))
                        item("输入", guide.inputs)
                        item("输出", guide.outputs)
                        item("怎么使用", guide.instructions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                        item("限制与注意事项", guide.limitations.joined(separator: "\n"))
                        if let example = guide.requestExample {
                            item("请求示例", JSONValue.pretty(example), code: true)
                        }
                        ForEach(guide.documentationURLs, id: \.self) { address in
                            if let url = URL(string: address) { Link("官方资料：\(url.host ?? address)", destination: url) }
                        }
                    }
                    if !packet.blockers.isEmpty { item("还需补齐", packet.blockers.joined(separator: "\n")) }
                    item("Agent 入口", [packet.exampleCommand, packet.preflightCommand, packet.callCommand].map { $0.joined(separator: " ") }.joined(separator: "\n"), code: true)
                    Text(packet.credentialHandling).font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .navigationTitle(packet.modelName)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func item(_ title: String, _ value: String, code: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(value.isEmpty ? "待补充" : value).font(code ? .system(.callout, design: .monospaced) : .callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
