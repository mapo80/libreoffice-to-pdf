using SlimLO;

if (args.Length < 1)
{
    Console.Error.WriteLine("Usage: Example <input.docx> [output.pdf]");
    return 1;
}

var input = args[0];
var output = args.Length > 1 ? args[1] : Path.ChangeExtension(input, ".pdf");

Console.WriteLine($"Converting: {input} -> {output}");

await using var converter = PdfConverter.Create();

var result = await converter.ConvertAsync(input, output);

if (result)
{
    Console.WriteLine($"OK — {new FileInfo(output).Length:N0} bytes");

    if (result.HasFontWarnings)
    {
        Console.WriteLine("Font warnings:");
        foreach (var d in result.Diagnostics)
            Console.WriteLine($"  {d.Severity}: {d.Message}");
    }

    return 0;
}
else
{
    Console.Error.WriteLine($"FAILED: {result.ErrorMessage}");
    return 1;
}
