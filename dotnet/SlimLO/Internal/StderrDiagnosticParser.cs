using System;
using System.Collections.Generic;
using System.Text.Json;

namespace SlimLO.Internal;

/// <summary>
/// Parses diagnostic entries from the worker's JSON response.
/// The native worker captures LOKit's stderr output during conversion and
/// parses it into structured diagnostic JSON objects.
/// </summary>
internal static class StderrDiagnosticParser
{
    /// <summary>
    /// Parse diagnostics from the worker's JSON response array.
    /// </summary>
    public static IReadOnlyList<ConversionDiagnostic> ParseFromJson(JsonElement diagnosticsArray)
    {
        if (diagnosticsArray.ValueKind != JsonValueKind.Array)
            return Array.Empty<ConversionDiagnostic>();

        int count = diagnosticsArray.GetArrayLength();
        if (count == 0)
            return Array.Empty<ConversionDiagnostic>();

        var result = new List<ConversionDiagnostic>(count);

        foreach (var item in diagnosticsArray.EnumerateArray())
        {
            var severity = DiagnosticSeverity.Warning;
            var category = DiagnosticCategory.General;
            string message = "";
            string? fontName = null;
            string? substitutedWith = null;

            if (item.TryGetProperty("severity", out var sev))
            {
                severity = sev.GetString() switch
                {
                    "info" => DiagnosticSeverity.Info,
                    _ => DiagnosticSeverity.Warning
                };
            }

            if (item.TryGetProperty("category", out var cat))
            {
                category = cat.GetString() switch
                {
                    "font" => DiagnosticCategory.Font,
                    "layout" => DiagnosticCategory.Layout,
                    _ => DiagnosticCategory.General
                };
            }

            if (item.TryGetProperty("message", out var msg))
                message = msg.GetString() ?? "";

            if (item.TryGetProperty("font", out var fn))
                fontName = fn.GetString();

            if (item.TryGetProperty("substituted_with", out var sw))
                substitutedWith = sw.GetString();

            result.Add(new ConversionDiagnostic(severity, category, message, fontName, substitutedWith));
        }

        return result;
    }
}
