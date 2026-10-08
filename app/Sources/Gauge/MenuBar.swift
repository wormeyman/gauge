import SwiftUI

/// The menu bar extra: CPU in the menu bar, and a compact instrument panel with all six vitals.
struct MenuBarLabel: View {
    var monitor: Monitor

    var body: some View {
        let cpu = monitor.cpuNow.map { String(format: "%.0f%%", $0) } ?? "–"
        Text("\(Image(systemName: "gauge.with.needle")) \(cpu)")
            .monospacedDigit()
            .accessibilityLabel("Gauge, CPU \(cpu)")
    }
}

struct MenuBarPanel: View {
    var monitor: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            if monitor.ready {
                VStack(spacing: 0) {
                    ForEach(monitor.vitals) { vital in
                        MenuBarChannel(vital: vital) { open(vital.name) }
                    }
                }
                .padding(.vertical, 6)
                if let notice = monitor.visibleNotices.first {
                    Hairline()
                    Button { open(notice.target) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            LED(on: notice.hot)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notice.title).font(.system(size: 12.5, weight: .medium))
                                Text(notice.body).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
            }
            Hairline()
            footer
        }
        .frame(width: 300)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .onAppear { monitor.setPanelVisible(true) }
        .onDisappear { monitor.setPanelVisible(false) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            GaugeMark(size: 18)
            Text("Gauge").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let status = monitor.status.first {
                HStack(spacing: 6) { LED(on: status.on); Text(status.text) }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.soft).lineLimit(1)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Gauge") { open("Overview") }.buttonStyle(QuietButtonStyle(primary: true))
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(QuietButtonStyle())
                .help("Settings")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Opens the main window on a page.
    private func open(_ page: String) {
        openWindow(id: "main")
        NSApp.activate()
        monitor.requestedPage = page
    }
}

/// One vital as a single row: dot and name, a thin scale, and a monospaced readout.
struct MenuBarChannel: View {
    var vital: Vital
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.tone(vital.name)).frame(width: 6, height: 6)
                    Text(vital.name).font(.system(size: 12.5))
                }
                .frame(width: 84, alignment: .leading)
                Ruler(fraction: vital.fraction, hot: vital.flag != nil, tint: Theme.tone(vital.name))
                    .frame(height: 14)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(vital.value).font(Theme.mono(12.5))
                    Text(vital.unit).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
                .foregroundStyle(vital.flag != nil ? Theme.signal : Theme.ink)
                .frame(width: 92, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(hovering ? Theme.raise : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(vital.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(vital.name), \(vital.value) \(vital.unit)\(vital.flag.map { ", \($0)" } ?? "")")
    }
}
