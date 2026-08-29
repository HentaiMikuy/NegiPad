import AppKit
import SwiftUI

struct AppTileView: View {
    @EnvironmentObject private var library: AppLibrary
    @State private var isHovering = false

    let app: AppItem

    private var category: AppCategory {
        library.category(for: app)
    }

    var body: some View {
        Button {
            library.launch(app)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    AppIconView(app: app, size: 64)
                        .shadow(color: .black.opacity(0.15), radius: 5, y: 3)

                    Spacer(minLength: 8)

                    if library.isFavorite(app) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .imageScale(.small)
                    }
                }

                Spacer(minLength: 0)

                Text(app.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    Image(systemName: category.symbol)
                    Text(category.rawValue)
                        .lineLimit(1)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(category.tint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        category.tint.opacity(isHovering ? 0.75 : 0.22),
                        lineWidth: isHovering ? 1.5 : 1
                    )
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(category.tint.opacity(isHovering ? 0.9 : 0.55))
                    .frame(height: 3)
                    .padding(.horizontal, 18)
                    .offset(y: 1)
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.12 : 0),
                radius: isHovering ? 10 : 0,
                y: isHovering ? 5 : 0
            )
            .scaleEffect(isHovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(app.url.path)
        .contextMenu {
            Button {
                library.launch(app)
            } label: {
                Label("打开", systemImage: "play.fill")
            }

            Button {
                library.toggleFavorite(app)
            } label: {
                Label(
                    library.isFavorite(app) ? "取消收藏" : "添加到收藏",
                    systemImage: library.isFavorite(app) ? "star.slash" : "star"
                )
            }

            Menu("移动到分类") {
                Button("使用自动分类") {
                    library.setCategory(nil, for: app)
                }
                Divider()
                ForEach(library.categories) { destination in
                    Button {
                        library.setCategory(destination, for: app)
                    } label: {
                        Label(destination.rawValue, systemImage: destination.symbol)
                    }
                }
            }

            Divider()

            Button {
                library.revealInFinder(app)
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }

            if let version = app.version {
                Divider()
                Text("版本 \(version)")
            }
        }
        .accessibilityLabel(app.name)
        .accessibilityHint("打开应用")
    }
}
