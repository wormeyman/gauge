"use client";

import { useMemo, useRef, useState, type PointerEvent } from "react";

// Interactive chart demo with sample data shaped like real readings: 5 minutes at one reading every 2 seconds.
const N = 151;
const STEP_SECONDS = 2;
const W = 1000;
const H = 300;

type MetricKey = "cpu" | "mem" | "net";

type Metric = {
  label: string;
  series: string;
  tone: string;
  data: number[];
  max: number;
  format: (v: number) => string;
  big: (v: number) => [string, string];
};

function random(seed: number) {
  let s = seed;
  return () => (s = (s * 16807) % 2147483647) / 2147483647;
}

function sample(kind: MetricKey): number[] {
  const r = random(kind === "cpu" ? 7 : kind === "mem" ? 11 : 23);
  const out: number[] = [];
  let v = kind === "cpu" ? 18 : kind === "mem" ? 12.4 : 40;
  for (let i = 0; i < N; i++) {
    if (kind === "cpu") {
      v += (r() - 0.5) * 6 + (18 - v) * 0.18;
      const spike = i % 37 === 12 || i % 53 === 30 ? 28 + r() * 20 : 0;
      out.push(Math.max(3, Math.min(96, v + spike)));
    } else if (kind === "mem") {
      v += (r() - 0.5) * 0.12 + (i > 90 && i < 110 ? 0.03 : 0) - (i > 125 ? 0.02 : 0);
      out.push(Math.max(9, Math.min(15.6, v)));
    } else {
      const burst = i % 29 === 5 || i % 41 === 20;
      v = burst ? 4000 + r() * 22000 : Math.max(8, v * 0.35 + 20 + r() * 60);
      out.push(v);
    }
  }
  return out;
}

function rate(kB: number) {
  return kB < 1000 ? `${Math.round(kB)} kB/s` : `${(kB / 1000).toFixed(1)} MB/s`;
}

function niceCeil(v: number) {
  const e = 10 ** Math.floor(Math.log10(v));
  for (const s of [1, 2, 2.5, 5, 10]) if (s * e >= v) return s * e;
  return 10 * e;
}

function buildMetrics(): Record<MetricKey, Metric> {
  const net = sample("net");
  return {
    cpu: { label: "CPU", series: "CPU", tone: "#5aa7ff", data: sample("cpu"), max: 100,
           format: v => `${Math.round(v)}%`, big: v => [String(Math.round(v)), "%"] },
    mem: { label: "Memory", series: "Used", tone: "#b08cff", data: sample("mem"), max: 16,
           format: v => `${v.toFixed(2)} GB`, big: v => [v.toFixed(2), "GB"] },
    net: { label: "Network", series: "Download", tone: "#3fd0a8", data: net, max: niceCeil(Math.max(...net) * 1.15),
           format: rate, big: v => rate(v).split(" ") as [string, string] },
  };
}

/** Relative time label, e.g. "−2m 14s", so the demo renders the same on server and client. */
function ago(index: number) {
  const s = (N - 1 - index) * STEP_SECONDS;
  if (s === 0) return "now";
  const m = Math.floor(s / 60), sec = s % 60;
  if (!m) return `−${sec}s`;
  return sec ? `−${m}m ${sec}s` : `−${m} min`;
}

/** Catmull–Rom spline with clamped control points, so peaks don't overshoot (like .monotone). */
function smoothPath(points: [number, number][]) {
  let d = `M${points[0][0]},${points[0][1]}`;
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[i - 1] ?? points[i], p1 = points[i], p2 = points[i + 1], p3 = points[i + 2] ?? points[i + 1];
    const lo = Math.min(p1[1], p2[1]), hi = Math.max(p1[1], p2[1]);
    const c1y = Math.min(hi, Math.max(lo, p1[1] + (p2[1] - p0[1]) / 6));
    const c2y = Math.min(hi, Math.max(lo, p2[1] - (p3[1] - p1[1]) / 6));
    const c1x = p1[0] + (p2[0] - p0[0]) / 6, c2x = p2[0] - (p3[0] - p1[0]) / 6;
    d += ` C${c1x.toFixed(1)},${c1y.toFixed(1)} ${c2x.toFixed(1)},${c2y.toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
  }
  return d;
}

export default function ChartDemo() {
  const metrics = useMemo(buildMetrics, []);
  const [key, setKey] = useState<MetricKey>("cpu");
  const [hover, setHover] = useState<number | null>(null);
  const svgRef = useRef<SVGSVGElement>(null);
  const m = metrics[key];

  const { line, area, stats } = useMemo(() => {
    const pts = m.data.map((v, i) => [(i / (N - 1)) * W, H - (v / m.max) * H] as [number, number]);
    const d = smoothPath(pts);
    const avg = m.data.reduce((a, b) => a + b, 0) / N;
    return { line: d, area: `${d} L${W},${H} L0,${H} Z`, stats: { avg, low: Math.min(...m.data), peak: Math.max(...m.data) } };
  }, [m]);

  const [now, unit] = m.big(m.data[N - 1]);

  function track(e: PointerEvent<HTMLDivElement>) {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) return;
    const x = Math.min(Math.max(e.clientX - rect.left, 0), rect.width);
    setHover(Math.round((x / rect.width) * (N - 1)));
  }

  const hx = hover === null ? 0 : (hover / (N - 1)) * 100;
  const hy = hover === null ? 0 : (1 - m.data[hover] / m.max) * 100;

  return (
    <div className="demo" style={{ ["--tone" as string]: m.tone }}>
      <div className="demo-top">
        <div className="demo-tabs" role="tablist" aria-label="Demo metric">
          {(Object.keys(metrics) as MetricKey[]).map(k => (
            <button key={k} role="tab" aria-selected={k === key} onClick={() => { setKey(k); setHover(null); }}>
              {metrics[k].label}
            </button>
          ))}
        </div>
        <span className="demo-note">Interactive demo · sample data</span>
      </div>

      <div className="demo-summary">
        <div className="demo-value">{now}<small>{unit}</small></div>
        <dl className="demo-stats">
          <div><dt>Average</dt><dd>{m.format(stats.avg)}</dd></div>
          <div><dt>Low</dt><dd>{m.format(stats.low)}</dd></div>
          <div><dt>Peak</dt><dd>{m.format(stats.peak)}</dd></div>
        </dl>
      </div>

      <div className="demo-chart" onPointerMove={track} onPointerDown={track} onPointerLeave={() => setHover(null)}>
        <svg ref={svgRef} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
          {[0.25, 0.5, 0.75, 1].map(f => (
            <line key={f} className="demo-grid-line" x1={0} x2={W} y1={H - f * H} y2={H - f * H} />
          ))}
          <line className="demo-grid-line" x1={0} x2={W} y1={H} y2={H} />
          <path className="demo-area" d={area} />
          <path className="demo-line" d={line} />
        </svg>
        <div className="demo-y" aria-hidden="true">
          {[0.25, 0.5, 0.75, 1].map(f => <span key={f} style={{ top: `${(1 - f) * 100}%` }}>{m.format(m.max * f)}</span>)}
        </div>
        {hover !== null && (
          <>
            <div className="demo-cross" style={{ left: `${hx}%` }} />
            <div className="demo-dot" style={{ left: `${hx}%`, top: `${hy}%` }} />
            <div className="demo-tip" style={{ left: `clamp(80px, ${hx}%, calc(100% - 80px))` }} role="status">
              <div className="t">{ago(hover)}</div>
              <div className="r"><i />{m.series}<b>{m.format(m.data[hover])}</b></div>
            </div>
          </>
        )}
      </div>
      <div className="demo-x" aria-hidden="true">
        {[0, 0.2, 0.4, 0.6, 0.8, 1].map(f => <span key={f}>{ago(Math.round(f * (N - 1)))}</span>)}
      </div>
    </div>
  );
}
