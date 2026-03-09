using SlimLO;

Console.Error.WriteLine($"HOME={Environment.GetEnvironmentVariable("HOME")}");
Console.Error.WriteLine($"USER={Environment.GetEnvironmentVariable("USER")}");
Console.Error.WriteLine($"XDG_CONFIG_HOME={Environment.GetEnvironmentVariable("XDG_CONFIG_HOME")}");
Console.Error.WriteLine($"CWD={Directory.GetCurrentDirectory()}");

var inputFile = args.Length > 0 ? args[0] : "test.docx";
if (!File.Exists(inputFile))
{
    Console.Error.WriteLine($"File not found: {inputFile}");
    return 1;
}

var docxBytes = await File.ReadAllBytesAsync(inputFile);
Console.Error.WriteLine($"Input: {docxBytes.Length} bytes");

try
{
    using var converter = PdfConverter.Create(new PdfConverterOptions { MaxWorkers = 1 });
    var result = await converter.ConvertAsync(new ReadOnlyMemory<byte>(docxBytes), DocumentFormat.Docx);

    if (!result.Success)
    {
        Console.Error.WriteLine($"FAILED: {result.ErrorMessage}");
        return 2;
    }

    Console.Error.WriteLine($"OK: {result.Data.Length} bytes PDF");
    var outputFile = Path.ChangeExtension(inputFile, ".pdf");
    await File.WriteAllBytesAsync(outputFile, result.Data);
    Console.Error.WriteLine($"Written to {outputFile}");
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine($"EXCEPTION: {ex}");
    return 3;
}
