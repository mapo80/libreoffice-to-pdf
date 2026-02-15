package com.slimlo.internal;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * IPC protocol for communication with the native slimlo_worker process.
 * Messages are framed as: [4-byte LE uint32 length][UTF-8 JSON payload]
 */
public final class Protocol {

    private static final int MAX_MESSAGE_SIZE = 256 * 1024 * 1024; // 256 MB
    private static final Gson GSON = new GsonBuilder()
            .disableHtmlEscaping()
            .create();

    private Protocol() {}

    /**
     * Write a length-prefixed message to a stream.
     */
    public static void writeMessage(OutputStream out, byte[] payload) throws IOException {
        byte[] lengthBytes = new byte[4];
        ByteBuffer.wrap(lengthBytes).order(ByteOrder.LITTLE_ENDIAN).putInt(payload.length);
        out.write(lengthBytes);
        out.write(payload);
        out.flush();
    }

    /**
     * Read a length-prefixed message from a stream.
     * Returns null on EOF (worker process died).
     */
    public static byte[] readMessage(InputStream in) throws IOException {
        byte[] lengthBytes = new byte[4];
        int bytesRead = readExact(in, lengthBytes);
        if (bytesRead < 4) {
            return null; // EOF
        }

        int length = ByteBuffer.wrap(lengthBytes).order(ByteOrder.LITTLE_ENDIAN).getInt();
        if (length < 0 || length > MAX_MESSAGE_SIZE) {
            throw new IOException("Message too large: " + (length & 0xFFFFFFFFL) + " bytes (max " + MAX_MESSAGE_SIZE + ")");
        }

        byte[] payload = new byte[length];
        bytesRead = readExact(in, payload);
        if (bytesRead < length) {
            return null; // EOF mid-message
        }

        return payload;
    }

    /**
     * Serialize an object to UTF-8 JSON bytes.
     */
    public static byte[] serialize(Object message) {
        return GSON.toJson(message).getBytes(StandardCharsets.UTF_8);
    }

    /**
     * Deserialize UTF-8 JSON bytes to a JsonObject.
     */
    public static JsonObject deserialize(byte[] data) {
        String json = new String(data, StandardCharsets.UTF_8);
        return JsonParser.parseString(json).getAsJsonObject();
    }

    /**
     * Get the shared Gson instance.
     */
    public static Gson gson() {
        return GSON;
    }

    private static int readExact(InputStream in, byte[] buffer) throws IOException {
        int totalRead = 0;
        while (totalRead < buffer.length) {
            int read = in.read(buffer, totalRead, buffer.length - totalRead);
            if (read == -1) {
                return totalRead; // EOF
            }
            totalRead += read;
        }
        return totalRead;
    }
}
