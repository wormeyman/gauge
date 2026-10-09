import SwiftUI

/// Settings section for the local API, the `gauge` command and its MCP server.
/// Text shared by the Local tools settings pane (Settings.swift) and its snapshot.
@MainActor
enum LocalToolsSettings {
    static var command: String { LocalAPI.commandPath }
    static var claudeCode: String { "claude mcp add gauge -- \"\(command)\" mcp" }
    static let explanation = "Lets the gauge command and coding agents on this Mac read vitals, top apps, dev servers, ports, notices and history. It's read-only: they can't stop servers or quit apps. Only your user account can connect, and nothing is opened to the network. Agents only see what's listed here, and the data stays on this Mac unless the agent sends it elsewhere."
}

extension LocalToolsSettings {
    /// The section's rows stacked plainly, for snapshots: ImageRenderer can't draw a grouped Form.
    static var snapshot: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local tools").font(.system(size: 13, weight: .semibold))
            HStack {
                Text("Let local tools read Gauge")
                Spacer()
                Text("On").font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Hairline()
            HStack { Text("Command"); Spacer(); Text(command).font(Theme.mono(11)) }
            Hairline()
            HStack { Text("Add to Claude Code"); Spacer(); Text(claudeCode).font(Theme.mono(11)) }
            Text(explanation)
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 720)
        .background(Theme.raise)
    }
}

/// A monospaced line that can be selected, with a Copy button.
struct CopyableLine: View {
    var text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(Theme.mono(11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .controlSize(.small)
        }
    }
}
