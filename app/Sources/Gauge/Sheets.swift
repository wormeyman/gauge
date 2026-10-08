import SwiftUI

enum SheetKind: String, Identifiable {
    case processes, privacy
    var id: String { rawValue }
}

struct SheetView: View {
    var kind: SheetKind
    @Environment(Monitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(kicker).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 14)
            Hairline()
            content.padding(.top, 16)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(QuietButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.raise)
        .onExitCommand { dismiss() }
    }

    private var title: String {
        switch kind {
        case .processes: "Processes"
        case .privacy: "Privacy"
        }
    }

    private var kicker: String {
        switch kind {
        case .processes: "Right now · your apps"
        case .privacy: "Gauge"
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .processes: ProcessesView(monitor: monitor)
        case .privacy:
            Text("Gauge reads system counters on this Mac, such as CPU load, memory, disk and network activity. Readings are saved to a history file in ~/Library/Application Support/Gauge and are never uploaded. Gauge has no analytics and no account. Its only network request is the optional update check, which downloads a small feed and sends nothing about your Mac. You can change how long history is kept, clear it, or turn off update checks in Settings.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.soft).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProcessesView: View {
    var monitor: Monitor
    @State private var query = ""
    @State private var order = [KeyPathComparator(\AppUsage.cpu, order: .reverse)]
    @State private var selection: AppUsage.ID?
    @State private var forceQuit: String?

    private var rows: [AppUsage] {
        monitor.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted(using: order)
    }

    private var selectedApp: String? { selection.flatMap { monitor.canQuit($0) ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Find a process", text: $query).textFieldStyle(.roundedBorder)
                Button("Quit") { selectedApp.map { monitor.quit($0, force: false) } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(selectedApp == nil)
                    .help(selectedApp.map { "Quit \($0)" } ?? "Select an app to quit it")
                Button("Force Quit…") { forceQuit = selectedApp }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(selectedApp == nil)
            }
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("App", value: \.name)
                TableColumn("CPU", value: \.cpu) { Text(String(format: "%.1f%%", $0.cpu)).font(Theme.mono(12)) }
                    .width(80)
                TableColumn("Memory", value: \.memory) { Text(Fmt.memoryText($0.memory)).font(Theme.mono(12)) }
                    .width(96)
            }
            .contextMenu(forSelectionType: AppUsage.ID.self) { ids in
                if let name = ids.first { QuitMenu(monitor: monitor, app: name, forceQuit: $forceQuit) }
            }
            .frame(height: 320)
            .overlay { if rows.isEmpty { Text("No matching processes.").foregroundStyle(Theme.muted) } }
            Text("Apps group their helper processes. CPU percentages are per core. Quit lets an app save its work first; Force Quit doesn't. Parts of macOS can't be quit from here. Processes owned by other users need administrator access, so they appear only in the memory total as \"Other & system\".")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .forceQuitConfirmation(monitor: monitor, app: $forceQuit)
    }
}

/// Quit and Force Quit items for an app's context menu. Empty for apps Gauge can't quit.
struct QuitMenu: View {
    var monitor: Monitor
    var app: String
    @Binding var forceQuit: String?

    var body: some View {
        if monitor.canQuit(app) {
            Button("Quit \(app)") { monitor.quit(app, force: false) }
            Button("Force Quit \(app)…") { forceQuit = app }
        }
    }
}

extension View {
    /// Asks before force quitting the app in `app`, since unsaved changes are lost.
    func forceQuitConfirmation(monitor: Monitor, app: Binding<String?>) -> some View {
        confirmationDialog("Force quit \(app.wrappedValue ?? "")?",
                           isPresented: Binding(get: { app.wrappedValue != nil }, set: { if !$0 { app.wrappedValue = nil } }),
                           presenting: app.wrappedValue) { name in
            Button("Force Quit", role: .destructive) { monitor.quit(name, force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { name in
            Text("\(name) closes immediately, and any unsaved changes are lost.")
        }
    }
}

struct ProjectsView: View {
    var monitor: Monitor
    @State private var pending: PendingStop?

    private struct PendingStop: Identifiable {
        var server: DevServer
        var force: Bool
        var id: String { server.id }
    }

    var body: some View {
        let servers = monitor.servers
        VStack(alignment: .leading, spacing: 12) {
            if servers.isEmpty {
                Text("No local servers are listening right now. Gauge looks for Node, Python, Ruby, Bun, Deno and similar processes with open TCP ports.")
                    .font(.system(size: 13.5)).foregroundStyle(Theme.soft).fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Server"); Text("Folder"); Text("Port").gridColumnAlignment(.trailing)
                        Text("Memory").gridColumnAlignment(.trailing); Text("State").gridColumnAlignment(.trailing)
                        Color.clear.frame(width: 1, height: 1).gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(servers) { server in
                        GridRow {
                            Text(server.name)
                            Text(server.folder.isEmpty ? "–" : server.folder).foregroundStyle(Theme.soft).lineLimit(1)
                            Text(server.ports.map(String.init).joined(separator: ", ")).font(Theme.mono(12.5))
                            Text(Fmt.memoryText(server.memory)).font(Theme.mono(12.5))
                            Text(server.isDev ? (server.idle ? "Idle" : "Active") : "Game server")
                                .foregroundStyle(server.isDev && !server.idle ? Theme.ink : Theme.muted)
                            stopControl(server)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            Text("Stop asks a server to shut down, like pressing Control-C in its terminal. Servers started by another user, such as with sudo, can't be stopped from Gauge. Game servers, such as Minecraft, are listed but not counted as dev servers.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(pending.map(title) ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { stop in
            Button(stop.force ? "Force Stop" : "Stop", role: .destructive) { monitor.stop(stop.server, force: stop.force) }
            Button("Cancel", role: .cancel) {}
        } message: { stop in
            Text(stop.force ? "It didn't stop when asked. Forcing ends it immediately, without letting it clean up."
                            : "Gauge sends it the same stop signal as Control-C in its terminal.")
        }
    }

    @ViewBuilder private func stopControl(_ server: DevServer) -> some View {
        switch monitor.serverStops[server.pid] {
        case .stopping:
            Text("Stopping…").foregroundStyle(Theme.muted)
        case .stillRunning:
            Button("Force stop") { pending = PendingStop(server: server, force: true) }
                .buttonStyle(.plain).foregroundStyle(Theme.signal)
                .help("\(server.name) is still running")
        case .notPermitted:
            Text("Not yours").foregroundStyle(Theme.muted)
                .help("Started by another user, such as with sudo. Stop it from its terminal.")
        case nil:
            Button("Stop") { pending = PendingStop(server: server, force: false) }
                .buttonStyle(.plain).foregroundStyle(Theme.soft)
                .accessibilityLabel("Stop \(server.name) on port \(server.ports.first ?? 0)")
        }
    }

    private func title(_ stop: PendingStop) -> String {
        let ports = stop.server.ports.map(String.init).joined(separator: ", ")
        let place = stop.server.folder.isEmpty ? "" : " in \(stop.server.folder)"
        return "\(stop.force ? "Force stop" : "Stop") \(stop.server.name) on port \(ports)\(place)?"
    }
}
