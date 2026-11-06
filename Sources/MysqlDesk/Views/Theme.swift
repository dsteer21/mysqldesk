import SwiftUI

enum Theme {
    static let background = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let panel = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let toolbar = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let selection = Color(red: 0.20, green: 0.32, blue: 0.50)
    static let hover = Color.white.opacity(0.05)
    /// Muted blue (#324772), shared with GitDesk.
    static let accent = Color(red: 50 / 255, green: 71 / 255, blue: 114 / 255)

    static let grid = Color(red: 0.12, green: 0.13, blue: 0.15)

    /// Colour tag for a connection (sidebar bar, tab stripe, target button).
    static func colour(_ tag: ConnectionColour) -> Color {
        switch tag {
        case .none: Color(red: 0.45, green: 0.50, blue: 0.58)
        case .green: Color(red: 0.36, green: 0.80, blue: 0.40)
        case .blue: Color(red: 0.30, green: 0.55, blue: 0.98)
        case .purple: Color(red: 0.58, green: 0.40, blue: 0.94)
        case .orange: Color(red: 0.98, green: 0.62, blue: 0.20)
        case .red: Color(red: 0.93, green: 0.30, blue: 0.27)
        }
    }
}

/// Icon-over-label toolbar button, as in GitDesk.
struct ToolButton: View {
    let title: String
    let icon: String
    var badge: Int = 0
    var help: String?
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(height: 18)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                                .offset(x: 12, y: -6)
                        }
                    }
                Text(title).font(.system(size: 11))
            }
            .frame(minWidth: 50, minHeight: 40)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help ?? title)
    }
}

/// A toolbar button with a small drop-down of related actions.
struct SplitToolButton<MenuContent: View>: View {
    let title: String
    let icon: String
    var badge: Int = 0
    var help: String?
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: -4) {
            ToolButton(title: title, icon: icon, badge: badge, help: help, action: action)
            Menu(content: menu) {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
}
