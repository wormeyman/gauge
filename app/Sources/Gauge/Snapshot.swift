import SwiftUI

/// Development aid: with GAUGE_SNAPSHOT=<folder>, Gauge renders its overview (and optionally a
/// detail sheet) to PNGs from live data, then quits. Used for progress screenshots.
/// Also renders the menu bar panel to menubar.png.
/// Optional: GAUGE_SNAPSHOT_WIDTH=1440, GAUGE_SNAPSHOT_HEIGHT=900, GAUGE_SNAPSHOT_SHEET=CPU (a detail page, Privacy or LocalTools), GAUGE_SNAPSHOT_DELAY=8.
@MainActor
enum Snapshot {
    static let folder = ProcessInfo.processInfo.environment["GAUGE_SNAPSHOT"]
    static weak var monitor: Monitor?

    static func scheduleIfRequested() {
        guard let folder else { return }
        let env = ProcessInfo.processInfo.environment
        let delay = Double(env["GAUGE_SNAPSHOT_DELAY"] ?? "") ?? 8
        let width = CGFloat(Double(env["GAUGE_SNAPSHOT_WIDTH"] ?? "") ?? 1440)
        let sheet = env["GAUGE_SNAPSHOT_SHEET"]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let monitor else { NSApp.terminate(nil); return }
            let gutter: CGFloat = width < 700 ? 20 : 40
            let content = width - gutter * 2
            let page = VStack(spacing: 0) {
                OverviewPage(monitor: monitor, width: content, bars: .constant(false), export: {}, open: { _ in }, select: { _ in })
                    .frame(width: content)
                    .padding(.horizontal, gutter)
                Island(selection: "Overview", select: { _ in }, compact: width < 600)
                    .padding(.vertical, 40)
                StatusBar(monitor: monitor, showPrivacy: {})
            }
            save(page.frame(width: width), to: "\(folder)/overview.png")
            save(MenuBarPanel(monitor: monitor), to: "\(folder)/menubar.png")
            if let height = Double(env["GAUGE_SNAPSHOT_HEIGHT"] ?? "") {
                // Window-sized view: content clipped to the viewport, island floating above the status bar.
                let viewport = ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        OverviewPage(monitor: monitor, width: content, bars: .constant(false), export: {}, open: { _ in }, select: { _ in })
                            .frame(width: content)
                            .padding(.horizontal, gutter)
                            .frame(width: width, height: height - 31, alignment: .top)
                            .clipped()
                        StatusBar(monitor: monitor, showPrivacy: {})
                    }
                    Island(selection: "Overview", select: { _ in }, compact: width < 600)
                        .padding(.bottom, 44)
                }
                save(viewport.frame(width: width, height: height), to: "\(folder)/viewport.png")
            }
            if let sheet, ["Privacy", "LocalTools"].contains(sheet) {
                // The privacy sheet, or the Local tools settings section, at their own widths.
                let panel = Group {
                    if sheet == "Privacy" { PrivacyDetails().frame(width: 512).padding(24).background(Theme.raise) }
                    else { LocalToolsSettings.snapshot }
                }
                save(panel, to: "\(folder)/detail.png")
            } else if let sheet {
                // Detail page for a metric, rendered at the same width as the window.
                let detail = VStack(spacing: 0) {
                    Group {
                        if sheet == "Projects" {
                            ProjectsPage(monitor: monitor, back: {})
                        } else {
                            DetailPage(name: sheet, monitor: monitor, width: content, back: {},
                                       previewHover: Double(env["GAUGE_SNAPSHOT_HOVER"] ?? ""))
                        }
                    }
                    .frame(width: content)
                    .padding(.horizontal, gutter)
                    .padding(.bottom, 40)
                }
                save(detail.frame(width: width), to: "\(folder)/detail.png")
            }
            NSApp.terminate(nil)
        }
    }

    private static func save(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view.background(Theme.bg).foregroundStyle(Theme.ink).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
