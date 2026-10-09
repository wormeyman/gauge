import Image from "next/image";
import type { CSSProperties } from "react";
import ChartDemo from "./components/ChartDemo";
import { CopyButton, Nav, RevealOnScroll } from "./components/Client";
import { DatabaseIcon, DownloadIcon, GitHubMark, NoNetworkIcon, SlidersIcon } from "./components/icons";

const REPO = "https://github.com/byalex33/gauge";
const DOWNLOAD = `${REPO}/releases/latest/download/Gauge.dmg`;
const BUILD = "git clone https://github.com/byalex33/gauge.git\ncd gauge/app && ./build.sh --open";

const tone = (c: string) => ({ "--c": c }) as CSSProperties;

const vitals = [
  ["CPU", "Load, user and system", "var(--cpu)"],
  ["Memory", "Pressure and composition", "var(--mem)"],
  ["GPU", "Utilisation and memory", "var(--gpu)"],
  ["Disk", "Space and throughput", "var(--disk)"],
  ["Network", "Download and upload", "var(--net)"],
  ["Battery", "Charge, power and health", "var(--bat)"],
];

export default function Home() {
  const year = new Date().getFullYear();
  return (
    <>
      <Nav>
        <div className="wrap nav-inner">
          <a className="brand" href="#top" aria-label="Gauge home">
            <Image src="/assets/icon.png" width={28} height={28} alt="" />
            <span>Gauge</span>
          </a>
          <nav className="nav-links" aria-label="Sections">
            <a href="#features">Features</a>
            <a href="#demo">Charts</a>
            <a href="#privacy">Privacy</a>
            <a href="#open-source">Open source</a>
          </nav>
          <a className="btn btn-dark btn-sm" href={DOWNLOAD}><DownloadIcon />Download</a>
        </div>
      </Nav>

      <main id="top">
        {/* Hero */}
        <section className="hero">
          <div className="hero-grid" aria-hidden="true" />
          <div className="wrap hero-copy">
            <a className="pill" href={`${REPO}/releases/tag/v0.4.0`}>
              <span className="pill-dot" />New in 0.4: see what was running, and when
              <span className="pill-arrow" aria-hidden="true">→</span>
            </a>
            <h1>Know exactly what<br /> your Mac is doing.</h1>
            <p className="lede">
              Gauge is a native system monitor with live readings, charts you can hover, and history that never leaves your Mac.
            </p>
            <div className="cta-row">
              <a className="btn btn-dark" href={DOWNLOAD}><DownloadIcon />Download for Mac</a>
              <a className="btn btn-light" href={REPO}><GitHubMark />View on GitHub</a>
            </div>
            <p className="fine">Free and open source · macOS 26 or later on Apple silicon</p>
          </div>

          <div className="wrap hero-stage">
            <div className="stage-frame">
              <figure className="window">
                <div className="window-bar">
                  <span className="lights" aria-hidden="true"><i /><i /><i /></span>
                  <span className="window-title">
                    <Image src="/assets/mark.svg" width={16} height={16} alt="" unoptimized />Gauge <em>Live</em>
                  </span>
                </div>
                <Image className="screenshot" src="/assets/overview-0.3.png" width={2880} height={1800} priority
                       sizes="(max-width: 1248px) 100vw, 1200px"
                       alt="Gauge overview: six vitals laid out as channels with colour-coded scales and traces, a Worth a look notice, ring breakdowns and the floating navigation island" />
              </figure>
              <figure className="float float-apps">
                <Image className="screenshot" src="/assets/top-apps.png" width={1440} height={580} sizes="400px" loading="eager"
                       alt="Top apps by CPU, with Google Chrome, Java and Gauge at the top" />
              </figure>
            </div>
            <p className="caption">Real readings from a MacBook Air (Apple M5).</p>
          </div>
        </section>

        {/* Metric strip */}
        <section className="vitals-strip" aria-label="What Gauge measures">
          <div className="wrap strip">
            {vitals.map(([name, detail, color]) => (
              <div className="strip-item" key={name} style={tone(color)}><b>{name}</b><span>{detail}</span></div>
            ))}
          </div>
        </section>

        {/* Overview feature */}
        <section className="section" id="features">
          <div className="wrap split">
            <div className="split-copy">
              <p className="eyebrow">Overview</p>
              <h2>Six vitals.<br /> One glance.</h2>
              <p>
                Every reading sits side by side like a channel on a mixing desk: a large monospaced value, a tick-mark
                scale and a fine trace, each in its own colour. Click any channel to open its page.
              </p>
              <ul className="ticks">
                <li>Updates every 2 seconds</li>
                <li>Orange is reserved for anything that needs attention</li>
                <li>Plain-language notices when something&apos;s worth a look</li>
              </ul>
            </div>
            <figure className="window window-flat split-media">
              <Image className="screenshot" src="/assets/channels-0.3.png" width={2880} height={620} sizes="(max-width: 1080px) 100vw, 700px"
                     alt="Six channels: CPU, Memory, GPU, Disk, Network and Battery, each with a readout, scale, trace and readings" />
            </figure>
          </div>
        </section>

        {/* Menu bar */}
        <section className="section" id="menu-bar">
          <div className="wrap split split-flip">
            <div className="split-copy">
              <p className="eyebrow">Menu bar</p>
              <h2>Always one<br /> click away.</h2>
              <p>
                CPU sits in your menu bar. Click it for all six vitals and anything worth a look, without opening a window.
              </p>
              <ul className="ticks">
                <li>Closing the window keeps Gauge running</li>
                <li>About 1% of a core with the window closed</li>
                <li>Turn it off in Settings if you&apos;d rather not</li>
              </ul>
            </div>
            <div className="split-media menubar-stage">
              <figure className="window window-flat menubar-shot">
                <Image className="screenshot" src="/assets/menubar.png" width={600} height={664} sizes="320px"
                       alt="The menu bar panel: CPU, Memory, GPU, Disk, Network and Battery as rows with scales and readouts, a dev servers notice, and Open Gauge, Settings and Quit buttons" />
              </figure>
            </div>
          </div>
        </section>

        {/* Interactive demo */}
        <section className="section section-tint" id="demo">
          <div className="wrap">
            <div className="section-head">
              <p className="eyebrow">Metric pages</p>
              <h2>Hover any moment.</h2>
              <p>Each vital opens a page with a large chart, ranges from live to seven days of saved history, and a readout that follows your pointer.</p>
            </div>
            <ChartDemo />
          </div>
        </section>

        {/* Details */}
        <section className="section">
          <div className="wrap">
            <div className="section-head">
              <p className="eyebrow">Details</p>
              <h2>Everything you&apos;d look for.<br /> Nothing you wouldn&apos;t.</h2>
            </div>
            <div className="bento">
              <article className="card card-wide">
                <div className="card-copy">
                  <h3>Worth a look</h3>
                  <p>Gauge tells you in plain words when memory pressure rises, an app pins a core, the disk fills up, or dev servers are left running.</p>
                </div>
                <div className="card-media fill">
                  <Image src="/assets/notice-0.3.png" width={1900} height={240} sizes="(max-width: 760px) 100vw, 800px"
                         alt="A notice reading: 4 dev servers are running, with their ports and memory use" />
                </div>
              </article>
              <article className="card">
                <div className="card-copy">
                  <h3>Apps, not processes</h3>
                  <p>Helpers are grouped under their app, so Chrome is one row, not forty.</p>
                </div>
                <div className="card-media">
                  <Image src="/assets/top-apps-mem.png" width={1440} height={580} sizes="(max-width: 760px) 100vw, 400px"
                         alt="Top apps by memory with bars and sizes" />
                </div>
              </article>
              <article className="card card-wide">
                <div className="card-copy">
                  <h3>Right now, in rings</h3>
                  <p>Memory by type, memory by app, CPU by app and the startup disk, each in its metric&apos;s colour.</p>
                </div>
                <div className="card-media">
                  <Image src="/assets/rings.png" width={2880} height={1000} sizes="(max-width: 760px) 100vw, 800px"
                         alt="Ring charts for memory by type, memory by app, CPU by app and the startup disk" />
                </div>
              </article>
              <article className="card">
                <div className="card-copy">
                  <h3>Two lines when it matters</h3>
                  <p>Network shows download and upload; Disk shows read and write.</p>
                </div>
                <div className="card-media fill">
                  <Image src="/assets/chart-zoom.png" width={1250} height={900} sizes="(max-width: 760px) 100vw, 400px"
                         alt="Network chart with download as a solid line and upload as a dashed line, and a hover readout showing both" />
                </div>
              </article>
            </div>
          </div>
        </section>

        {/* Privacy */}
        <section className="section privacy" id="privacy">
          <div className="wrap">
            <div className="section-head">
              <p className="eyebrow eyebrow-light">Privacy</p>
              <h2>History stays on your Mac.</h2>
              <p>Gauge saves a reading every 10 seconds to a single file on your Mac, and never uploads it.</p>
            </div>
            <div className="privacy-grid">
              <div className="fact">
                <span className="fact-icon" style={tone("var(--net)")}><NoNetworkIcon /></span>
                <h3>Nothing sent about you</h3>
                <p>No analytics, telemetry, account or sync. The only request Gauge makes is an optional update check.</p>
              </div>
              <div className="fact">
                <span className="fact-icon" style={tone("var(--cpu)")}><DatabaseIcon /></span>
                <h3>One local file</h3>
                <p>A small SQLite database you can open, export or delete whenever you like.</p>
              </div>
              <div className="fact">
                <span className="fact-icon" style={tone("var(--mem)")}><SlidersIcon /></span>
                <h3>You choose how long</h3>
                <p>Keep 1 to 90 days, reveal the file in Finder, or clear it all from Settings.</p>
              </div>
            </div>
            <div className="path">
              <span className="path-dot" />
              <code>~/Library/Application Support/Gauge/history.sqlite</code>
            </div>
          </div>
        </section>

        {/* Native */}
        <section className="section">
          <div className="wrap">
            <div className="section-head">
              <p className="eyebrow">Native</p>
              <h2>Built the Mac way.</h2>
              <p>No Electron, no web view, no helper with admin rights. Public macOS interfaces, SwiftUI, and Sparkle for updates.</p>
            </div>
            <div className="native-grid">
              <div className="native"><b>SwiftUI</b><span>A native app for macOS 26, with Swift Charts for every graph.</span></div>
              <div className="native"><b>No admin rights</b><span>Readings come from Mach, sysctl, IOKit, libproc and CoreAudio.</span></div>
              <div className="native"><b>Light on your Mac</b><span>About 1% of a core with the window closed. It keeps recording, but stops drawing until you look.</span></div>
              <div className="native"><b>Signed updates</b><span>Gauge asks before checking, and verifies every update&apos;s signature before installing it.</span></div>
            </div>
          </div>
        </section>

        {/* Open source */}
        <section className="section" id="open-source">
          <div className="wrap">
            <div className="cta-card">
              <Image className="cta-icon" src="/assets/icon.png" width={96} height={96} alt="Gauge app icon" />
              <h2>Get Gauge.</h2>
              <p>Free, open source and MIT licensed.</p>
              <div className="cta-row">
                <a className="btn btn-dark" href={DOWNLOAD}><DownloadIcon />Download for Mac</a>
                <a className="btn btn-light" href={`${REPO}/releases`}>All releases</a>
              </div>
              <ol className="steps">
                <li><span><b>Open Gauge.dmg</b> and drag Gauge to Applications.</span></li>
                <li><span><b>Open Gauge.</b> If macOS says it can&apos;t verify the developer, go to System Settings › Privacy &amp; Security and click <b>Open Anyway</b>. You only do this once.</span></li>
                <li><span><b>Stay current.</b> Gauge offers new versions itself, or use Gauge › Check for Updates.</span></li>
              </ol>
              <p className="or">Or build it from source</p>
              <div className="code" role="group" aria-label="Build commands">
                <pre>
                  <span className="prompt">$ </span>git clone https://github.com/byalex33/gauge.git{"\n"}
                  <span className="prompt">$ </span>cd gauge/app &amp;&amp; ./build.sh --open
                </pre>
                <CopyButton text={BUILD} />
              </div>
              <p className="fine">Requires macOS 26 or later on Apple silicon. <a href={REPO}>Star it on GitHub</a> to follow along.</p>
            </div>
          </div>
        </section>
      </main>

      <footer className="footer">
        <div className="wrap footer-inner">
          <div className="footer-brand">
            <Image src="/assets/icon.png" width={22} height={22} alt="" />
            <span>Gauge</span>
            <span className="footer-muted">History stays on your Mac.</span>
          </div>
          <nav className="footer-links" aria-label="Footer">
            <a href={REPO}>GitHub</a>
            <a href={`${REPO}/blob/main/LICENSE`}>MIT License</a>
            <a href="#privacy">Privacy</a>
          </nav>
          <p className="footer-muted">© {year} Alex. This site has no cookies or analytics.</p>
        </div>
      </footer>
      <RevealOnScroll />
    </>
  );
}
