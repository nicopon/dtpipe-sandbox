# DtPipe Sandbox: Examples & Benchmarks

This repository provides a self-contained environment for testing and evaluating
**DtPipe** — a high-performance, streaming ETL/ELT pipeline engine written in C#/.NET —
without requiring access to the engine's internal source code.

---

## Repository Structure

```
dtpipe-sandbox/
├── DtPipe.Sandbox.slnx            # .NET 10 solution file
├── NuGet.Config                   # NuGet feeds (public + local dev override)
├── src/
│    └── DtPipe.Sample/             # C# API usage examples (6 scenarios)
│        ├── DtPipe.Sample.csproj
│        └── Program.cs
├── benchmarks/                    # Dockerized comparative benchmark suite
│    ├── benchmarks.sh              # Self-contained launcher (Linux / macOS / Git Bash / WSL)
│    ├── benchmarks.ps1             # PowerShell launcher (Windows)
│    ├── 03-dtpipe.sh               # dtpipe runner
│    ├── 03-pandas.sh               # pandas + SQLAlchemy runner
│    ├── 03-meltano.sh              # Meltano (Singer) runner
│    ├── 03-sling.sh                # Sling runner
│    ├── 03-ingestr.sh              # ingestr runner
│    ├── 03-native.sh               # Native DB tools runner
│    └── config/
│        └── docker-compose-benchmark.yml
├── infra/
│    ├── docker-compose.yml        # PostgreSQL + SQL Server + Oracle containers
│    ├── start_infra.sh            # Infrastructure lifecycle helper
│    └── stop_infra.sh             # Stop infrastructure
└── tests/                         # (empty, kept for backward compatibility)
```

---

## 1. DtPipe.Sample — C# API Usage

Demonstrates how to integrate DtPipe programmatically. Six scenarios:

1. **Full pipeline** — source → transform → target
2. **Reader only** — streaming data without automatic writing
3. **Writer only** — manually feeding a DtPipe target
4. **Microsoft DataFrame** — transfer from `Microsoft.Data.Analysis.DataFrame`
5. **Custom transformer** — row-by-row transformation plugin
6. **LINQ generator** — streaming strongly-typed objects

### Run the sample

```bash
dotnet build DtPipe.Sandbox.slnx -c Release
dotnet run --project src/DtPipe.Sample/DtPipe.Sample.csproj -c Release
```

### Local NuGet packages (dev loop)

To test local engine changes without publishing to NuGet.org:

1. Build packages in the main `dtpipe` repo:
    ```bash
    dotnet pack -c Release -o ./nuget-packages
    ```
2. Uncomment the local source in `NuGet.Config`:
    ```xml
    <add key="local-packages" value="../dtpipe/nuget-packages" />
    ```
3. Build this project normally — it will pick up the local packages.

---

## 2. Benchmark Suite — Performance Comparison

Compares **6 data-transfer tools** across **12 pipeline scenarios** covering
Parquet, CSV and the three main relational databases (PostgreSQL, SQL Server, Oracle).

| Tool | Description |
|------|-------------|
| **dtpipe** | Streaming C#/.NET CLI |
| **pandas + SQLAlchemy** | Python DataFrame-based transfer |
| **Meltano** | Singer tap/target orchestration (ELT) |
| **Sling** | Go-based data replication engine |
| **ingestr** | Python CLI built on dlt |
| **native** | Raw DB CLI tools (psql, bcp, sqlldr) |

Everything runs in isolated Docker containers — nothing is installed on the host.
The suite is **multi-arch**: Docker pulls `linux/amd64` or `linux/arm64` images
automatically based on the host CPU.

### Run the benchmarks

#### Linux / macOS

```bash
cd benchmarks/
./benchmarks.sh                # full run: infra + data init + all tools + report
./benchmarks.sh --help         # all options
```

#### Windows (PowerShell 7+)

```powershell
cd benchmarks\
.\benchmarks.ps1               # requires WSL or Git for Windows
.\benchmarks.ps1 -help         # all options
```

#### Common options

```bash
# 1 million rows, 5 repetitions:
./benchmarks.sh --rows 1000000 --repetitions 5

# Single tool, single pipeline, infrastructure already running:
./benchmarks.sh --tool dtpipe --scope B01 --skip-infra

# Clean previous outputs before running:
./benchmarks.sh --clean-artifacts
```

The final report is generated automatically at:
```
benchmarks/artifacts/reports/benchmark_report.md    ← human-readable
benchmarks/artifacts/reports/benchmark_report.json ← machine-readable
```

See [`benchmarks/README.md`](benchmarks/README.md) for the full documentation.

---

## Infrastructure

The three database containers are defined in `infra/docker-compose.yml`
and managed automatically by `benchmarks.sh`. To control them independently:

```bash
cd infra/
./start_infra.sh    # start (idempotent — skips already-healthy containers)
./stop_infra.sh     # stop
```

---

## CLI dev loop — local dtpipe package

The `benchmark-dtpipe` container installs the CLI from `benchmarks/artifacts/`.
To benchmark a local build:

1. Build the CLI package:
    ```bash
    dotnet pack src/DtPipe/DtPipe.csproj -c Release -o ./nuget-packages
    ```
2. Copy the `.nupkg` to `benchmarks/artifacts/`.
3. Run `benchmarks.sh` — it will automatically install from the local package.