using DtPipe.Core.Abstractions;

namespace DtPipe.Sample;

/// <summary>
/// The reader → transformers → writer loop, written out.
/// </summary>
/// <remarks>
/// <para>
/// DtPipe publishes its adapters, transformers and abstractions as libraries, but not the engine
/// that drives them: <c>PipelineExecutor</c> lives in the <c>dtpipe</c> tool package. Embedding
/// therefore means owning this loop, and it is short enough to own.
/// </para>
/// <para>
/// Two details are not optional. A transformer that emits several rows from one implements
/// <see cref="IMultiRowTransformer"/>, and a loop that only calls
/// <see cref="IDataTransformer.Transform"/> silently drops every extra row — an expand of one row
/// into five writes one. A stateful transformer (a window, an aggregate) holds its result until
/// <see cref="IDataTransformer.Flush"/>, and those rows still have to travel through the
/// transformers that come after it. Both are why this is a loop and not a Select.
/// </para>
/// </remarks>
internal static class MiniPipeline
{
    public static async Task<long> RunAsync(
        IStreamReader reader,
        IRowDataWriter writer,
        IReadOnlyList<IDataTransformer>? pipeline,
        int batchSize,
        CancellationToken ct)
    {
        var stages = pipeline ?? Array.Empty<IDataTransformer>();
        long written = 0;

        await foreach (var batch in reader.ReadBatchesAsync(batchSize, ct))
        {
            var outRows = new List<object?[]>(batch.Length);
            foreach (var row in batch.ToArray())
                outRows.AddRange(Apply(row, stages, 0));

            if (outRows.Count > 0)
            {
                await writer.WriteBatchAsync(outRows, ct);
                written += outRows.Count;
            }
        }

        // End of stream: what each stateful stage held back still has to cross the stages after it.
        for (int i = 0; i < stages.Count; i++)
        {
            var flushed = stages[i].Flush().ToList();
            if (flushed.Count == 0) continue;

            var tail = new List<object?[]>();
            foreach (var row in flushed)
                tail.AddRange(Apply(row, stages, i + 1));

            if (tail.Count > 0)
            {
                await writer.WriteBatchAsync(tail, ct);
                written += tail.Count;
            }
        }

        await writer.CompleteAsync(ct);
        return written;
    }

    /// <summary>Runs one row through the stages from <paramref name="from"/> onward.</summary>
    private static List<object?[]> Apply(object?[] row, IReadOnlyList<IDataTransformer> stages, int from)
    {
        var current = new List<object?[]> { row };

        for (int i = from; i < stages.Count && current.Count > 0; i++)
        {
            var next = new List<object?[]>();
            foreach (var r in current)
            {
                if (stages[i] is IMultiRowTransformer many)
                {
                    foreach (var produced in many.TransformMany(r))
                        if (produced is not null) next.Add(produced);
                }
                else if (stages[i].Transform(r) is { } produced)
                {
                    next.Add(produced);
                }
            }
            current = next;
        }

        return current;
    }
}
