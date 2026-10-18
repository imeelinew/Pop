import SwiftUI
import Observation

@MainActor @Observable
final class TranslationState {
    var text = ""
    var isLoading = true
    var error: String?

    func reset() {
        text = ""
        isLoading = true
        error = nil
    }
}

struct TranslationView: View {
    let state: TranslationState
    let copy: () -> Void
    let configure: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void
    let sizeChanged: (CGSize) -> Void
    @State private var contentHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.text.isEmpty && state.error == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .accessibilityLabel("Translating")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !state.text.isEmpty {
                            Text(state.text)
                                .font(.system(size: 15))
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let error = state.error {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.trailing, 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .defaultScrollAnchor(.top)
                .frame(height: min(max(contentHeight, 20), 340))

                HStack(spacing: 12) {
                    if state.isLoading {
                        ProgressView().controlSize(.mini).accessibilityLabel("Translating")
                    }
                    Spacer(minLength: 0)
                    if state.error != nil {
                        iconButton("arrow.clockwise", label: "Retry", action: retry)
                        iconButton("slider.horizontal.3", label: "Open configuration", action: configure)
                    }
                    if !state.text.isEmpty {
                        iconButton("doc.on.doc", label: "Copy translation", action: copy)
                    }
                }
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(height: 16)
            }
        }
        .padding(18)
        .frame(width: 360)
        // NSPopover supplies the native Liquid Glass surface; avoid a second glass layer.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeChanged($0) }
        .onExitCommand(perform: dismiss)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
