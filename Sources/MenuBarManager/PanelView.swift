import SwiftUI
import AppKit

@MainActor
final class PanelModel: ObservableObject {
    @Published var items: [MenuBarItem] = []
    @Published var query = ""
    @Published var axTrusted = true
    @Published var screenCaptureGranted = true
    @Published var busy = false
    @Published var message: String?
    /// macOS only applies a new Screen Recording grant after the app restarts.
    @Published var screenCaptureRequested = false

    var onActivate: ((MenuBarItem) -> Void)?
    var onTogglePin: ((MenuBarItem) -> Void)?
    var onRequestAX: (() -> Void)?
    var onRequestScreenCapture: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRelaunch: (() -> Void)?

    private func filtered(_ s: MenuBarItem.Section) -> [MenuBarItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter {
            $0.section == s && (q.isEmpty || $0.displayName.lowercased().contains(q) || $0.appName.lowercased().contains(q))
        }
    }
    var visible: [MenuBarItem] { filtered(.visible) }
    var hidden: [MenuBarItem] { filtered(.hidden) }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search icons", text: $model.query)
                    .textFieldStyle(.plain)
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.onRefresh?() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))

            if !model.axTrusted {
                banner("Turn on MenuBar Manager in Privacy & Security → Accessibility. If it's already on, select it, remove it with −, and grant again.",
                       button: "Open settings") {
                    model.onRequestAX?()
                }
            } else {
                if !model.screenCaptureGranted {
                    if model.screenCaptureRequested {
                        banner("After allowing Screen Recording, relaunch to show real icons.", button: "Relaunch") {
                            model.onRelaunch?()
                        }
                    } else {
                        banner("Allow Screen Recording to show real icons instead of app icons.", button: "Allow") {
                            model.screenCaptureRequested = true
                            model.onRequestScreenCapture?()
                        }
                    }
                }
                section("Hidden", items: model.hidden, empty: "No hidden icons. Click a pin to hide one.")
                Divider()
                section("Always visible", items: model.visible, empty: "Nothing pinned.")
            }

            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            Text("Click an icon to open it. Click the pin to move it between sections.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 360)
    }

    @ViewBuilder
    private func section(_ title: String, items: [MenuBarItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.tertiary).padding(.vertical, 6)
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(items) { item in
                        ItemTile(item: item,
                                 onTap: { model.onActivate?(item) },
                                 onPin: { model.onTogglePin?(item) })
                    }
                }
            }
        }
    }

    private func banner(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
    }
}

private struct ItemTile: View {
    let item: MenuBarItem
    let onTap: () -> Void
    let onPin: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            icon.frame(height: 22)
            Text(item.displayName)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7).padding(.horizontal, 2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .overlay(alignment: .topTrailing) {
            if item.movable && (hovering || item.section == .visible) {
                Button(action: onPin) {
                    Image(systemName: item.section == .visible ? "pin.fill" : "pin")
                        .font(.system(size: 9))
                        .foregroundStyle(item.section == .visible ? Color.accentColor : .secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help(item.section == .visible ? "Hide this icon" : "Keep this icon visible")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .help(item.label.isEmpty ? item.appName : "\(item.appName) — \(item.label)")
        .contextMenu {
            Button("Open") { onTap() }
            if item.movable {
                Button(item.section == .visible ? "Hide" : "Keep visible") { onPin() }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let img = item.image {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        } else if let img = item.appIcon {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 22, height: 22)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 18))
        }
    }
}

/// Borderless floating panel that can take keyboard focus (for search) without activating the app.
final class DropdownPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}
