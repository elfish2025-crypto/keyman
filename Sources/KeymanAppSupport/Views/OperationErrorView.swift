import SwiftUI

struct OperationErrorView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let message = model.presentedError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("关闭提示", systemImage: "xmark") {
                    model.presentedError = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            }
            .padding()
            .background(.orange.opacity(0.10))
            .accessibilityElement(children: .contain)
        }
    }
}
