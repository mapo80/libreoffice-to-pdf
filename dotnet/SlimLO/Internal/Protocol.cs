using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SlimLO.Internal;

/// <summary>
/// IPC protocol for communication with the native slimlo_worker process.
/// Messages are framed as: [4-byte LE uint32 length][UTF-8 JSON payload]
/// </summary>
internal static class Protocol
{
    private const int MaxMessageSize = 16 * 1024 * 1024; // 16 MB

    /// <summary>Write a length-prefixed JSON message to a stream.</summary>
    public static async Task WriteMessageAsync(Stream stream, byte[] payload, CancellationToken ct)
    {
        var lengthBytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(lengthBytes, (uint)payload.Length);
        await stream.WriteAsync(lengthBytes, ct).ConfigureAwait(false);
        await stream.WriteAsync(payload, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Read a length-prefixed JSON message from a stream.
    /// Returns null on EOF (worker process died).
    /// </summary>
    public static async Task<byte[]?> ReadMessageAsync(Stream stream, CancellationToken ct)
    {
        var lengthBytes = new byte[4];
        int bytesRead = await ReadExactAsync(stream, lengthBytes, ct).ConfigureAwait(false);
        if (bytesRead < 4)
            return null; // EOF — worker died

        uint length = BinaryPrimitives.ReadUInt32LittleEndian(lengthBytes);
        if (length > MaxMessageSize)
            throw new InvalidOperationException($"Message too large: {length} bytes (max {MaxMessageSize})");

        var payload = new byte[length];
        bytesRead = await ReadExactAsync(stream, payload, ct).ConfigureAwait(false);
        if (bytesRead < (int)length)
            return null; // EOF — worker died mid-message

        return payload;
    }

    private static async Task<int> ReadExactAsync(Stream stream, byte[] buffer, CancellationToken ct)
    {
        int totalRead = 0;
        while (totalRead < buffer.Length)
        {
            int read = await stream.ReadAsync(
                buffer.AsMemory(totalRead, buffer.Length - totalRead), ct).ConfigureAwait(false);
            if (read == 0)
                return totalRead; // EOF
            totalRead += read;
        }
        return totalRead;
    }

    /// <summary>Serialize a message to a UTF-8 JSON byte array.</summary>
    public static byte[] Serialize<T>(T message) =>
        JsonSerializer.SerializeToUtf8Bytes(message, ProtocolJsonContext.Default.Options);

    /// <summary>Deserialize a UTF-8 JSON byte array to a JsonDocument for flexible parsing.</summary>
    public static JsonDocument Deserialize(byte[] data) =>
        JsonDocument.Parse(data);
}

// --- Request/response message types ---

internal sealed class InitRequest
{
    [JsonPropertyName("type")]
    public string Type => "init";

    [JsonPropertyName("resource_path")]
    public required string ResourcePath { get; init; }

    [JsonPropertyName("font_paths")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<string>? FontPaths { get; init; }
}

internal sealed class ConvertRequest
{
    [JsonPropertyName("type")]
    public string Type => "convert";

    [JsonPropertyName("id")]
    public int Id { get; init; }

    [JsonPropertyName("input")]
    public required string Input { get; init; }

    [JsonPropertyName("output")]
    public required string Output { get; init; }

    [JsonPropertyName("format")]
    public int Format { get; init; }

    [JsonPropertyName("options")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ConvertRequestOptions? Options { get; init; }
}

internal sealed class ConvertRequestOptions
{
    [JsonPropertyName("pdf_version")]
    public int PdfVersion { get; init; }

    [JsonPropertyName("jpeg_quality")]
    public int JpegQuality { get; init; }

    [JsonPropertyName("dpi")]
    public int Dpi { get; init; }

    [JsonPropertyName("tagged_pdf")]
    public bool TaggedPdf { get; init; }

    [JsonPropertyName("page_range")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? PageRange { get; init; }

    [JsonPropertyName("password")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Password { get; init; }

    public static ConvertRequestOptions? FromConversionOptions(ConversionOptions? options)
    {
        if (options is null)
            return null;

        return new ConvertRequestOptions
        {
            PdfVersion = (int)options.PdfVersion,
            JpegQuality = options.JpegQuality,
            Dpi = options.Dpi,
            TaggedPdf = options.TaggedPdf,
            PageRange = options.PageRange,
            Password = options.Password
        };
    }
}

internal sealed class QuitRequest
{
    [JsonPropertyName("type")]
    public string Type => "quit";
}

/// <summary>
/// Source-generated JSON serializer context for AOT/trimming compatibility.
/// </summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(InitRequest))]
[JsonSerializable(typeof(ConvertRequest))]
[JsonSerializable(typeof(ConvertRequestOptions))]
[JsonSerializable(typeof(QuitRequest))]
internal partial class ProtocolJsonContext : JsonSerializerContext
{
}
