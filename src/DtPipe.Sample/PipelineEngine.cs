using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DtPipe.Core.Abstractions;
using DtPipe.Core.Abstractions.Dag;
using DtPipe.Core.Pipelines.Dag;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace DtPipe.Sample;

/// <summary>
/// Headless pipeline orchestration engine that bridges DtPipe.Core's <see cref="DagOrchestrator"/>
/// with row-by-row and batch-level data streaming.
/// 
/// In DtPipe 1.15+, all pipeline execution (linear or multi-branch DAG) is governed by <see cref="DagOrchestrator"/>,
/// which provides uniform lifecycle management, cancellation propagation, and telemetry.
/// 
/// This class demonstrates Option B:
/// 1. High-level DAG orchestration via <see cref="DagOrchestrator"/> and <see cref="JobDagDefinition"/>
/// 2. Stream extraction from <see cref="IStreamReader"/>
/// 3. Standard row-by-row transformation via <see cref="IDataTransformer"/>
/// 4. 1-to-N transformations via <see cref="IMultiRowTransformer"/>
/// 5. Stateful flush propagation via <see cref="IDataTransformer.Flush"/>
/// 6. Batched writes to <see cref="IRowDataWriter"/> with <see cref="IDataWriter.CompleteAsync"/>
/// </summary>
public class PipelineEngine
{
    private readonly ILogger<PipelineEngine> _logger;
    private readonly ILoggerFactory? _loggerFactory;

    public PipelineEngine(ILogger<PipelineEngine> logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public PipelineEngine(ILoggerFactory loggerFactory)
    {
        _loggerFactory = loggerFactory ?? throw new ArgumentNullException(nameof(loggerFactory));
        _logger = loggerFactory.CreateLogger<PipelineEngine>();
    }

    /// <summary>
    /// Executes a linear pipeline inside a single-branch DAG via <see cref="DagOrchestrator"/>.
    /// </summary>
    public async Task<long> RunAsync(
        IStreamReader reader,
        IRowDataWriter writer,
        IReadOnlyList<IDataTransformer>? pipeline = null,
        int batchSize = 50_000,
        string branchAlias = "main",
        CancellationToken ct = default)
    {
        // 1. Setup the DAG orchestrator from DtPipe.Core
        var channelRegistry = new MemoryChannelRegistry();
        var orchestratorLogger = _loggerFactory?.CreateLogger<DagOrchestrator>() ?? NullLogger<DagOrchestrator>.Instance;
        var orchestrator = new DagOrchestrator(orchestratorLogger, channelRegistry);

        orchestrator.OnLogEvent = evt =>
        {
            _logger.LogDebug("[DAG {Branch}] {Severity}: {Message}", evt.Branch ?? "all", evt.Severity, evt.Message);
        };

        // 2. Define the single-branch DAG
        var dag = new JobDagDefinition
        {
            Branches = new[]
            {
                new BranchDefinition
                {
                    Alias = branchAlias,
                    Input = reader.ToString(),
                    Output = writer.ToString()
                }
            }
        };

        long totalWritten = 0;

        // 3. Execute the DAG via DagOrchestrator
        int exitCode = await orchestrator.ExecuteAsync(dag, async (branch, ctx, token) =>
        {
            totalWritten = await TransferBranchDataAsync(reader, writer, pipeline, batchSize, token);
            return 0;
        }, ct);

        if (exitCode != 0)
        {
            throw new InvalidOperationException($"DagOrchestrator failed with exit code: {exitCode}");
        }

        return totalWritten;
    }

    /// <summary>
    /// The streaming transfer loop for a branch, handling reader batches, transformers, and writer flushing.
    /// </summary>
    private async Task<long> TransferBranchDataAsync(
        IStreamReader reader,
        IRowDataWriter writer,
        IReadOnlyList<IDataTransformer>? pipeline,
        int batchSize,
        CancellationToken ct)
    {
        long totalWritten = 0;
        var transformers = pipeline ?? Array.Empty<IDataTransformer>();
        var writeBuffer = new List<object?[]>(batchSize);

        // A. Stream row batches from the reader
        await foreach (var batchChunk in reader.ReadBatchesAsync(batchSize, ct))
        {
            int length = batchChunk.Length;
            for (int i = 0; i < length; i++)
            {
                var row = batchChunk.Span[i];
                ProcessRow(row, transformers, 0, writeBuffer);

                if (writeBuffer.Count >= batchSize)
                {
                    await FlushWriteBufferAsync(writer, writeBuffer, ct);
                    totalWritten += writeBuffer.Count;
                    writeBuffer.Clear();
                }
            }
        }

        // B. Flush stateful transformers (e.g. windowing, aggregations)
        // Flushed rows must cascade through subsequent stages in the pipeline.
        for (int tIdx = 0; tIdx < transformers.Count; tIdx++)
        {
            var flushed = transformers[tIdx].Flush();
            foreach (var flushedRow in flushed)
            {
                ProcessRow(flushedRow, transformers, tIdx + 1, writeBuffer);

                if (writeBuffer.Count >= batchSize)
                {
                    await FlushWriteBufferAsync(writer, writeBuffer, ct);
                    totalWritten += writeBuffer.Count;
                    writeBuffer.Clear();
                }
            }
        }

        // C. Flush remaining buffered rows
        if (writeBuffer.Count > 0)
        {
            await FlushWriteBufferAsync(writer, writeBuffer, ct);
            totalWritten += writeBuffer.Count;
            writeBuffer.Clear();
        }

        // D. Finalize writer
        await writer.CompleteAsync(ct);

        return totalWritten;
    }

    private static async Task FlushWriteBufferAsync(IRowDataWriter writer, List<object?[]> buffer, CancellationToken ct)
    {
        if (buffer.Count > 0)
        {
            await writer.WriteBatchAsync(buffer, ct);
        }
    }

    private static void ProcessRow(
        object?[] row,
        IReadOnlyList<IDataTransformer> transformers,
        int startIndex,
        List<object?[]> outputBuffer)
    {
        List<object?[]> current = [row];

        for (int i = startIndex; i < transformers.Count; i++)
        {
            var transformer = transformers[i];
            var next = new List<object?[]>();

            foreach (var r in current)
            {
                if (transformer is IMultiRowTransformer multi)
                {
                    var multiResult = multi.TransformMany(r);
                    if (multiResult != null)
                    {
                        next.AddRange(multiResult);
                    }
                }
                else
                {
                    var singleResult = transformer.Transform(r);
                    if (singleResult != null)
                    {
                        next.Add(singleResult);
                    }
                }
            }

            current = next;
            if (current.Count == 0) break;
        }

        outputBuffer.AddRange(current);
    }
}
