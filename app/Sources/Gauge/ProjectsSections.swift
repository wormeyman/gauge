import SwiftUI

/// The Projects page's developer sections: ports, containers, build caches and local AI models.
struct ProjectsSections: View {
    var monitor: Monitor
    var width: CGFloat

    private var wide: Bool { width >= 900 }

    var body: some View {
        let tools = monitor.devTools
        VStack(spacing: 34) {
            pair(PortsSection(monitor: monitor, tools: tools), ContainersSection(tools: tools))
            pair(CachesSection(tools: tools), ModelsSection(tools: tools))
        }
        .task {
            // Scans run only while the page is open; each kind keeps its own interval.
            while !Task.isCancelled {
                tools.refresh(monitor)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder private func pair(_ left: some View, _ right: some View) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 40) {
                left.frame(maxWidth: .infinity, alignment: .topLeading)
                right.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(spacing: 34) { left; right }
        }
    }
}

/// A plain-language line under a section, in the muted colour.
private struct Note: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

/// A list row with a hairline under it.
private struct Row<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            content.padding(.vertical, 9)
            Hairline()
        }
    }
}

// MARK: Ports

private struct PortsSection: View {
    var monitor: Monitor
    var tools: DevTools
    @State private var pending: DevServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Ports", count: tools.ports.count) {
                Text("Common dev ports").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            if !tools.portsScanned && tools.ports.isEmpty {
                Note(text: "Checking ports…").padding(.top, 12)
            }
            ForEach(tools.ports) { row in
                Row {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(verbatim: String(row.port)).font(Theme.mono(13)).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.holder).font(.system(size: 13)).lineLimit(1)
                                if !row.folder.isEmpty {
                                    Text(row.folder).font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            if let note = row.note {
                                HStack(spacing: 6) {
                                    if row.forgotten { Circle().fill(Theme.signal).frame(width: 5, height: 5) }
                                    Text(row.forgotten ? "Probably forgotten · \(note)" : note)
                                }
                                .font(.system(size: 12)).foregroundStyle(row.forgotten ? Theme.signal : Theme.muted)
                            }
                        }
                        Spacer(minLength: 8)
                        if let server = row.server { stopControl(server) }
                    }
                }
            }
            if !tools.freePorts.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Free").font(.system(size: 12.5)).foregroundStyle(Theme.muted).frame(width: 46, alignment: .leading)
                    Text(tools.freePorts.map(String.init).joined(separator: "  ")).font(Theme.mono(12.5)).foregroundStyle(Theme.soft)
                }
                .padding(.top, 10)
            }
            Note(text: "A server that has sat idle for half an hour, or runs in another project while you work in a newer one, is marked as probably forgotten. Ports held by other users' processes, such as ones started with sudo, aren't visible to Gauge.")
                .padding(.top, 12)
        }
        .confirmationDialog(pending.map(title) ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { server in
            Button("Stop", role: .destructive) { monitor.stop(server) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Gauge sends it the same stop signal as Control-C in its terminal.")
        }
    }

    /// The same states as the server list above; forcing a stuck server happens there.
    @ViewBuilder private func stopControl(_ server: DevServer) -> some View {
        switch monitor.serverStops[server.pid] {
        case .stopping: Text("Stopping…").font(.system(size: 13)).foregroundStyle(Theme.muted)
        case .stillRunning: Text("Still running").font(.system(size: 13)).foregroundStyle(Theme.signal)
        case .notPermitted: Text("Not yours").font(.system(size: 13)).foregroundStyle(Theme.muted)
        case nil:
            Button("Stop") { pending = server }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.soft)
                .accessibilityLabel("Stop \(server.name) on port \(server.ports.first ?? 0)")
        }
    }

    private func title(_ server: DevServer) -> String {
        let place = server.folder.isEmpty ? "" : " in \(server.folder)"
        return "Stop \(server.name) on port \(server.ports.map(String.init).joined(separator: ", "))\(place)?"
    }
}

// MARK: Containers

private struct ContainersSection: View {
    var tools: DevTools

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Containers", count: count) {
                if let runtime { Text(runtime).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
            }
            switch tools.containers {
            case .noRuntime:
                Note(text: "No container runtime running. Gauge looks for Docker Desktop, OrbStack, Colima and Podman.").padding(.top, 12)
            case .checking:
                Note(text: "Asking the runtime for container stats…").padding(.top, 12)
            case .unavailable(_, let reason):
                Note(text: reason).padding(.top, 12)
            case .running(_, let containers):
                if containers.isEmpty {
                    Note(text: "No containers are running.").padding(.top, 12)
                } else {
                    HStack {
                        Text("Container"); Spacer()
                        Text("CPU").frame(width: 64, alignment: .trailing)
                        Text("Memory").frame(width: 86, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.top, 10).padding(.bottom, 2)
                    ForEach(containers) { container in
                        Row {
                            HStack(alignment: .firstTextBaseline) {
                                Text(container.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(String(format: "%.1f%%", container.cpu)).font(Theme.mono(12.5)).frame(width: 64, alignment: .trailing)
                                Text(Fmt.memoryText(container.memory)).font(Theme.mono(12.5)).frame(width: 86, alignment: .trailing)
                            }
                        }
                    }
                }
                Note(text: "From docker stats over the runtime's local socket, every 30 seconds. CPU is a percentage of one core.")
                    .padding(.top, 12)
            }
        }
    }

    private var runtime: String? {
        switch tools.containers {
        case .noRuntime: nil
        case .checking(let name), .unavailable(let name, _), .running(let name, _): name
        }
    }

    private var count: Int? {
        if case .running(_, let containers) = tools.containers { return containers.count }
        return nil
    }
}

// MARK: Build caches

private struct CachesSection: View {
    var tools: DevTools
    @State private var pending: CacheItem?
    @State private var failure: String?

    var body: some View {
        let top = tools.caches.first?.bytes ?? 1
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Build caches") {
                HStack(spacing: 12) {
                    if !tools.caches.isEmpty {
                        Text(Fmt.storageText(tools.caches.map(\.bytes).reduce(0, +))).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    Button(tools.measuring ? "Measuring…" : "Measure again") { tools.measureCaches() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.soft)
                        .disabled(tools.measuring)
                }
            }
            if tools.caches.isEmpty {
                Note(text: tools.measuring || tools.measured == nil ? "Measuring folders…" : "No build caches found.").padding(.top, 12)
            }
            ForEach(tools.caches) { item in
                Row {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label).font(.system(size: 13)).lineLimit(1)
                            Text(PortBoard.abbreviate(item.path, home: NSHomeDirectory()))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.line2)
                            Rectangle().fill(Theme.tone("Disk")).frame(width: 70 * item.bytes / max(top, 1))
                        }
                        .frame(width: 70, height: 3)
                        Text(Fmt.storageText(item.bytes)).font(Theme.mono(12.5)).frame(width: 72, alignment: .trailing)
                        Button("Move to Trash…") { pending = item }
                            .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.soft)
                    }
                }
            }
            Note(text: "Sizes are measured on this Mac at most every 10 minutes, including node_modules in folders where Gauge has seen a dev server. Move to Trash keeps everything in the Trash until you empty it.")
                .padding(.top, 12)
        }
        .confirmationDialog(pending.map { "Move \($0.label) to the Trash?" } ?? "",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { item in
            Button("Move to Trash", role: .destructive) { failure = tools.trash(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(PortBoard.abbreviate(item.path, home: NSHomeDirectory())) (\(Fmt.storageText(item.bytes))) goes to the Trash. \(item.note)")
        }
        .alert("Couldn't move it to the Trash", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}

// MARK: Local AI models

private struct ModelsSection: View {
    var tools: DevTools

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Local AI models", count: tools.models.isEmpty ? nil : tools.models.count)
            if let room = tools.headroom {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.tone("Memory")).frame(width: 7, height: 7)
                        Text(ModelHeadroom.sentence(free: room.free)).font(.system(size: 13.5, weight: .medium))
                    }
                    Ruler(fraction: room.limit > 0 ? room.used / room.limit : 0, tint: Theme.tone("Memory"), glides: false)
                    Readings(stats: [
                        Stat(label: room.estimated ? "GPU memory limit (estimate)" : "GPU memory limit", value: Fmt.memoryText(room.limit)),
                        Stat(label: "In use now", value: Fmt.memoryText(room.used)),
                        Stat(label: "Headroom", value: Fmt.memoryText(room.free)),
                    ], size: 13)
                }
                .padding(.top, 14).padding(.bottom, 12)
                Hairline()
            }
            if tools.runners.isEmpty {
                Note(text: "No model runner is running. Gauge looks for Ollama, LM Studio, llama.cpp and MLX.").padding(.top, 12)
            } else {
                ForEach(tools.runners) { runner in
                    Row {
                        HStack(alignment: .firstTextBaseline) {
                            Text(runner.name).font(.system(size: 13))
                            Spacer(minLength: 8)
                            Text(Fmt.memoryText(runner.memory)).font(Theme.mono(12.5))
                        }
                    }
                }
            }
            if !tools.models.isEmpty {
                Text("Downloaded").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).padding(.top, 14)
                ForEach(tools.models) { model in
                    Row {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(model.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Text(model.source).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer(minLength: 8)
                            Text(Fmt.storageText(model.bytes)).font(Theme.mono(12.5))
                        }
                    }
                }
            }
            Note(text: note).padding(.top, 12)
        }
    }

    private var note: String {
        let limit = tools.headroom?.estimated ?? true
            ? "The GPU limit is an estimate: about 75% of memory, roughly what macOS allows by default."
            : "The GPU limit comes from iogpu.wired_limit_mb."
        return "\(limit) A model needs about its parameters × bits ÷ 8, plus 20% for context, so this is a rough guide. Downloaded models are read from Ollama's and LM Studio's folders on disk."
    }
}
