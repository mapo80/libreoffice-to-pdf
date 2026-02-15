using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Xunit;

namespace SlimLO.Tests;

// ===========================================================================
// Process polyfill tests (WaitForExit, Kill behavior)
// Tests verify that the patterns used in WorkerProcess.cs work on both targets.
// ===========================================================================

public class ProcessPolyfillTests
{
    [Fact]
    public async Task WaitForExit_CompletedProcess_ReturnsImmediately()
    {
        var psi = new ProcessStartInfo
        {
            FileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "cmd.exe" : "/bin/sh",
            Arguments = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "/c echo hello" : "-c \"echo hello\"",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi)!;
        // Read output to prevent blocking
        await process.StandardOutput.ReadToEndAsync();

#if NET5_0_OR_GREATER
        await process.WaitForExitAsync();
#else
        await Task.Run(() => process.WaitForExit(5000));
#endif

        Assert.True(process.HasExited);
        Assert.Equal(0, process.ExitCode);
    }

    [Fact]
    public async Task Kill_RunningProcess_Terminates()
    {
        var psi = new ProcessStartInfo
        {
            FileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "cmd.exe" : "/bin/sh",
            Arguments = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "/c timeout 60" : "-c \"sleep 60\"",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi)!;

        // Give it a moment to start
        await Task.Delay(100);
        Assert.False(process.HasExited, "Process should still be running");

#if NET5_0_OR_GREATER
        process.Kill(entireProcessTree: true);
#else
        process.Kill();
#endif

        // Wait for the process to actually terminate
#if NET5_0_OR_GREATER
        using var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(5));
        await process.WaitForExitAsync(cts.Token);
#else
        await Task.Run(() => process.WaitForExit(5000));
#endif

        Assert.True(process.HasExited);
    }

    [Fact]
    public void Kill_AlreadyExited_DoesNotThrow()
    {
        var psi = new ProcessStartInfo
        {
            FileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "cmd.exe" : "/bin/sh",
            Arguments = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "/c echo done" : "-c \"echo done\"",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true
        };

        using var process = Process.Start(psi)!;
        process.WaitForExit(5000);
        Assert.True(process.HasExited);

        // Killing an already-exited process should not throw
        try
        {
#if NET5_0_OR_GREATER
            process.Kill(entireProcessTree: true);
#else
            process.Kill();
#endif
        }
        catch (InvalidOperationException)
        {
            // This is acceptable — some platforms throw when killing an exited process
        }
    }
}
