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
| **ingestr** | CLI data ingestion tool built on dlt | Python |
| **native** | Direct database CLI tools (bcp, psql, sqlldr, sqlplus) | C / shell |

---

## Architecture

All benchmark executions happen **inside isolated Docker containers**.
Nothing is installed permanently on the host machine.

```
Host (Linux / macOS / Windows)
│
├─ benchmarks.sh   ──────────────────────────────────────────┐
│   or benchmarks.ps1                                          │
│                                                              ▼  Docker network: dtpipe-benchmark_benchmark-net
│                                              ┌────────────────────────────────────┐
│   Infrastructure (infra/)                   │  Benchmark containers               │
│    ┌────────────────────────────┐           │                                     │
│    │ dtpipe-integ-postgres        │◄─────────│  benchmark-dtpipe   (.NET SDK)      │
│    │ dtpipe-integ-mssql           │◄───────── │  benchmark-pandas   (python:3.12)   │
│    │ dtpipe-integ-oracle          │◄───────── │  benchmark-meltano (python:3.12)    │
│    └────────────────────────────┘            │  benchmark-sling    (python:3.12)    │
│                                               │  benchmark-ingestr (python:3.12)    │
│                                               │  benchmark-native   (ubuntu + OCI)   │
│                                               └────────────────────────────────────┘
│
└─ artifacts/                   ← result JSON files, output datasets, reports
```

### Multi-architecture support

Docker images used in this benchmark are all published as **multi-arch manifests**
(`linux/amd64` + `linux/arm64`). Docker automatically pulls the image matching
your host CPU — no configuration needed.

The `benchmark-native` image (which bundles Oracle Instant Client) selects the
correct Oracle binary at build time based on `uname -m`.

---

## File Structure

```
benchmarks/
├── benchmarks.sh                       # Main orchestrator (bash — self-contained)
├── benchmarks.ps1                      # PowerShell entry point (Windows)
├── 01-init-data.sh                     # Source dataset generation & DB loading
├── 03-dtpipe.sh                        # dtpipe benchmark runner
├── 03-pandas.sh                        # pandas + SQLAlchemy benchmark runner
├── 03-meltano.sh                       # Meltano (Singer) benchmark runner
├── 03-sling.sh                         # Sling benchmark runner
├── 03-ingestr.sh                       # ingestr benchmark runner
├── 03-native.sh                        # Native tools benchmark runner
├── 04-report.sh                        # Comparative report generator
├── README.md                           # This file
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
│    └── benchmark-native/
│        └── Dockerfile                  # Ubuntu + Oracle Instant Client + DB clients
└── scripts/
     ├── benchmarks/
     │    └── _pandas_bench.py            # pandas/SQLAlchemy benchmark logic
     └── verify_data.py                  # Post-run data integrity checker
```

---

## Prerequisites

- **Docker** (Desktop or Engine) with the **Compose plugin** (`docker compose`)
- On Windows: **WSL** or **Git for Windows** (Git Bash) — required to run `.sh` scripts

No other software needs to be installed on the host.

---

## Quick Start

### Linux / macOS

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

### Windows (PowerShell)

```powershell
cd benchmarks\
.\benchmarks.ps1
```

Requires WSL or Git Bash. The script detects the available bash automatically.

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

PowerShell: same options as PascalCase parameters (`-Rows`, `-Repetitions`, etc.).

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

```powershell
# PowerShell equivalents:
.\benchmarks.ps1 -Rows 1000000 -Repetitions 5
.\benchmarks.ps1 -Tool dtpipe -Scope B01 -SkipInfra -CleanArtifacts
```

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

Each tool uses its own table/file prefix to avoid conflicts:
`dtpipe_*` · `pandas_*` · `meltano_*` · `sling_*` · `ingestr_*` · `native_*`

---

## Tool Limitations

| Tool | Not supported | Reason |
|------|---------------|--------|
| **Meltano** | B01, B05, B09 (Parquet source) | `tap-parquet` fails on `fixed_size_binary[16]` (UUID column) |
| **Meltano** | B05, B06, B11, B12 (Oracle) | `cx_Oracle` requires native Instant Client not available in the slim image |
| **ingestr** | B05, B11 (→ Oracle target) | Oracle is not a supported destination in ingestr |
| **native** | B01, B02, B05, B06, B09, B10 (Parquet ↔ DB) | Native CLI tools don't support the Parquet format |
| **pandas** | _(all supported)_ | — |
| **dtpipe** | _(all supported)_ | — |

Unsupported benchmarks are reported as `Not supported` in the final table.

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
./04-report.sh --rows 250000 --repetitions 3
```

---

## Infrastructure Details

The DB containers are defined in `infra/docker-compose.yml`:

| Container | Image | Port |
|-----------|-------|------|
| `dtpipe-integ-postgres` | `postgres:18-alpine` | 5440→5432 |
| `dtpipe-integ-mssql` | `mcr.microsoft.com/azure-sql-edge` | 1434→1433 |
| `dtpipe-integ-oracle` | `gvenzl/oracle-free:slim` | 1522→1521 |

To manage them independently:

```bash
# Start:
cd infra/ && ./start_infra.sh
# Stop:
cd infra/ && ./stop_infra.sh
```

---

## Notes

1. **Isolation**: every tool runs in its own container with its own Python/runtime env.
2. **Timing**: wall-clock time measured via `/usr/bin/time -f '%e'` inside each container.
3. **Averaging**: each pipeline is run N times; the mean of successful runs is reported.
4. **Data integrity**: after each run `verify_data.py` checks row count + min/max/nulls.
5. **Network**: benchmark containers join the DB network dynamically at runtime —
   no static network references in the infra compose file are required.
6. **Memory**: peak RSS delta is sampled from the host via `docker stats` at ~1 s intervals,
   relative to the container's baseline at the start of each run. Because of this sampling
   rate, **memory figures are only meaningful for transfers that take at least a few seconds**.
   Sub-second runs will typically report 0 MiB — this is a measurement artifact, not a
   sign of zero memory usage.