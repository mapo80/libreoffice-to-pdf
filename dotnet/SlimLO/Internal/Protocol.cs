using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace SlimLO.Internal;

/// <summary>
/// IPC protocol for communication with the native slimlo_worker process.
/// Messages are framed as: [4-byte LE uint32 length][UTF-8 JSON payload]
/// </summary>
internal static class Protocol
{
    private const int MaxMessageSize = 256 * 1024 * 1024; // 256 MB (documents can be large)

    /// <summary>Write a length-prefixed message to a stream (byte array).</summary>
    public static async Task WriteMessageAsync(Stream stream, byte[] payload, CancellationToken ct)
    {
        var lengthBytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(lengthBytes, (uint)payload.Length);
#if NET8_0_OR_GREATER
        await stream.WriteAsync(lengthBytes, ct).ConfigureAwait(false);
        await stream.WriteAsync(payload, ct).ConfigureAwait(false);
#else
        await stream.WriteAsync(lengthBytes, 0, lengthBytes.Length, ct).ConfigureAwait(false);
        await stream.WriteAsync(payload, 0, payload.Length, ct).ConfigureAwait(false);
#endif
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    /// <summary>Write a length-prefixed binary frame to a stream (ReadOnlyMemory, avoids copying).</summary>
    public static async Task WriteMessageAsync(Stream stream, ReadOnlyMemory<byte> payload, CancellationToken ct)
    {
        var lengthBytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(lengthBytes, (uint)payload.Length);
#if NET8_0_OR_GREATER
        await stream.WriteAsync(lengthBytes, ct).ConfigureAwait(false);
        await stream.WriteAsync(payload, ct).ConfigureAwait(false);
#else
        await stream.WriteAsync(lengthBytes, 0, lengthBytes.Length, ct).ConfigureAwait(false);
        // ReadOnlyMemory<byte> → byte[] for NS2.0 Stream.WriteAsync overload
        var payloadArray = payload.ToArray();
        await stream.WriteAsync(payloadArray, 0, payloadArray.Length, ct).ConfigureAwait(false);
#endif
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
#if NET8_0_OR_GREATER
            int read = await stream.ReadAsync(
                buffer.AsMemory(totalRead, buffer.Length - totalRead), ct).ConfigureAwait(false);
#else
            int read = await stream.ReadAsync(
                buffer, totalRead, buffer.Length - totalRead, ct).ConfigureAwait(false);
#endif
            if (read == 0)
                return totalRead; // EOF
            totalRead += read;
        }
        return totalRead;
    }

    /// <summary>Serialize a message to a UTF-8 JSON byte array.</summary>
    public static byte[] Serialize<T>(T message) =>
#if NET8_0_OR_GREATER
        JsonSerializer.SerializeToUtf8Bytes(message, ProtocolJsonContext.Default.Options);
#else
        JsonSerializer.SerializeToUtf8Bytes(message, s_serializerOptions);
#endif

    /// <summary>Deserialize a UTF-8 JSON byte array to a JsonDocument for flexible parsing.</summary>
    public static JsonDocument Deserialize(byte[] data) =>
        JsonDocument.Parse(data);

#if !NET8_0_OR_GREATER
    private static readonly JsonSerializerOptions s_serializerOptions = new JsonSerializerOptions
    {
        // JsonPropertyName attributes on each property handle snake_case naming.
        // SnakeCaseLower naming policy is .NET 8+ only; the explicit attributes work everywhere.
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
#endif
}

// --- Request/response message types ---

internal sealed class InitRequest
{
    [JsonPropertyName("type")]
    public string Type => "init";

    [JsonPropertyName("resource_path")]
    public string ResourcePath { get; init; } = "";

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
    public string Input { get; init; } = "";

    [JsonPropertyName("output")]
    public string Output { get; init; } = "";

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

internal sealed class ConvertBufferRequest
{
    [JsonPropertyName("type")]
    public string Type => "convert_buffer";

    [JsonPropertyName("id")]
    public int Id { get; init; }

    [JsonPropertyName("format")]
    public int Format { get; init; }

    [JsonPropertyName("data_size")]
    public long DataSize { get; init; }

    [JsonPropertyName("options")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public ConvertRequestOptions? Options { get; init; }
}

internal sealed class QuitRequest
{
    [JsonPropertyName("type")]
    public string Type => "quit";
}

#if NET8_0_OR_GREATER
/// <summary>
/// Source-generated JSON serializer context for AOT/trimming compatibility.
/// </summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(InitRequest))]
[JsonSerializable(typeof(ConvertRequest))]
[JsonSerializable(typeof(ConvertBufferRequest))]
[JsonSerializable(typeof(ConvertRequestOptions))]
[JsonSerializable(typeof(QuitRequest))]
internal partial class ProtocolJsonContext : JsonSerializerContext
{
}
#endif
