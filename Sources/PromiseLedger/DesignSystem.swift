import SwiftUI
import LedgerCore

enum Palette {
    static let background = Color(red: 0.966, green: 0.973, blue: 0.957)
    static let sidebar = Color(red: 0.938, green: 0.953, blue: 0.924)
    static let ink = Color(red: 0.13, green: 0.22, blue: 0.18)
    static let secondary = Color(red: 0.44, green: 0.49, blue: 0.45)
    static let green = Color(red: 0.16, green: 0.43, blue: 0.31)
    static let paleGreen = Color(red: 0.89, green: 0.94, blue: 0.87)
    static let border = Color(red: 0.87, green: 0.90, blue: 0.85)
    static let amber = Color(red: 0.63, green: 0.40, blue: 0.12)
}

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .padding(.horizontal, compact ? 14 : 18).padding(.vertical, compact ? 9 : 12)
            .foregroundStyle(.white)
            .background(Palette.green.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(Palette.ink)
            .background(configuration.isPressed ? Palette.paleGreen : .white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.border, lineWidth: 1))
    }
}

struct StateBadge: View {
    let state: EntryState
    var color: Color {
        switch state {
        case .confirmed: return Palette.green
        case .needsReview: return Palette.amber
        case .failed: return .red.opacity(0.75)
        default: return Palette.secondary
        }
    }
    var body: some View {
        Text(state.label).font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(color).background(color.opacity(0.08), in: Capsule())
    }
}

struct BrandMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(Palette.green)
            Image(systemName: "text.book.closed.fill").font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(.white)
            Circle().fill(Color(red: 0.77, green: 0.91, blue: 0.59)).frame(width: size * 0.20, height: size * 0.20)
                .offset(x: size * 0.31, y: -size * 0.31)
        }.frame(width: size, height: size)
    }
}
