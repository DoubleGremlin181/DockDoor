import SwiftUI

/// Inline tinted callout used across settings for warnings and rejected input.
struct SettingsWarningCallout: View {
    enum Style {
        case warning
        case error

        var icon: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .warning: .yellow
            case .error: .red
            }
        }
    }

    private let text: Text
    private let style: Style

    /// Localized literal (extracted into the string catalog).
    init(_ key: LocalizedStringKey, style: Style = .warning) {
        text = Text(key)
        self.style = style
    }

    /// Already-localized dynamic string (e.g. a validation reason).
    init(verbatim string: String, style: Style = .warning) {
        text = Text(verbatim: string)
        self.style = style
    }

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: style.icon)
                .foregroundColor(style.tint)
            text
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(style.tint.opacity(0.1))
        .cornerRadius(8)
    }
}
