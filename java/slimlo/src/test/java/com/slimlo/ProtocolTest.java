package com.slimlo;

import com.google.gson.JsonObject;
import com.slimlo.internal.Protocol;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class ProtocolTest {

    @Test
    void writeAndReadMessage_roundTrip() throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] payload = "hello world".getBytes(StandardCharsets.UTF_8);

        Protocol.writeMessage(baos, payload);

        ByteArrayInputStream bais = new ByteArrayInputStream(baos.toByteArray());
        byte[] result = Protocol.readMessage(bais);

        assertNotNull(result);
        assertArrayEquals(payload, result);
    }

    @Test
    void writeMessage_usesLittleEndianLength() throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] payload = new byte[]{0x01, 0x02, 0x03};

        Protocol.writeMessage(baos, payload);

        byte[] raw = baos.toByteArray();
        // First 4 bytes should be length in LE
        assertEquals(7, raw.length); // 4 + 3
        int length = ByteBuffer.wrap(raw, 0, 4).order(ByteOrder.LITTLE_ENDIAN).getInt();
        assertEquals(3, length);
    }

    @Test
    void readMessage_returnsNullOnEOF() throws IOException {
        ByteArrayInputStream empty = new ByteArrayInputStream(new byte[0]);
        assertNull(Protocol.readMessage(empty));
    }

    @Test
    void readMessage_returnsNullOnPartialHeader() throws IOException {
        ByteArrayInputStream partial = new ByteArrayInputStream(new byte[]{0x01, 0x02});
        assertNull(Protocol.readMessage(partial));
    }

    @Test
    void readMessage_returnsNullOnTruncatedPayload() throws IOException {
        // Header says 10 bytes but only 3 available
        byte[] data = new byte[7]; // 4 header + 3 payload
        ByteBuffer.wrap(data, 0, 4).order(ByteOrder.LITTLE_ENDIAN).putInt(10);
        data[4] = 0x01;
        data[5] = 0x02;
        data[6] = 0x03;

        ByteArrayInputStream bais = new ByteArrayInputStream(data);
        assertNull(Protocol.readMessage(bais));
    }

    @Test
    void serializeAndDeserialize_jsonRoundTrip() {
        Map<String, Object> message = new HashMap<String, Object>();
        message.put("type", "init");
        message.put("resource_path", "/path/to/resources");

        byte[] json = Protocol.serialize(message);
        JsonObject parsed = Protocol.deserialize(json);

        assertEquals("init", parsed.get("type").getAsString());
        assertEquals("/path/to/resources", parsed.get("resource_path").getAsString());
    }

    @Test
    void multipleMessages_canBeReadSequentially() throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] msg1 = "first".getBytes(StandardCharsets.UTF_8);
        byte[] msg2 = "second".getBytes(StandardCharsets.UTF_8);
        byte[] msg3 = "third".getBytes(StandardCharsets.UTF_8);

        Protocol.writeMessage(baos, msg1);
        Protocol.writeMessage(baos, msg2);
        Protocol.writeMessage(baos, msg3);

        ByteArrayInputStream bais = new ByteArrayInputStream(baos.toByteArray());
        assertArrayEquals(msg1, Protocol.readMessage(bais));
        assertArrayEquals(msg2, Protocol.readMessage(bais));
        assertArrayEquals(msg3, Protocol.readMessage(bais));
        assertNull(Protocol.readMessage(bais)); // EOF
    }

    @Test
    void emptyPayload() throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] empty = new byte[0];

        Protocol.writeMessage(baos, empty);

        ByteArrayInputStream bais = new ByteArrayInputStream(baos.toByteArray());
        byte[] result = Protocol.readMessage(bais);
        assertNotNull(result);
        assertEquals(0, result.length);
    }

    @Test
    void largePayload() throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        byte[] payload = new byte[1024 * 1024]; // 1 MB
        for (int i = 0; i < payload.length; i++) {
            payload[i] = (byte) (i & 0xFF);
        }

        Protocol.writeMessage(baos, payload);

        ByteArrayInputStream bais = new ByteArrayInputStream(baos.toByteArray());
        byte[] result = Protocol.readMessage(bais);
        assertNotNull(result);
        assertArrayEquals(payload, result);
    }
}
