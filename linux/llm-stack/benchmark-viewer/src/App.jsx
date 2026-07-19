import React, { useState, useEffect } from 'react'
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
  ResponsiveContainer, Cell,
} from 'recharts'

const DATA_URL = './benchmark_results/_manifest.json'

const COLORS = ['#6366f1', '#8b5cf6', '#a855f7', '#d946ef', '#ec4899']
const STATUS_COLORS = { success: '#22c55e', error: '#ef4444' }

function initFetch(url) {
  const [data, setData] = useState(null)
  const [err, setErr] = useState(null)
  useEffect(() => {
    fetch(url)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json() })
      .then(setData)
      .catch(setErr)
  }, [url])
  return [data, err]
}

function HardwareCard({ hw }) {
  if (!hw) return null
  const rows = [
    { label: 'OS', value: `${hw.os} ${hw.os_release}` },
    { label: 'Architecture', value: hw.architecture },
    { label: 'CPU', value: hw.cpu_model || 'unknown' },
    { label: 'Cores / Threads', value: `${hw.cpu_physical_cores ?? '?'} cores / ${hw.cpu_total_threads ?? '?'} threads` },
    { label: 'RAM', value: `${hw.ram_total_gb} GB` },
    { label: 'Container', value: hw.in_container ? 'Yes' : 'No' },
    { label: 'Ollama Host', value: hw.ollama_host },
  ]
  return (
    <div className="card hardware-card">
      <h2>Hardware</h2>
      <table className="kv-table">
        <tbody>
          {rows.map(r => (
            <tr key={r.label}><td className="kv-label">{r.label}</td><td className="kv-value">{r.value}</td></tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function ModelCard({ title, model, generated, configs }) {
  const totalReqs = configs.reduce((s, c) => s + c.results.filter(r => !r.error).length, 0)
  const totalErrs = configs.reduce((s, c) => s + c.results.filter(r => r.error).length, 0)
  const avgTps = configs.length
    ? (configs.reduce((s, c) => {
        const ok = c.results.filter(r => r.tokens_per_sec)
        return s + ok.reduce((ss, r) => ss + r.tokens_per_sec, 0) / (ok.length || 1)
      }, 0) / configs.length).toFixed(1)
    : '-'
  return (
    <div className="card summary-card">
      <h2>{title}</h2>
      <div className="summary-stats">
        <div className="stat"><span className="stat-value">{model}</span><span className="stat-label">Model</span></div>
        <div className="stat"><span className="stat-value">{configs.length}</span><span className="stat-label">Configs</span></div>
        <div className="stat"><span className="stat-value">{totalReqs}</span><span className="stat-label">Requests</span></div>
        <div className="stat"><span className="stat-value">{totalErrs}</span><span className="stat-label">Errors</span></div>
        <div className="stat"><span className="stat-value">{avgTps}</span><span className="stat-label">Avg T/s</span></div>
        <div className="stat"><span className="stat-value">{new Date(generated).toLocaleDateString()}</span><span className="stat-label">Date</span></div>
      </div>
    </div>
  )
}

function ComparisonTable({ configs }) {
  const rows = configs.map(c => {
    const ok = c.results.filter(r => !r.error)
    const tps = ok.length ? (ok.reduce((s, r) => s + r.tokens_per_sec, 0) / ok.length).toFixed(1) : '-'
    const lat = ok.length ? (ok.reduce((s, r) => s + r.latency_s, 0) / ok.length).toFixed(1) : '-'
    const cpu = ok.length ? (ok.reduce((s, r) => s + r.cpu_percent, 0) / ok.length).toFixed(1) : '-'
    const ram = ok.length ? (ok.reduce((s, r) => s + r.ram_used_gb, 0) / ok.length).toFixed(1) : '-'
    const comp = ok.reduce((s, r) => s + (r.completion_tokens || 0), 0)
    const prom = ok.reduce((s, r) => s + (r.prompt_tokens || 0), 0)
    return { label: c.label, tps, lat, cpu, ram, comp, prom, numOk: ok.length }
  })
  return (
    <div className="card full-width">
      <h2>Config Comparison</h2>
      <div className="table-wrap">
        <table className="data-table">
          <thead>
            <tr>
              <th>Config</th>
              <th>num_ctx</th>
              <th>max_tokens</th>
              <th>T/s</th>
              <th>Latency (s)</th>
              <th>CPU %</th>
              <th>RAM (GB)</th>
              <th>Comp. Tokens</th>
              <th>Prompt Tokens</th>
              <th>OK</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => {
              const ctx = r.label.match(/ctx(\d+)/)?.[1] ?? '?'
              const tok = r.label.match(/tok(\d+)/)?.[1] ?? '?'
              return (
                <tr key={r.label} style={{ background: i % 2 === 0 ? 'var(--bg-alt)' : undefined }}>
                  <td><code>{r.label}</code></td>
                  <td>{ctx}</td>
                  <td>{tok}</td>
                  <td className="num">{r.tps}</td>
                  <td className="num">{r.lat}</td>
                  <td className="num">{r.cpu}</td>
                  <td className="num">{r.ram}</td>
                  <td className="num">{r.comp}</td>
                  <td className="num">{r.prom}</td>
                  <td className="num">{r.numOk}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function ChartSection({ configs, title, dataKey, label, unit, decimals }) {
  const data = configs.map((c, i) => {
    const ok = c.results.filter(r => !r.error)
    const avg = ok.length ? ok.reduce((s, r) => s + (r[dataKey] || 0), 0) / ok.length : 0
    return { name: c.label, value: parseFloat(avg.toFixed(decimals ?? 1)), fill: COLORS[i % COLORS.length] }
  })
  return (
    <div className="card chart-card">
      <h2>{title}</h2>
      <ResponsiveContainer width="100%" height={300}>
        <BarChart data={data} margin={{ top: 10, right: 30, left: 0, bottom: 60 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
          <XAxis dataKey="name" angle={-25} textAnchor="end" tick={{ fontSize: 11 }} interval={0} />
          <YAxis label={{ value: unit, angle: -90, position: 'insideLeft', style: { fontSize: 12 } }} />
          <Tooltip formatter={v => [`${v} ${unit}`, label]} />
          <Bar dataKey="value" name={label} radius={[4, 4, 0, 0]}>
            {data.map((e, i) => <Cell key={i} fill={e.fill} />)}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  )
}

function ConfigDetail({ config }) {
  const [expanded, setExpanded] = useState(false)
  const ok = config.results.filter(r => !r.error)
  const errs = config.results.filter(r => r.error)
  return (
    <div className="card config-detail">
      <div className="config-detail-header" onClick={() => setExpanded(!expanded)}>
        <h3><code>{config.label}</code></h3>
        <span className="toggle">{expanded ? '▲' : '▼'}</span>
      </div>
      {expanded && (
        <div className="config-detail-body">
          <table className="kv-table">
            <tbody>
              {Object.entries(config.config?.extra_params || {}).map(([k, v]) => (
                <tr key={k}><td className="kv-label">{k}</td><td className="kv-value">{JSON.stringify(v)}</td></tr>
              ))}
              {Object.entries(config.config || {}).filter(([k]) => !['extra_params', 'prompts_requested', 'prompts_completed'].includes(k)).map(([k, v]) => (
                <tr key={k}><td className="kv-label">{k}</td><td className="kv-value">{JSON.stringify(v)}</td></tr>
              ))}
            </tbody>
          </table>
          {ok.length > 0 && (
            <>
              <h4>Per-Prompt Results</h4>
              <div className="table-wrap">
                <table className="data-table">
                  <thead>
                    <tr>
                      <th>#</th>
                      <th>Prompt</th>
                      <th>PT</th>
                      <th>CT</th>
                      <th>T/s</th>
                      <th>Lat (s)</th>
                      <th>CPU%</th>
                      <th>RAM (GB)</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ok.map(r => (
                      <tr key={r.prompt_index} style={{ background: r.prompt_index % 2 === 0 ? 'var(--bg-alt)' : undefined }}>
                        <td>{r.prompt_index}</td>
                        <td style={{ maxWidth: 300, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={r.prompt_preview}>{r.prompt_preview}</td>
                        <td className="num">{r.prompt_tokens}</td>
                        <td className="num">{r.completion_tokens}</td>
                        <td className="num">{r.tokens_per_sec?.toFixed(1)}</td>
                        <td className="num">{r.latency_s?.toFixed(1)}</td>
                        <td className="num">{r.cpu_percent?.toFixed(1)}</td>
                        <td className="num">{r.ram_used_gb?.toFixed(2)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
          {errs.length > 0 && (
            <>
              <h4>Errors ({errs.length})</h4>
              <ul className="error-list">
                {errs.map((r, i) => (
                  <li key={i}><strong>#{r.prompt_index}</strong>: {r.error}</li>
                ))}
              </ul>
            </>
          )}
        </div>
      )}
    </div>
  )
}

function useTheme() {
  const getInitial = () => {
    const stored = localStorage.getItem('kataglyphis-theme')
    if (stored) return stored
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
  }
  const [theme, setTheme] = useState(getInitial)
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme)
    localStorage.setItem('kataglyphis-theme', theme)
  }, [theme])
  return [theme, () => setTheme(t => t === 'light' ? 'dark' : 'light')]
}

function App() {
  const [data, err] = initFetch(DATA_URL)
  const [selectedIdx, setSelectedIdx] = useState(null)
  const [theme, toggleTheme] = useTheme()

  if (err) return (
    <div className="app">
      <div className="error-banner">
        <strong>Failed to load benchmark data.</strong>
        <p>{err.message}</p>
        <p>Make sure <code>benchmark_results/_manifest.json</code> exists relative to the app.</p>
        <p>Run <code>bash run_benchmarks.sh</code> first, then rebuild the viewer.</p>
      </div>
    </div>
  )
  if (!data) return (
    <div className="app">
      <div className="loading">Loading benchmark data…</div>
    </div>
  )

  const { title, model, generated, host_hardware: hw, configs } = data
  const selected = selectedIdx !== null ? configs[selectedIdx] : null

  return (
    <div className="app">
      <header className="app-header">
        <div>
          <h1>LLM Benchmark Viewer</h1>
          <p className="subtitle">{title || 'Model benchmarks'}</p>
        </div>
        <button className="theme-toggle" onClick={toggleTheme}>
          {theme === 'light' ? '🌙 Dark' : '☀️ Light'}
        </button>
      </header>

      <div className="layout-top">
        <ModelCard title={title} model={model} generated={generated} configs={configs} />
        <HardwareCard hw={hw} />
      </div>

      <ComparisonTable configs={configs} />

      <div className="chart-grid">
        <ChartSection configs={configs} title="Tokens per Second" dataKey="tokens_per_sec" label="T/s" unit="tok/s" />
        <ChartSection configs={configs} title="Average Latency" dataKey="latency_s" label="Latency" unit="s" />
        <ChartSection configs={configs} title="CPU Usage" dataKey="cpu_percent" label="CPU" unit="%" />
        <ChartSection configs={configs} title="RAM Usage" dataKey="ram_used_gb" label="RAM" unit="GB" decimals={2} />
      </div>

      <div className="card full-width">
        <h2>Drill Down</h2>
        <div className="drill-selector">
          {configs.map((c, i) => (
            <button
              key={c.label}
              className={`chip ${selectedIdx === i ? 'active' : ''}`}
              onClick={() => setSelectedIdx(selectedIdx === i ? null : i)}
            >
              {c.label}
            </button>
          ))}
        </div>
        {selected && <ConfigDetail config={selected} />}
      </div>

      <footer className="app-footer">
        Generated {new Date(generated).toLocaleString()} &middot; LLM Stack Benchmark Suite
      </footer>
    </div>
  )
}

export default App
