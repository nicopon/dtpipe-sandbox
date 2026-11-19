# A service that hosts a dtpipe node and serves its own source

A .NET service that reads an external API, applies its business rules, and offers the result to dtpipe as
an Apache Arrow IPC stream on a socket. It hosts a dtpipe node in its own process (`AddDtPipeNode`), so a
coordinator sees an ordinary data node with four bricks:

| Brick | Kind | What it is |
|:---|:---|:---|
| `orders` | source | A .NET source: the service serves it on an Arrow socket, dtpipe reads it as `arrow:pipe://…` |
| `numbers` | source | A standard dtpipe source, `generate:1000`, run by the dtpipe child |
| `report`, `numbers-report` | sinks | CSV files |

`Program.cs` is the whole registration:

```csharp
var node = builder.Services.AddDtPipeNode(o => { /* name, coordinator, key file */ });
node.AddArrowSource("orders", "Orders of the shop API", OrdersTransform.Schema, (ctx, ct) => OrdersTransform.ReadAsync(api, ct));
node.AddBrick("numbers", BrickKind.Source, "Generated numbers", "input: generate:1000");
```

A brick's branch is YAML text, the branch a job file would hold; a JSON object is YAML too, and reads the same.

## The packages

The service references the node library, `DtPipe.PipelineNode.Hosting`, as a package: it carries the node,
its contracts and the job reader, and depends on TransportR and Apache.Arrow. `AddArrowSource` is in it.

Each run of a fragment is a `dtpipe` child process. The csproj gets the program from the `dtpipe` tool package:

```xml
<PackageReference Include="DtPipe.PipelineNode.Hosting" Version="$(NodeHostVersion)" />
<PackageDownload Include="dtpipe" Version="[$(DtPipeVersion)]" />
```

A tool package cannot be a `PackageReference`, so it is downloaded; the node library writes its folder into the
host's `runtimeconfig.json` at build, and a host that names no `DtPipe` of its own runs that package's
`DtPipe.dll` through the dotnet host. The `PackageDownload` line stays in the service's project, since a package's
props are read only after the first restore. The library and the tool package are each named by their own version
property, and `run.sh` sets both from one variable, `DTPIPE_VERSION`.
The machine needs the .NET and ASP.NET Core runtimes. A published copy of the service needs the package's folder
beside it, under `dtpipe/`; nothing here copies it.

| File | What it does |
|:---|:---|
| `Program.cs` | The registration above, behind the `node` command |
| `OrdersTransform.cs`, `FakeOrdersApi.cs` | The business rules and the fixed Arrow schema; a stand-in external API |
| `run.sh` | Coordinator in a container, runner and service on the host, previews, two pipelines, three rounds |

## Run it

It needs the .NET 10 SDK, `docker` or `podman`, `curl` and `jq`. Everything else comes from public registries:
the packages from nuget.org (the first build downloads the dtpipe package, 168 MB) and the coordinator's image
from `ghcr.io/nicopon/dtpipe-coordinator`.

```bash
bash src/ArrowSocketSource/run.sh
```

`DTPIPE_VERSION` (default `1.18.0`) names the node library, the dtpipe tool package and the image's tag.
`COORDINATOR_IMAGE` names another image in full, and `PORT` (default `18080`) another port of the loopback.

The script:

1. builds the service and makes the keys, the rights and a small library of two pipelines in a throwaway folder;
2. starts the coordinator from its image, on the loopback only, with that folder mounted read-only;
3. starts a runner (`dtpipe node --runner`) and the service as processes of the host, and waits for both nodes;
4. shows the bricks, proves that the socket's path never reaches the coordinator, and previews both sources;
5. arms the two pipelines and runs each twice, then once more after the service restarts, comparing the
   orders report with a read of the socket by dtpipe itself, and the numbers report with its known sum.

The coordinator is the only container: the service and the runner are processes of the host, and both reach the coordinator
at the loopback address its port is published on.
The container, the folder and every process are removed when the script ends;
a failed run keeps its folder and prints the path, with the tail of each log. The keys are throwaway and
mode `0644`, since the image runs as user `1654` and could not read a `0600` key of the host's user from a
bind mount on Linux.

## Local packages

To run the service against a dtpipe checkout instead of the published packages, pack the node library
(it is outside `DtPipe.sln`, so it is packed by name) and the tool package in the `dtpipe` repository, under a
version of their own:

```bash
dotnet pack src/DtPipe.PipelineNode.Hosting/DtPipe.PipelineNode.Hosting.csproj -c Release -o ./nuget-packages -p:PackageVersion=1.18.0-local.1
dotnet pack src/DtPipe/DtPipe.csproj -c Release -o ./nuget-packages -p:PackageVersion=1.18.0-local.1
```

Then uncomment the `local-packages` source in `NuGet.Config`, and run the script with that version. No image
carries it, so `COORDINATOR_IMAGE` names a published one:

```bash
DTPIPE_VERSION=1.18.0-local.1 COORDINATOR_IMAGE=ghcr.io/nicopon/dtpipe-coordinator:1.18.0 bash src/ArrowSocketSource/run.sh
```

A version of its own keeps the NuGet cache from serving the published package under the same number.

## What `AddArrowSource` holds

How a real `dtpipe` reads such a source, a failing producer and a reader that leaves included, is held by the
[`ArrowSourceReadTests`](https://github.com/nicopon/dtpipe/blob/main/tests/DtPipe.PipelineNode.Tests/ArrowSourceReadTests.cs)
of the dtpipe repository.

- **A connection is a request to read.** The socket listens from the server's constructor on, and a host builds
  every hosted service before it starts any, so the node never announces the brick before the socket exists.
- **The socket's path is a variable of the node, never part of the brick.** The brick reads
  `arrow:pipe://${{DTPIPE_SRC_ORDERS}}`: its text is its version, which stays the same when the service restarts
  under another process id, and the coordinator learns the variable's name and nothing of the path.
- **The schema goes first**, before the producer runs, and never depends on the data: the source brick's contract
  is pinned when a pipeline is armed. A batch of another schema ends the stream.
- **The end-of-stream marker means success.** A producer that throws (the external API fails, its call times out)
  ends the stream without it, and the dtpipe run fails.
- **A reader can leave early** (`--limit`, a preview, a sample): the next write fails, and the producer is
  disposed, so it stops calling the external API.
- **Only the current user reaches the socket.** It lives in a folder of the process that no one else can open.
  The path is at most 103 characters on macOS; the registration refuses a longer one.

## Not covered

- Parameters per run (a cursor, a filter): the socket carries no request, and the stream is always the whole data set.
- Copying the dtpipe package beside a published service.
- A node that restarts while a run is in flight, and a service killed without running its shutdown (a run in flight
  leaves its child).
- A reader that leaves while the producer is waiting on the external API: the producer finds out at its next write.
- Windows: the code takes a pipe name there, and has not been run on it.
