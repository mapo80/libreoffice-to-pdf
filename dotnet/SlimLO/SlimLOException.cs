namespace SlimLO;

/// <summary>
/// Exception thrown by SlimLO operations when a conversion or initialization fails.
/// </summary>
public class SlimLOException : Exception
{
    /// <summary>
    /// The native error code associated with the failure.
    /// </summary>
    public SlimLOErrorCode ErrorCode { get; }

    public SlimLOException(string message, SlimLOErrorCode errorCode = SlimLOErrorCode.Unknown)
        : base(message)
    {
        ErrorCode = errorCode;
    }

    public SlimLOException(string message, SlimLOErrorCode errorCode, Exception innerException)
        : base(message, innerException)
    {
        ErrorCode = errorCode;
    }
}
