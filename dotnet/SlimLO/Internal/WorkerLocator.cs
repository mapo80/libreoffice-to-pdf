using System;
using System.IO;
using System.Runtime.InteropServices;

namespace SlimLO.Internal;

/// <summary>
/// Locates the slimlo_worker executable and resource directory at runtime.
/// </summary>
internal static class WorkerLocator
{
    /// <summary>
    /// Find the slimlo_worker executable.
    /// </summary>
    public static string FindWorkerExecutable()
    {
        var workerName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "slimlo_worker.exe" : "slimlo_worker";
        var assemblyDir = GetAssemblyDirectory();

        // Search locations in priority order
        string[] searchPaths = new[]
        {
            // Same directory as assembly (most common for dev/test)
            Path.Combine(assemblyDir, workerName),
            // runtimes/{rid}/native/ (NuGet package layout)
            Path.Combine(assemblyDir, "runtimes", GetRuntimeIdentifier(), "native", workerName),
            // native/ subdirectory
            Path.Combine(assemblyDir, "native", workerName),
            // program/ subdirectory (direct artifact layout)
            Path.Combine(assemblyDir, "program", workerName),
        };

        foreach (var path in searchPaths)
        {
            if (File.Exists(path))
                return Path.GetFullPath(path);
        }

        // Check SLIMLO_WORKER_PATH environment variable
        var envPath = Environment.GetEnvironmentVariable("SLIMLO_WORKER_PATH");
        if (!string.IsNullOrEmpty(envPath) && File.Exists(envPath))
            return Path.GetFullPath(envPath);

        throw new FileNotFoundException(
            $"Cannot find slimlo_worker executable. Searched: {string.Join(", ", searchPaths)}. " +
            "Set SLIMLO_WORKER_PATH environment variable or install the SlimLO.Native NuGet package.");
    }

    /// <summary>
    /// Find the SlimLO resource directory (containing program/, share/).
    /// </summary>
    public static string FindResourcePath()
    {
        var assemblyDir = GetAssemblyDirectory();

        // Search locations in priority order
        string[] candidates = new[]
        {
            // Same directory as assembly has program/ subdirectory
            assemblyDir,
            // slimlo-resources/ subdirectory
            Path.Combine(assemblyDir, "slimlo-resources"),
            // Parent directory
            Path.Combine(assemblyDir, ".."),
            // Parent's slimlo-resources
            Path.Combine(assemblyDir, "..", "slimlo-resources"),
            // NuGet package layout
            Path.Combine(assemblyDir, "runtimes", GetRuntimeIdentifier(), "native"),
        };

        foreach (var candidate in candidates)
        {
            // Resource dir must contain program/ with libmergedlo or mergedlo
            var programDir = Path.Combine(candidate, "program");
            if (Directory.Exists(programDir) && HasMergedLibrary(programDir))
                return Path.GetFullPath(candidate);
        }

        // Check SLIMLO_RESOURCE_PATH environment variable
        var envPath = Environment.GetEnvironmentVariable("SLIMLO_RESOURCE_PATH");
        if (!string.IsNullOrEmpty(envPath) && Directory.Exists(Path.Combine(envPath, "program")))
            return Path.GetFullPath(envPath);

        throw new InvalidOperationException(
            "Cannot auto-detect SlimLO resource path. " +
            "Set SLIMLO_RESOURCE_PATH environment variable or pass ResourcePath in PdfConverterOptions.");
    }

    private static string GetRuntimeIdentifier()
    {
#if NET5_0_OR_GREATER
        return RuntimeInformation.RuntimeIdentifier;
#else
        string os;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            os = "win";
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            os = "osx";
        else
            os = "linux";

        string arch = RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.Arm64 => "arm64",
            Architecture.X86 => "x86",
            Architecture.Arm => "arm",
            _ => "x64"
        };

        return $"{os}-{arch}";
#endif
    }

    private static bool HasMergedLibrary(string programDir)
    {
        // Check for any platform's merged library
        return File.Exists(Path.Combine(programDir, "libmergedlo.so"))
            || File.Exists(Path.Combine(programDir, "libmergedlo.dylib"))
            || File.Exists(Path.Combine(programDir, "mergedlo.dll"))
            || File.Exists(Path.Combine(programDir, "sofficerc"));
    }

    private static string GetAssemblyDirectory()
    {
        var location = typeof(WorkerLocator).Assembly.Location;
        if (string.IsNullOrEmpty(location))
        {
            // Single-file publish: use AppContext.BaseDirectory
            return AppContext.BaseDirectory;
        }
        return Path.GetDirectoryName(location) ?? AppContext.BaseDirectory;
    }
}
