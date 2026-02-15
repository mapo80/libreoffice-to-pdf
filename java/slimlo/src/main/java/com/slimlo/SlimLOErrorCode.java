package com.slimlo;

/**
 * Error codes from the SlimLO native library.
 * Values match the native SlimLOError enum in slimlo.h.
 */
public enum SlimLOErrorCode {
    OK(0),
    INIT_FAILED(1),
    LOAD_FAILED(2),
    EXPORT_FAILED(3),
    INVALID_FORMAT(4),
    FILE_NOT_FOUND(5),
    OUT_OF_MEMORY(6),
    PERMISSION_DENIED(7),
    ALREADY_INITIALIZED(8),
    NOT_INITIALIZED(9),
    INVALID_ARGUMENT(10),
    UNKNOWN(99);

    private final int value;

    SlimLOErrorCode(int value) {
        this.value = value;
    }

    public int getValue() {
        return value;
    }

    public static SlimLOErrorCode fromValue(int value) {
        for (SlimLOErrorCode c : values()) {
            if (c.value == value) return c;
        }
        return UNKNOWN;
    }
}
