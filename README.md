# DtPipe Sandbox: Examples & Benchmarks

This repository provides a self-contained environment for testing and evaluating
**DtPipe** — a streaming ETL/ELT pipeline engine written in C#/.NET —
without requiring access to the engine's internal source code.

---

## Repository Structure

```
dtpipe-sandbox/
├── DtPipe.Sandbox.slnx            # .NET 10 solution file
├── NuGet.Config                   # NuGet feeds (public + local dev override)
├── src/
│    ├── ArrowSocketSource/         # A service that hosts a node and serves its own Arrow source
│    │    ├── ArrowSocketSource.csproj
│    │    ├── Program.cs, OrdersTransform.cs, FakeOrdersApi.cs
│    │    ├── run.sh                 # End to end: coordinator image, runner, service, two pipelines
│    │    └── README.md
│    └── DtPipe.Sample/             # C# API usage examples (6 scenarios)
│        ├── DtPipe.Sample.csproj
│        └── Program.cs
├── benchmarks/                    # Dockerized comparative benchmark suite
│    ├── benchmarks.sh              # Self-contained launcher (Linux / macOS / Git Bash / WSL)
│    ├── runners/                   # 01-init-data, one 03-<tool> per tool, 04-report, 05-compare-baseline
│    ├── lib/                       # Shared shell helpers (container runtime, stats, verification)
│    ├── baselines/                 # Versioned macro baseline read by the performance gate
│    └── config/
│        └── docker-compose-benchmark.yml
└── infra/
     ├── docker-compose.yml        # PostgreSQL + SQL Server + Oracle containers
     ├── start_infra.sh            # Infrastructure lifecycle helper
     └── stop_infra.sh             # Stop infrastructure
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

## 2. ArrowSocketSource — a service that hosts a node

A .NET service that reads an external API, applies its business rules, and serves the result as an
Arrow stream on a socket, to the dtpipe node it hosts in its own process. A coordinator sees it as an
ordinary data node; a runner reads the source and writes a report through the node's sinks.

```bash
bash src/ArrowSocketSource/run.sh
```

It needs the .NET 10 SDK, `docker` or `podman`, `curl` and `jq`. The script builds the service, starts the
coordinator from its published image (the only container, on the loopback), starts a runner and the service
as processes of the host, arms two pipelines and runs them, once more after the service restarts. It leaves
nothing behind. `DTPIPE_VERSION` picks the release of the packages and of the image. See
[`src/ArrowSocketSource/README.md`](src/ArrowSocketSource/README.md) for what it shows and how it is built.

---

## 3. Benchmark Suite

Measures wall-clock time and peak memory of data-transfer tools (4 in a default run,
6 with `--tool all`) across **19 scenarios**: 15 transfers between Parquet, CSV and three
relational databases (PostgreSQL, SQL Server, Oracle), and 4 transformation scenarios
that only dtpipe runs.

| Tool | Description |
|------|-------------|
| **dtpipe** | Streaming C#/.NET CLI |
| **pandas + SQLAlchemy** | Python DataFrame-based transfer |
| **Meltano** | Singer tap/target orchestration (ELT) |
| **Sling** | Go-based data replication engine |
| **ingestr** | Go CLI data ingestion tool (by Bruin) |
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

#### Windows (Git Bash or WSL)

```bash
cd benchmarks/
./benchmarks.sh                # full run
./benchmarks.sh --help         # all options
```

#### Common options

```bash
# 1 million rows, 5 repetitions:
./benchmarks.sh --rows 1000000 --repetitions 5

# Single tool, single pipeline, infrastructure already running:
./benchmarks.sh --tool dtpipe --scope B01 --skip-infra

# Pin the dtpipe release and reuse the source data already loaded (fixed inputs for an A/B):
./benchmarks.sh --tool dtpipe --dtpipe-version v1.15.2 --skip-data-init

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
