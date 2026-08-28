# Benchmark Suite: dtpipe vs the field

Competitive performance benchmark comparing **6 data-transfer tools** across
12 pipeline scenarios (Parquet, CSV, PostgreSQL, SQL Server, Oracle).

---

## Tools Compared

| Tool | Positioning | Implementation |
|------|-------------|----------------|
| **dtpipe** | Streaming ETL/ELT CLI with transformations | C# / .NET |
| **pandas + SQLAlchemy** | DataFrame-based in-memory data transfer | Python |
| **Meltano** | Full ELT orchestrator using Singer taps/targets | Python |
| **Sling** | Lightweight data replication engine | Go |
| **ingestr** | CLI data ingestion tool (by Bruin) | Go |
| **native** | Direct database CLI tools (bcp, psql, sqlldr, sqlplus) | C / shell |

---

## Architecture

All benchmark executions happen **inside a unified Docker container** named `benchmark-test` (except for the target database services which run in their own dedicated containers).
Nothing is installed permanently on the host machine.

```
Host (Linux / macOS / Windows — Git Bash or WSL)
│
├─ benchmarks.sh   ──────────────────────────────────────────┐
│                                                              │
│                                                              ▼  Docker network: dtpipe-benchmark_benchmark-net
│                                             ┌─────────────────────────────────────┐
│   Infrastructure (infra/)                   │  Unified benchmark container        │
│    ┌────────────────────────────┐           │  ┌───────────────────────────────┐  │
│    │ dtpipe-integ-postgres      │◄──────────│  │ benchmark-test                │  │
│    │ dtpipe-integ-mssql         │◄──────────│  │  ├─ dtpipe (.NET 10.0 SDK)    │  │
│    │ dtpipe-integ-oracle        │◄──────────│  │  ├─ pandas (/opt/venv/pandas) │  │
│    └────────────────────────────┘           │  │  ├─ meltano (/opt/venv/meltano)│ │
│                                             │  │  ├─ sling (Go binary)         │  │
│                                             │  │  ├─ ingestr (Go binary)       │  │
│                                             │  │  └─ native (CLIs & OCI)       │  │
│                                             │  └───────────────────────────────┘  │
│                                             └─────────────────────────────────────┘
│
└─ artifacts/                   ← result JSON files, output datasets, reports
```

### Multi-architecture support

Docker images used in this benchmark are all published as **multi-arch manifests**
(`linux/amd64` + `linux/arm64`). Docker automatically pulls the image matching
your host CPU — no configuration needed.

The `benchmark-test` image (which bundles all tools including Oracle Instant Client)
selects the correct Oracle binary at build time based on `uname -m`.

---

## File Structure

```
benchmarks/
├── benchmarks.sh                       # Main orchestrator (bash — Linux / macOS / Git Bash / WSL)
├── README.md                           # This file
├── lib/                                # Utility library (container-runtime, mem-watcher, stats)
├── runners/                            # Tool-specific benchmark runners
│    ├── 01-init-data.sh                # Source dataset generation & DB loading
│    ├── 03-dtpipe.sh                   # dtpipe benchmark runner
│    ├── 03-pandas.sh                   # pandas + SQLAlchemy benchmark runner
│    ├── 03-meltano.sh                  # Meltano (Singer) benchmark runner
│    ├── 03-sling.sh                    # Sling benchmark runner
│    ├── 03-ingestr.sh                  # ingestr benchmark runner
│    ├── 03-native.sh                   # Native tools benchmark runner
│    ├── 04-report.sh                   # Comparative report generator
│    └── 05-compare-baseline.sh         # Macro performance gate (baseline comparison)
├── artifacts/                          # Intermediate results (git-ignored)
│    ├── dtpipe/       dtpipe_report.json
│    ├── pandas/       pandas_report.json
│    ├── meltano/      meltano_report.json
│    ├── sling/        sling_report.json
│    ├── ingestr/      ingestr_report.json
│    ├── native/       native_report.json
│    ├── reports/
│    │    ├── benchmark_report.md
│    │    └── benchmark_report.json
│    ├── source_data_<N>.parquet        (generated)
│    └── source_data_<N>.csv            (generated)
├── baselines/                          # Versioned reference reports for the gate
│    └── macro_perf.json
├── config/
│    ├── benchmark.env                   # DB connection defaults
│    └── docker-compose-benchmark.yml   # Benchmark container definitions
├── docker/
│    └── benchmark-test/      Dockerfile  # Unified image containing all runtimes & venvs
└── scripts/
     ├── benchmarks/
     │    ├── _pandas_bench.py            # pandas/SQLAlchemy benchmark logic
     │    └── _sling_bench.py             # Sling benchmark logic
     └── verify_data.py                  # Post-run data integrity checker
```

---

## Prerequisites

- **Docker** (Desktop or Engine) with the **Compose plugin** (`docker compose`)
- **Windows**: **Git for Windows** (Git Bash) or **WSL** — required to run `.sh` scripts

No other software needs to be installed on the host.

---

## Quick Start

### Linux / macOS / Windows (Git Bash or WSL)

```bash
cd benchmarks/
./benchmarks.sh
```

The script automatically:
1. Starts the DB infrastructure (`infra/`)
2. Builds & starts benchmark containers
3. Initializes the source dataset
4. Runs all 6 tools across all 12 pipelines
5. Generates `artifacts/reports/benchmark_report.md`

---

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--rows NUM` | `1000000` | Number of source rows. Lower it to iterate on the suite, not to publish — see [Fixed cost](#fixed-cost-why-the-default-is-1-000-000-rows). |
| `--repetitions NUM` | `3` | Runs per benchmark |
| `--scope SELECTOR` | `all` | `all`, `transfer` (B01-B15), `transform` (B16-B19), one id (`B07`), or a comma-separated list (`B16,B19`) |
| `--tool SELECTOR` | `all` | `all`, one tool (`dtpipe`), or a comma-separated list (`dtpipe,ingestr`). Unknown names are rejected. |
| `--skip-infra` | _(off)_ | Skip DB infrastructure startup |
| `--infra-compose FILE` | auto | Path to infra docker-compose file |
| `--clean-artifacts` | _(off)_ | Wipe previous output files first |

### Examples

```bash
# Full benchmark with defaults (1 000 000 rows, 3 runs, all tools):
./benchmarks.sh

# More repetitions — tightens the dispersion, lengthens the run:
./benchmarks.sh --repetitions 5

# Smaller and faster, for iterating on the suite itself.
# Not for publication: see "Fixed cost" below.
./benchmarks.sh --rows 250000 --repetitions 3

# Single tool and pipeline (fast debug run):
./benchmarks.sh --tool dtpipe --scope B01 --rows 1000 --repetitions 1

# Baseline run for the performance gate. The gate only ever compares dtpipe, so
# measuring the competitors costs time and buys nothing — dtpipe is about 20 % of
# a full run:
./benchmarks.sh --tool dtpipe

# Head-to-head against the closest competitor only:
./benchmarks.sh --tool dtpipe,ingestr

# Infrastructure already running, clean previous outputs:
./benchmarks.sh --skip-infra --clean-artifacts

# Custom infra compose (e.g., external dtpipe repo):
./benchmarks.sh --infra-compose /path/to/dtpipe/infra/docker-compose.yml
```

> **Note — calling runners directly:**
> `benchmarks.sh` always runs `runners/01-init-data.sh` before any tool benchmark, generating
> the source dataset and DB tables for the requested `--rows` count.
> If you call a runner script directly, the source data for that row count must
> already exist (from a prior `./benchmarks.sh` or `./runners/01-init-data.sh --rows NUM` run).
> Calling `runners/03-sling.sh --rows 1000` when only a `1000000`-row dataset was initialized
> will fail on every DB-source pipeline with "table does not exist".

---

## Benchmark Pipelines

| ID | Description | Source | Target |
|----|-------------|--------|--------|
| **B01** | Parquet → PostgreSQL | `source_data_N.parquet` | PG table |
| **B02** | PostgreSQL → Parquet | PG table | `*_bench_pg_to_pq.parquet` |
| **B03** | CSV → SQL Server | `source_data_N.csv` | MSSQL table |
| **B04** | SQL Server → CSV | MSSQL table | `*_bench_mssql_to_csv.csv` |
| **B05** | Parquet → Oracle | `source_data_N.parquet` | Oracle table |
| **B06** | Oracle → Parquet | Oracle table | `*_bench_oracle_to_pq.parquet` |
| **B07** | CSV → PostgreSQL | `source_data_N.csv` | PG table |
| **B08** | PostgreSQL → CSV | PG table | `*_bench_pg_to_csv.csv` |
| **B09** | Parquet → SQL Server | `source_data_N.parquet` | MSSQL table |
| **B10** | SQL Server → Parquet | MSSQL table | `*_bench_mssql_to_pq.parquet` |
| **B11** | CSV → Oracle | `source_data_N.csv` | Oracle table |
| **B12** | Oracle → CSV | Oracle table | `*_bench_oracle_to_csv.csv` |
| **B13** | PostgreSQL → PostgreSQL | `benchmark_source_N` (bench_reader) | `bench_tgt.*_bench_pg2pg` (bench_writer) |
| **B14** | SQL Server → SQL Server | `benchmark_source_N` (bench_reader) | `bench_tgt.*_bench_mssql2mssql` (bench_writer) |
| **B15** | Oracle → Oracle | `BENCHMARK_SOURCE_N` (bench_reader) | `BENCH_WRITER.*_BENCH_ORA2ORA` (bench_writer) |

B13–B15 use two separate DB accounts — `bench_reader` (read-only on the source table)
and `bench_writer` (write access to a dedicated target schema) — to validate real ETL tool behaviour
with realistic access constraints. Created automatically by `runners/01-init-data.sh`.

Each tool uses its own table/file prefix to avoid conflicts:
`dtpipe_*` · `pandas_*` · `meltano_*` · `sling_*` · `ingestr_*` · `native_*`

### Transformation family (B16-B19) — dtpipe only

| ID | Description | Source | Target |
|----|-------------|--------|--------|
| **B16** | Control, no transformer | `source_data_N.parquet` | `null:` |
| **B17** | Columnar chain: `--fake` + `--filter` + `--mask` | `source_data_N.parquet` | `null:` |
| **B18** | Row chain: `--compute` | `source_data_N.parquet` | `null:` |
| **B19** | Mixed chain, forces a row↔columnar bridge | `source_data_N.parquet` | `null:` |

B01-B15 are pure transfers: they measure how fast data moves between a source and a
target. B16-B19 measure something the other fifteen cannot see — **what a transformer
costs**. Writing to `null:` makes the sink a no-op, so the difference between two
scenarios is transformation work and nothing else.

There is no competitor column here, deliberately. The question these four answer is
internal — regression over time, and one design decision (should `--compute` be
vectorized?) — not how dtpipe places against another tool.

The four are built to subtract from each other:

```
B17 - B16                    cost of the columnar transformers
B18 - B16                    cost of the compute (JavaScript) in row mode
(B19 - B17) - (B18 - B16)    cost of the extra row/columnar round trip
```

The control is what makes the other three subtract from something. Without B16 the
remaining numbers are totals, and a total answers no question.

What keeps the four comparable: same source and same sink; `country != ZZZ` is a
simple filter (columnar fast path) that keeps every row, so all four carry the same
row count end to end; the `--compute` in B18 and B19 is byte-identical and reads the
untouched `email` column; no scenario adds or drops a column.

Run just this family — no DB target is involved, so it is fast:

```bash
./benchmarks.sh --tool dtpipe --scope transform
```

---

## Tool Limitations

> **Not supported** = the tool fundamentally cannot perform this operation (hard limitation).
> **Not implemented** = the tool supports this use case but it has not been configured in this benchmark.

| Tool | Benchmarks | Status | Reason |
|------|------------|--------|--------|
| **Meltano** | B01, B05, B09 (Parquet source) | Not implemented | `tap-parquet` (AE-nv, stable) exists on MeltanoHub but fails on `fixed_size_binary[16]` (UUID column) due to a PyArrow upstream bug — not a design limitation of Meltano |
| **Meltano** | B05, B06, B11, B12 (Oracle) | Not implemented | `tap-oracle` (Silver) and `target-oracle` (Gold) exist on MeltanoHub but are not configured in this benchmark |
| **ingestr** | B05, B11 (→ Oracle target) | Not supported | Oracle is not a supported destination in ingestr ([confirmed in official docs](https://bruin-data.github.io/ingestr/)) |
| **native** | B01, B02, B05, B06, B09, B10 (Parquet ↔ DB) | Not supported | `psql`, `bcp`, `sqlplus`, `sqlldr` have no native Parquet support — they predate the format and only handle text/proprietary binary formats |
| **Meltano** | B14, B15 (intra MSSQL/Oracle) | Not implemented | Not configured in this benchmark |
| **ingestr** | B15 (→ Oracle target) | Not supported | Oracle is not a supported destination in ingestr |
| **pandas** | _(all supported)_ | — | — |
| **dtpipe** | _(all supported)_ | — | — |

---

## Viewing the Report

After a benchmark run the report is available in two formats:

```bash
# Markdown (human-readable):
cat artifacts/reports/benchmark_report.md

# JSON (machine-readable / CI integration):
cat artifacts/reports/benchmark_report.json
```

The report can also be regenerated independently (e.g. after partial runs):

```bash
./runners/04-report.sh --rows 1000000 --repetitions 3
```

### Which statistic the report publishes

Every benchmark is run N times and the report publishes three figures per scenario:

| Figure | Where | Why |
|:---|:---|:---|
| **min** | headline duration table | The reference. Noise on a shared machine is one-sided — scheduling, page-cache warming and neighbour processes can only ever *add* time. The fastest run is therefore the closest estimate of the tool's own cost. |
| avg | dispersion table | Kept for continuity with earlier reports. It integrates the noise the minimum excludes. |
| sample stddev | dispersion table | The point of the whole thing: it says whether a 15 % gap is a regression or the machine breathing. |

The standard deviation is the **sample** one (Bessel-corrected, n-1). With 3 to 5
repetitions the uncorrected form understates dispersion by about 20 %, which would
make the gate look sharper than it is.

A difference between two figures smaller than their standard deviations is not a
result. The report says so in its own Notes section, so a reader who only has the
Markdown still has the rule.

All of it is computed in `lib/stats.sh`, sourced by every `03-*.sh` runner — the
runners no longer each carry their own arithmetic. The machine-readable JSON carries
`min_duration_ms`, `avg_duration_ms`, `stddev_duration_ms`, `runs`,
`avg_peak_mem_mb` and `min_peak_mem_mb` per benchmark.

### Fixed cost: why the default is 1 000 000 rows

Every figure in this report is wall-clock time for a whole process: it contains the
runtime's startup and the source's setup, neither of which scale with the row count.
Measured on the reference machine:

| | Process floor (`--version`) | Measured intercept of a run |
|:---|---:|---:|
| dtpipe (.NET, self-contained) | 132 ms | 235 ms (CSV source) to ~530 ms (Parquet source) |
| sling | 46 ms | — |
| ingestr | 57 ms | — |

At 250 000 rows that used to put **about half** of a Parquet-source dtpipe measurement
into fixed cost, while sling and ingestr start in a third of the time. A share of what
looked like a throughput gap was a runtime-startup gap wearing throughput's clothes.
Raising the default to 1 000 000 rows brings that share down to roughly a quarter.

**It does not eliminate it.** A wall-clock benchmark cannot: the honest fix is to
measure the *slope* — the same scenario at two row counts, reporting the marginal cost
per row and discarding the intercept. That is a real change to the suite (two sizes per
scenario, a different report and gate schema) and it has not been made. Until it is,
read the absolute numbers as containing a few hundred milliseconds that belong to
process startup, and read cross-tool comparisons of *fast* scenarios with that in mind.

Lowering `--rows` for a quick iteration is fine and expected. Publishing numbers taken
that way is not.

### Choosing what to run

The suite serves two jobs, and running the whole field for both is where the time
goes. Measured share of a full run:

| tool | share of measured time | wins (B01-B15) | usable results |
|:---|---:|---:|---:|
| pandas | 40 % | 1 | 14/15 |
| sling | 29 % | 0 | 15/15 |
| dtpipe | 20 % | — | 14/15 |
| ingestr | 6 % | 6 | 11/15 |
| native | 5 % | 7 | 9/15 |

- **Regression gate** — `./benchmarks.sh --tool dtpipe`. The gate compares dtpipe
  against its own past and reads no other tool, so the competitors are pure cost here.
- **Comparative publication** — run the whole field. The tools that lose are what make
  the wins mean anything, and `native` in particular is the cheapest row in the table
  and the most informative: it is not a competitor but the floor, the answer to "how
  much headroom is there".

Prune on cost if you must, never on rank. Dropping a tool because it beats dtpipe
somewhere turns a benchmark into a marketing table.

---

## Performance Gate

`runners/05-compare-baseline.sh` compares a fresh report against a versioned
baseline in `baselines/` and renders a verdict — or refuses to.

```bash
# Record the current report as the reference
./runners/05-compare-baseline.sh --update

# Compare a later run against it
./runners/05-compare-baseline.sh --threshold 15
```

### It refuses across scales, with no override

A baseline is only meaningful against a run at the same row count: duration is roughly
linear in it, so a 250 000-row baseline against a 1 000 000-row run reports a +300 %
"regression" on every scenario. No threshold widening rescues that, so nothing overrides
this refusal — re-record the baseline at the new scale instead. A differing repetition
count is only warned about: more repetitions means more chances at a fast run, so the
minimum drifts down slightly, but the comparison stays meaningful.

### It refuses across machines, on purpose

The baseline records the machine it was measured on (OS, architecture, CPU model,
core count). When the current host does not match, the gate exits 2 and renders **no
verdict at all**.

That is not caution, it is correctness: comparing durations measured on different
hardware does not give a weaker verdict, it gives a misleading one — most of the gap
between the two numbers would be the machine, not the code. `--allow-foreign-host`
overrides it, and then the threshold is clamped to no tighter than 50 %: enough to
catch a factor, never presented as catching a +15 %.

This is why the complete macro suite stays local. It needs Oracle and SQL Server in
containers, which free CI runners cannot host — but the methodological reason stands
on its own: a shared cloud runner has 20-50 % duration variance, so a 15 % gate there
produces random red, not signal. The micro stage that *does* run in CI lives in the
dtpipe repo (`tests/scripts/micro_perf_gate.sh`) and applies the same fingerprint
rule with a deliberately wide threshold.

Exit codes: `0` pass · `1` regression · `2` refused to render a verdict · `3` setup error.

---

## Infrastructure Details

The DB containers are defined in `infra/docker-compose.yml`:

| Container | Image | Port | Role |
|-----------|-------|------|------|
| `dtpipe-integ-postgres` | `postgres:18-alpine` | 5440→5432 | PostgreSQL |
| `dtpipe-integ-mssql` | `mcr.microsoft.com/azure-sql-edge` | 1434→1433 | SQL Server |
| `dtpipe-integ-oracle` | `gvenzl/oracle-free:slim` | 1522→1521 | Oracle |
| `dtpipe-integ-mssql-tools` | `mcr.microsoft.com/mssql-tools` | _(none)_ | sqlcmd sidecar for SQL Server health checks |

To manage them independently (run from the repo root):

```bash
# Start:
infra/start_infra.sh
# Stop:
infra/stop_infra.sh
```

---

## Notes

1. **Isolation**: every tool runs in the same `benchmark-test` container but using isolated Python virtual environments (`/opt/venv/pandas` and `/opt/venv/meltano`) or independent binaries/runtimes to prevent dependency conflicts.
2. **Timing**: wall-clock time measured via `date +%s%N` (nanoseconds → ms, 1ms precision) inside the container.
3. **Averaging**: each pipeline is run N times; the mean of successful runs is reported.
4. **Data integrity**: after each run `verify_data.py` checks row count + min/max/nulls.
5. **Network**: benchmark containers join the DB network dynamically at runtime —
   no static network references in the infra compose file are required.
6. **Memory**: peak cgroup memory delta is polled at ~100 ms intervals by reading
   `/sys/fs/cgroup/memory.current` inside each container, relative to the container's
   baseline at the start of each run. This covers all child processes spawned by the tool.
   Transfers shorter than ~100 ms may still report 0 MiB.