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
├── lib/                                # Utility library (container-runtime, mem-watcher)
├── runners/                            # Tool-specific benchmark runners
│    ├── 01-init-data.sh                # Source dataset generation & DB loading
│    ├── 03-dtpipe.sh                   # dtpipe benchmark runner
│    ├── 03-pandas.sh                   # pandas + SQLAlchemy benchmark runner
│    ├── 03-meltano.sh                  # Meltano (Singer) benchmark runner
│    ├── 03-sling.sh                    # Sling benchmark runner
│    ├── 03-ingestr.sh                  # ingestr benchmark runner
│    ├── 03-native.sh                   # Native tools benchmark runner
│    └── 04-report.sh                   # Comparative report generator
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
| `--rows NUM` | `250000` | Number of source rows |
| `--repetitions NUM` | `3` | Runs per benchmark |
| `--scope B01`…`all` | `all` | Single pipeline or all |
| `--tool NAME`\|`all` | `all` | Single tool or all |
| `--skip-infra` | _(off)_ | Skip DB infrastructure startup |
| `--infra-compose FILE` | auto | Path to infra docker-compose file |
| `--clean-artifacts` | _(off)_ | Wipe previous output files first |

### Examples

```bash
# Full benchmark with defaults (250 000 rows, 3 runs, all tools):
./benchmarks.sh

# Larger dataset, more repetitions:
./benchmarks.sh --rows 1000000 --repetitions 5

# Single tool and pipeline (fast debug run):
./benchmarks.sh --tool dtpipe --scope B01 --rows 1000 --repetitions 1

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
> Calling `runners/03-sling.sh --rows 1000` when only a `250000`-row dataset was initialized
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
./runners/04-report.sh --rows 250000 --repetitions 3
```

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