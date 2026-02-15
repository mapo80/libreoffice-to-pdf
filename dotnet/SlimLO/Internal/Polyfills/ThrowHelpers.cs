using System;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.CompilerServices;

namespace SlimLO.Internal;

/// <summary>
/// Polyfill for .NET 7+ static throw helpers that don't exist on .NET Standard 2.0.
/// On .NET 8+, callers use the built-in static methods directly.
/// </summary>
internal static class ThrowHelpers
{
    /// <summary>
    /// Throws <see cref="ObjectDisposedException"/> if <paramref name="condition"/> is true.
    /// </summary>
    public static void ThrowIfDisposed(
#if NET7_0_OR_GREATER
        [DoesNotReturnIf(true)]
#endif
        bool condition,
        object instance)
    {
        if (condition)
            throw new ObjectDisposedException(instance.GetType().FullName);
    }

    /// <summary>
    /// Throws <see cref="ArgumentException"/> if <paramref name="argument"/> is null or empty.
    /// </summary>
    public static void ThrowIfNullOrEmpty(
#if NET7_0_OR_GREATER
        [NotNull]
#endif
        string? argument,
        [CallerArgumentExpression(nameof(argument))] string? paramName = null)
    {
        if (string.IsNullOrEmpty(argument))
            throw new ArgumentException("Value cannot be null or empty.", paramName);
    }

    /// <summary>
    /// Throws <see cref="ArgumentNullException"/> if <paramref name="argument"/> is null.
    /// </summary>
    public static void ThrowIfNull(
#if NET7_0_OR_GREATER
        [NotNull]
#endif
        object? argument,
        [CallerArgumentExpression(nameof(argument))] string? paramName = null)
    {
        if (argument is null)
            throw new ArgumentNullException(paramName);
    }
}
