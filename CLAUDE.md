# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

User-facing documentation: [README.md](README.md) · [benchmarks/README.md](benchmarks/README.md). This file captures only design intent and non-obvious constraints that require reading multiple source files to understand.

---

## Design philosophy

### Benchmark: light, fair, non-intrusive

The benchmark suite is designed so that **anyone with bash and a container runtime can run it** — no Python, no Node, no jq, no DB client on the host. Every tool execution, every dependency, every post-run check happens inside a container. This constraint is strict: never introduce a host dependency, even a seemingly innocuous one.

"Fair" means every competitor runs against the same source data, the same DB instances, the same schemas, the same row count. Each tool gets its own table/file prefix so runs are independent and repeatable without teardown.

"Non-intrusive" means no persistent state on the host: containers are ephemeral, artifacts go to a git-ignored `artifacts/` directory, and the infra compose is the same one used by the main dtpipe integration tests — the benchmark piggybacks on existing infrastructure rather than duplicating it.

### Sample project: readable and pedagogical

`src/DtPipe.Sample/` exists to illustrate the DtPipe API in its clearest form — not to be production-ready. Each scenario should remain short, self-contained, and focused on one concept. Avoid framework abstractions or boilerplate that would obscure the API surface. Dependencies should stay minimal: DtPipe NuGet packages plus only what a given scenario strictly requires.

---

## Non-obvious constraints

### `container_compose` requires `COMPOSE_PROJECT_DIR`

`lib/container-runtime.sh` exports `container_compose`, but the function `cd`s into `$COMPOSE_PROJECT_DIR` before calling compose. Every caller must set this variable before calling it:

```bash
COMPOSE_PROJECT_DIR="$CONFIG_DIR"
container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml exec ...
```

Forgetting this causes compose to fail silently or pick up the wrong compose file.

### `jq` runs inside `benchmark-test`, not on the host

`04-report.sh` defines a `jq()` shell function that proxies all `jq` calls through `docker exec -i benchmark-test jq` (`05-compare-baseline.sh` does the same with `jq_file`). The function also rewrites host paths (`$ARTIFACTS_DIR/...` → `/bench/artifacts/...`) since that directory is mounted in the container.

Consequence: **`benchmark-test` must be running** when `04-report.sh` is called. `benchmarks.sh` guarantees this (it starts all containers before calling `04-report.sh`), but calling `./04-report.sh` or `./05-compare-baseline.sh` in isolation requires `benchmark-test` to already be up.

### `lib/stats.sh` owns the result row format — all seven scripts must agree

Dispersion (min, average, sample stddev) and the result-row serialization live in
`lib/stats.sh`, sourced by every `03-*.sh`. The runners no longer carry their own
arithmetic, and they must not: the row written to `.tmp_results.csv` is a fixed
8-field pipe-delimited record

```
bench_id|description|avg_ms|min_ms|stddev_ms|runs|avg_mem_mb|min_mem_mb
```

read back by `stats_json_benchmarks` and, downstream, by `04-report.sh` and
`05-compare-baseline.sh`. Adding a field means touching all three ends. Use
`stats_record_result` / `stats_record_unavailable` rather than echoing a row by hand.

**The statistic that matters is the minimum, not the average.** Noise on a shared
machine is one-sided — it can only make a run slower — so the fastest run is the
closest estimate of the tool's own cost, and it is what the gate compares. The
average is kept for continuity with published reports; the standard deviation is
what makes a 15 % delta interpretable at all. It is the *sample* deviation (n-1):
at 3-5 repetitions the uncorrected form understates dispersion by about 20 %.

### `05-compare-baseline.sh` refuses rather than warns

The macro gate compares a report against a versioned baseline in `baselines/`. When
the host fingerprint (OS / arch / CPU model / core count, taken from the report's own
`configuration.host`) does not match the baseline's, it exits 2 and renders **no
verdict**. This is not caution: comparing durations across different hardware gives a
misleading verdict, not a weaker one, because most of the gap is then the machine.
`--allow-foreign-host` overrides it and clamps the threshold to ≥ 50 %.

The same gate also refuses a **row-count** mismatch, and that one has no override at
all: duration is roughly linear in the row count, so a 250k baseline against a 1M run
reports a +300 % regression on everything. No threshold rescues it; only re-recording
the baseline at the new scale does. A differing repetition count is warned about, not
refused — more repetitions lowers the minimum slightly but keeps the comparison sound.

Do not "fix" any of this by downgrading a refusal to a warning. A warning next to a
number gets read as a number.

It obeys the host-dependency rule the same way `04-report.sh` does — jq runs inside
`benchmark-test` — so **`benchmark-test` must be running** when the gate is invoked.

### B16-B19 are dtpipe-only by design, and B16 is not padding

`03-dtpipe.sh` carries a transformation family (Parquet → `null:`) that no competitor
runner implements. That asymmetry is deliberate: B01-B15 ask "how does dtpipe place
against the field", B16-B19 ask "what does a transformer cost", and the second
question has no competitor in it.

The control (B16, no transformer) is what lets the other three subtract from
something. Removing it to save a few minutes turns the remaining three into totals,
and a total answers no question. The comparability of the four rests on invariants
documented in the runner — same source and sink, a filter that keeps every row, an
identical `--compute` in B18 and B19, no column added or dropped. Changing any one of
them without changing all four breaks the subtraction silently.

### The default tool set is four, and the two left out are not left out for losing

`ALL_TOOLS` is the set `--tool` validates against; `DEFAULT_TOOLS` is what a bare run
measures. pandas and meltano are in the first and not the second.

The reason is **what they measure**, not where they place. A Singer tap serialises every
record to JSON over a pipe between tap and target, and pandas is an analysis library that
happens to be able to move rows. Their gaps — x9 to x200, measured 2026-09-12 — are facts
about those two architectures, not about the quality of either implementation, and they do
not move between versions. Re-measuring them every run bought nothing and cost **68 % of
the wall clock** (meltano 47 %, pandas 21 %). `--tool all` still runs the six.

**Dropping a competitor because it loses is selection, and it is what makes a benchmark
untrustworthy.** If the reason ever shrinks to "it is slow", put them back: the published
figure must keep its date, its versions and its motive, or the absent column reads as a
verdict rather than a scope decision.

### A run purges every per-tool report before it starts

`04-report.sh` assembles the comparative table from whichever `<tool>/<tool>_report.json`
files are on disk, skipping the absent ones — and those files survive a run. So a run that
measures four tools would republish the other two from an earlier run under **this** run's
date, with nothing in the output saying so. The purge in `benchmarks.sh` Step 2 is what
keeps one run to one report; it matters far more now that the default set is a subset.

Consequence to accept, not work around: `--tool dtpipe` produces a dtpipe-only report. A
comparative table wants a comparative run.

### Meltano needs its project bootstrapped, and `meltano add` changed syntax in 4.x

`03-meltano.sh` bootstraps `/bench/artifacts/meltano/meltano_project` itself, idempotently.
Nothing else can: the Dockerfile cannot, because `../artifacts` is bind-mounted over
`/bench/artifacts` and shadows anything baked into the image. Before that step existed,
every `meltano run` died with *"must be run inside a Meltano project"* — meltano scored
0 usable results out of 15 while still consuming run time, and the report showed it as
`0`, which reads like a measurement rather than a missing setup.

Only the project and its plugins are created there. Every plugin **setting** is supplied
by `run_pipeline` as environment variables at run time (`TAP_POSTGRES_SQLALCHEMY_URL`,
`TAP_CSV_FILES`, `TARGET_*_DESTINATION_PATH`…), so nothing is written to `meltano.yml`
and the two must not drift into each other.

`meltano run` is invoked with `--force`. Meltano refuses to start a pipeline whose
State ID is already marked running and only clears that mark after a ~5 minute stale
timeout, so a single interrupted run (Ctrl-C, a killed benchmark) poisons every
following repetition of the same tap/target pair with *"Another pipeline is already
running"*. Each repetition here is independent by construction, so forcing is correct
rather than merely convenient — without it the suite is not restartable.

Meltano 4.x takes the plugin type as an **option**: `meltano add --plugin-type extractor
tap-postgres --install`. The 3.x positional form `meltano add extractor tap-postgres`
now parses `extractor` as a plugin name and fails with *"Utility 'extractor' is not known
to Meltano"*. Plugin installation is best-effort per plugin so a hub variant that will not
install degrades that scenario rather than aborting the tool.

### `mem-watcher.sh` requires `init_container_runtime` first

`lib/mem-watcher.sh` uses `$CONTAINER_CMD` directly (not the wrapper functions). Every script that sources it must call `init_container_runtime` beforehand. All `03-*.sh` scripts do this — maintain the pattern when adding new ones.

### `03-*.sh` scripts require pre-initialized source data

`benchmarks.sh` always runs `01-init-data.sh` before any tool script, generating
the source dataset (Parquet/CSV files + DB tables) for the requested row count.
Calling a `03-*.sh` script directly with `--rows NUM` requires that the dataset
for that exact row count was already generated by a prior `benchmarks.sh` or
`01-init-data.sh --rows NUM` run — otherwise every DB-source pipeline (B02, B04,
B06, B08, B10, B12) fails with "table does not exist".

### `benchmark.env` vs `benchmarks.sh` defaults

`benchmark.env` is sourced by `03-*.sh` scripts but **not** by `benchmarks.sh` — which defines its own `BENCHMARK_ROWS` and passes it via `--rows`. The env file value only takes effect when a `03-*.sh` is called directly without `--rows`.

The default row count is declared in **ten** places (`benchmarks.sh`, `benchmark.env`, `01-init-data.sh`, the six `03-*.sh`, `04-report.sh`) and they must stay aligned — currently `1000000`. It was raised from `250000` because at that size roughly half of a Parquet-source dtpipe measurement was process startup and source setup, while sling and ingestr start in a third of the time: part of the published competitive gap was a runtime-startup comparison. 1M brings that share to about a quarter; it does not remove it. The real fix is to measure the slope at two row counts and discard the intercept, which has not been done. Lowering `--rows` to iterate is fine; publishing numbers taken that way is not.

---

## Adding a new benchmark tool

1. Create `benchmarks/docker/benchmark-<tool>/Dockerfile`
2. Add the service to `benchmarks/config/docker-compose-benchmark.yml` with volume mounts `../artifacts:/bench/artifacts` and `../scripts:/bench/scripts`
3. Add it to `ALL_TOOLS` in `benchmarks.sh` — `--tool` validates against that list, so an
   unlisted name is rejected rather than silently skipped.
4. Create `benchmarks/03-<tool>.sh` — source `container-runtime.sh` + `mem-watcher.sh` + `stats.sh`, call `init_container_runtime`, record rows with `stats_record_result` / `stats_record_unavailable` and emit the report with `stats_json_benchmarks` so the tool lands on the same JSON schema as the others
5. Add the tool to the `tools` array in `04-report.sh`'s `_generate_json_report`
