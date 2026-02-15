package com.slimlo;

/**
 * Exception thrown by SlimLO operations.
 */
public class SlimLOException extends RuntimeException {

    private final SlimLOErrorCode errorCode;

    public SlimLOException(String message, SlimLOErrorCode errorCode) {
        super(message);
        this.errorCode = errorCode;
    }

    public SlimLOException(String message, SlimLOErrorCode errorCode, Throwable cause) {
        super(message, cause);
        this.errorCode = errorCode;
    }

    public SlimLOErrorCode getErrorCode() {
        return errorCode;
    }
}
