# Gauge history database

Gauge keeps its history in one SQLite file on your Mac:

```
~/Library/Application Support/Gauge/history.sqlite
```

Nothing uploads, syncs or reads this file except Gauge. You can open it yourself to check what's stored, or to run your own queries. The file uses WAL mode, so open it with `-readonly` while Gauge is running. That way your queries never block Gauge's writes.

```sh
sqlite3 -readonly ~/Library/Application\ Support/Gauge/history.sqlite
```

Gauge deletes rows older than the retention period you choose in Settings (1, 7, 30 or 90 days). The one exception is `daily`, which holds one tiny row a day and is kept for two years so battery health can show a trend over months. **Clear History** empties every table.

## Tables

### `samples`

One averaged reading every 10 seconds while Gauge is running. Gaps mean Gauge wasn't running.

| Column | Type | Meaning |
| --- | --- | --- |
| `t` | INTEGER, primary key | Unix time in seconds, at the end of the 10-second window |
| `cpu` | REAL | CPU load, percent of all cores (0–100) |
| `mem` | REAL | Memory in use, bytes (app + wired + compressed) |
| `mem_total` | REAL | Installed memory, bytes |
| `gpu` | REAL | GPU load, percent (0 when the GPU doesn't report it) |
| `down` | REAL | Download rate, bytes per second |
| `up` | REAL | Upload rate, bytes per second |
| `disk_read` | REAL | Disk read rate, bytes per second |
| `disk_write` | REAL | Disk write rate, bytes per second |
| `battery` | REAL, nullable | Battery charge, percent; NULL on Macs without a battery |

### `app_cpu`

CPU time each app used, summed per hour. Gauge groups helper processes under their app, and system processes under "macOS".

| Column | Type | Meaning |
| --- | --- | --- |
| `hour` | INTEGER | Unix time divided by 3600 (hours since 1970, UTC) |
| `app` | TEXT | App name, as the process list shows it |
| `seconds` | REAL | CPU seconds used in that hour (can exceed 3600 across several cores) |

Primary key: `(hour, app)`.

### `moments`

The flight recorder: the five busiest apps by CPU and the five by memory for each `samples` row.

| Column | Type | Meaning |
| --- | --- | --- |
| `t` | INTEGER, primary key | Same Unix time as the matching `samples` row |
| `apps` | TEXT | Comma-separated `id:cpu:memory` items: `id` refers to `app_names`, `cpu` is tenths of a percent of one core, `memory` is megabytes |

### `app_names`

App names referenced from `moments`, stored once.

| Column | Type | Meaning |
| --- | --- | --- |
| `id` | INTEGER, primary key | Referenced by `moments.apps` |
| `name` | TEXT, unique | App name, as the process list shows it |

### `events`

Things that happened, shown as markers on the Timeline.

| Column | Type | Meaning |
| --- | --- | --- |
| `t` | INTEGER | Unix time in seconds |
| `kind` | TEXT | `sleep`, `wake`, `launch`, `quit` or `thermal` |
| `detail` | TEXT | App name for `launch` and `quit`; `Nominal`, `Fair`, `Serious` or `Critical` for `thermal` |

### `daily`

One row a day for long-term trends. Kept for two years.

| Column | Type | Meaning |
| --- | --- | --- |
| `day` | INTEGER, primary key | Unix time of local midnight starting the day |
| `battery_health` | REAL, nullable | Maximum capacity, percent of design |
| `battery_cycles` | INTEGER, nullable | Battery cycle count |
| `disk_used` | REAL, nullable | Startup disk used, bytes |
| `disk_total` | REAL, nullable | Startup disk size, bytes |

These tables are defined in `app/Sources/Gauge/HistoryStore.swift` and `HistoryStore+Recorder.swift`. Run `.schema` in `sqlite3` to see them exactly.

## Example queries

Last five readings, in local time:

```sql
SELECT datetime(t, 'unixepoch', 'localtime') AS time,
       round(cpu, 1) AS cpu_percent,
       round(mem / 1073741824.0, 2) AS memory_gb
FROM samples ORDER BY t DESC LIMIT 5;
```

Hourly CPU average and peak over the last 24 hours:

```sql
SELECT strftime('%H:00', min(t), 'unixepoch', 'localtime') AS hour,
       round(avg(cpu), 1) AS average, round(max(cpu), 1) AS peak
FROM samples
WHERE t >= strftime('%s', 'now') - 86400
GROUP BY t / 3600 ORDER BY min(t);
```

Apps that used the most CPU time today, in minutes:

```sql
SELECT app, round(sum(seconds) / 60.0, 1) AS cpu_minutes
FROM app_cpu
WHERE hour >= strftime('%s', 'now', 'localtime', 'start of day', 'utc') / 3600
GROUP BY app ORDER BY cpu_minutes DESC LIMIT 10;
```

Busiest download minute this week:

```sql
SELECT strftime('%Y-%m-%d %H:%M', min(t), 'unixepoch', 'localtime') AS minute,
       round(avg(down) / 1048576.0, 2) AS download_mb_per_s
FROM samples
WHERE t >= strftime('%s', 'now') - 7 * 86400
GROUP BY t / 60 ORDER BY avg(down) DESC LIMIT 1;
```

What happened in the last day (sleep, wake, apps opening and quitting, thermal changes):

```sql
SELECT datetime(t, 'unixepoch', 'localtime') AS time, kind, detail
FROM events WHERE t >= strftime('%s', 'now') - 86400 ORDER BY t;
```

Battery health over time:

```sql
SELECT date(day, 'unixepoch', 'localtime') AS day, battery_health, battery_cycles
FROM daily ORDER BY day;
```

Export the last day as CSV:

```sh
sqlite3 -readonly -header -csv ~/Library/Application\ Support/Gauge/history.sqlite \
  "SELECT datetime(t,'unixepoch','localtime') AS time, cpu, mem, down, up FROM samples
   WHERE t >= strftime('%s','now') - 86400 ORDER BY t;" > gauge-day.csv
```

To read history without SQL, turn on **Let local tools read Gauge** in Settings and run `gauge history cpu --minutes 60`, or use the `get_history` MCP tool.
