package com.raceglyph.nearby;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.os.Build;
import android.util.Base64;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.nearby.Nearby;
import com.google.android.gms.nearby.connection.AdvertisingOptions;
import com.google.android.gms.nearby.connection.ConnectionInfo;
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback;
import com.google.android.gms.nearby.connection.ConnectionResolution;
import com.google.android.gms.nearby.connection.ConnectionsClient;
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo;
import com.google.android.gms.nearby.connection.DiscoveryOptions;
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback;
import com.google.android.gms.nearby.connection.Payload;
import com.google.android.gms.nearby.connection.PayloadCallback;
import com.google.android.gms.nearby.connection.PayloadTransferUpdate;
import com.google.android.gms.nearby.connection.Strategy;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicLong;

/** Google Nearby Connections bridge kept deliberately transport-only. */
public final class RaceGlyphNearbyPlugin extends GodotPlugin {
    private static final String SERVICE_ID = "com.raceglyph.game.nearby.protocol4";
    private static final Strategy STRATEGY = Strategy.P2P_STAR;
    private static final int PERMISSION_REQUEST = 7314;
    private static final int MAX_MESSAGE_BYTES = 256 * 1024;
    private static final int RAW_MESSAGE_BYTES = 30_000;
    private static final int CHUNK_CHARACTERS = 20_000;
    private static final int MAX_PENDING_MESSAGES = 8;
    private static final long CHUNK_TTL_MS = 15_000L;

    private static final String SIGNAL_PERMISSION_RESULT = "permission_result";
    private static final String SIGNAL_OPERATION_FAILED = "operation_failed";
    private static final String SIGNAL_ADVERTISING_STARTED = "advertising_started";
    private static final String SIGNAL_DISCOVERY_STARTED = "discovery_started";
    private static final String SIGNAL_ENDPOINT_FOUND = "endpoint_found";
    private static final String SIGNAL_ENDPOINT_LOST = "endpoint_lost";
    private static final String SIGNAL_CONNECTION_INITIATED = "connection_initiated";
    private static final String SIGNAL_CONNECTION_RESULT = "connection_result";
    private static final String SIGNAL_ENDPOINT_DISCONNECTED = "endpoint_disconnected";
    private static final String SIGNAL_MESSAGE_RECEIVED = "message_received";

    private final Activity hostActivity;
    private final ConnectionsClient client;
    private final Set<String> connectedEndpoints = new HashSet<>();
    private final Map<String, ChunkAccumulator> pendingChunks = new HashMap<>();
    private final AtomicLong messageSerial = new AtomicLong();

    public RaceGlyphNearbyPlugin(Godot godot) {
        super(godot);
        hostActivity = getActivity();
        if (hostActivity == null) {
            throw new IllegalStateException("RaceGlyph Nearby requires an Android Activity");
        }
        client = Nearby.getConnectionsClient(hostActivity);
    }

    @Override
    public String getPluginName() {
        return BuildConfig.GODOT_PLUGIN_NAME;
    }

    @Override
    public Set<SignalInfo> getPluginSignals() {
        Set<SignalInfo> signals = new HashSet<>();
        signals.add(new SignalInfo(SIGNAL_PERMISSION_RESULT, Boolean.class, String.class));
        signals.add(new SignalInfo(SIGNAL_OPERATION_FAILED, String.class, String.class));
        signals.add(new SignalInfo(SIGNAL_ADVERTISING_STARTED));
        signals.add(new SignalInfo(SIGNAL_DISCOVERY_STARTED));
        signals.add(new SignalInfo(SIGNAL_ENDPOINT_FOUND, String.class, String.class));
        signals.add(new SignalInfo(SIGNAL_ENDPOINT_LOST, String.class));
        signals.add(new SignalInfo(SIGNAL_CONNECTION_INITIATED, String.class, String.class, String.class));
        signals.add(new SignalInfo(SIGNAL_CONNECTION_RESULT, String.class, Boolean.class, String.class));
        signals.add(new SignalInfo(SIGNAL_ENDPOINT_DISCONNECTED, String.class));
        signals.add(new SignalInfo(SIGNAL_MESSAGE_RECEIVED, String.class, String.class));
        return signals;
    }

    @UsedByGodot
    public boolean isAvailable() {
        return GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(hostActivity)
                == ConnectionResult.SUCCESS;
    }

    @UsedByGodot
    public boolean hasRequiredPermissions() {
        for (String permission : requiredPermissions()) {
            if (hostActivity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                return false;
            }
        }
        return true;
    }

    @UsedByGodot
    public void requestRequiredPermissions() {
        List<String> missing = new ArrayList<>();
        for (String permission : requiredPermissions()) {
            if (hostActivity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                missing.add(permission);
            }
        }
        if (missing.isEmpty()) {
            emitOnHost(SIGNAL_PERMISSION_RESULT, true, "granted");
            return;
        }
        hostActivity.requestPermissions(missing.toArray(new String[0]), PERMISSION_REQUEST);
    }

    @Override
    public void onMainRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onMainRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != PERMISSION_REQUEST) {
            return;
        }
        boolean granted = grantResults != null && grantResults.length > 0;
        if (granted) {
            for (int result : grantResults) {
                if (result != PackageManager.PERMISSION_GRANTED) {
                    granted = false;
                    break;
                }
            }
        }
        emitOnHost(SIGNAL_PERMISSION_RESULT, granted, granted ? "granted" : "denied");
    }

    @UsedByGodot
    public void startAdvertising(String endpointName) {
        if (!readyForConnections("advertise")) {
            return;
        }
        String safeName = sanitizeEndpointName(endpointName);
        AdvertisingOptions options = new AdvertisingOptions.Builder().setStrategy(STRATEGY).build();
        client.startAdvertising(safeName, SERVICE_ID, lifecycleCallback, options)
                .addOnSuccessListener(unused -> emitOnHost(SIGNAL_ADVERTISING_STARTED))
                .addOnFailureListener(error -> operationFailed("advertise", safeError(error)));
    }

    @UsedByGodot
    public void stopAdvertising() {
        client.stopAdvertising();
    }

    @UsedByGodot
    public void startDiscovery() {
        if (!readyForConnections("discover")) {
            return;
        }
        DiscoveryOptions options = new DiscoveryOptions.Builder().setStrategy(STRATEGY).build();
        client.startDiscovery(SERVICE_ID, discoveryCallback, options)
                .addOnSuccessListener(unused -> emitOnHost(SIGNAL_DISCOVERY_STARTED))
                .addOnFailureListener(error -> operationFailed("discover", safeError(error)));
    }

    @UsedByGodot
    public void stopDiscovery() {
        client.stopDiscovery();
    }

    @UsedByGodot
    public void requestConnection(String endpointId, String localName) {
        if (!readyForConnections("connect") || endpointId == null || endpointId.isEmpty()) {
            operationFailed("connect", "invalid_endpoint");
            return;
        }
        client.requestConnection(sanitizeEndpointName(localName), endpointId, lifecycleCallback)
                .addOnFailureListener(error -> operationFailed("connect", safeError(error)));
    }

    @UsedByGodot
    public boolean sendMessage(String endpointId, String message) {
        if (endpointId == null || !connectedEndpoints.contains(endpointId) || message == null) {
            return false;
        }
        byte[] raw = message.getBytes(StandardCharsets.UTF_8);
        if (raw.length > MAX_MESSAGE_BYTES) {
            operationFailed("send", "message_too_large");
            return false;
        }
        if (raw.length + 3 <= RAW_MESSAGE_BYTES) {
            byte[] framed = new byte[raw.length + 3];
            framed[0] = 'R';
            framed[1] = 'G';
            framed[2] = '0';
            System.arraycopy(raw, 0, framed, 3, raw.length);
            sendBytes(endpointId, framed);
            return true;
        }
        String encoded = Base64.encodeToString(raw, Base64.NO_WRAP);
        int count = (encoded.length() + CHUNK_CHARACTERS - 1) / CHUNK_CHARACTERS;
        String messageId = Long.toHexString(messageSerial.incrementAndGet());
        for (int index = 0; index < count; index++) {
            int start = index * CHUNK_CHARACTERS;
            int end = Math.min(encoded.length(), start + CHUNK_CHARACTERS);
            String frame = String.format(Locale.US, "RG1|%s|%d|%d|%s", messageId, index, count,
                    encoded.substring(start, end));
            sendBytes(endpointId, frame.getBytes(StandardCharsets.UTF_8));
        }
        return true;
    }

    @UsedByGodot
    public void disconnectEndpoint(String endpointId) {
        if (endpointId != null && !endpointId.isEmpty()) {
            client.disconnectFromEndpoint(endpointId);
            connectedEndpoints.remove(endpointId);
        }
    }

    @UsedByGodot
    public void stopAll() {
        client.stopAdvertising();
        client.stopDiscovery();
        client.stopAllEndpoints();
        connectedEndpoints.clear();
        pendingChunks.clear();
    }

    private final EndpointDiscoveryCallback discoveryCallback = new EndpointDiscoveryCallback() {
        @Override
        public void onEndpointFound(String endpointId, DiscoveredEndpointInfo info) {
            emitOnHost(SIGNAL_ENDPOINT_FOUND, endpointId, info.getEndpointName());
        }

        @Override
        public void onEndpointLost(String endpointId) {
            emitOnHost(SIGNAL_ENDPOINT_LOST, endpointId);
        }
    };

    private final ConnectionLifecycleCallback lifecycleCallback = new ConnectionLifecycleCallback() {
        @Override
        public void onConnectionInitiated(String endpointId, ConnectionInfo info) {
            emitOnHost(SIGNAL_CONNECTION_INITIATED, endpointId, info.getEndpointName(), info.getAuthenticationDigits());
            client.acceptConnection(endpointId, payloadCallback)
                    .addOnFailureListener(error -> operationFailed("accept", safeError(error)));
        }

        @Override
        public void onConnectionResult(String endpointId, ConnectionResolution resolution) {
            boolean connected = resolution.getStatus().isSuccess();
            if (connected) {
                connectedEndpoints.add(endpointId);
            } else {
                connectedEndpoints.remove(endpointId);
            }
            emitOnHost(SIGNAL_CONNECTION_RESULT, endpointId, connected,
                    connected ? "connected" : Integer.toString(resolution.getStatus().getStatusCode()));
        }

        @Override
        public void onDisconnected(String endpointId) {
            connectedEndpoints.remove(endpointId);
            removePendingForEndpoint(endpointId);
            emitOnHost(SIGNAL_ENDPOINT_DISCONNECTED, endpointId);
        }
    };

    private final PayloadCallback payloadCallback = new PayloadCallback() {
        @Override
        public void onPayloadReceived(String endpointId, Payload payload) {
            if (payload.getType() != Payload.Type.BYTES || payload.asBytes() == null) {
                operationFailed("receive", "unsupported_payload_type");
                return;
            }
            receiveBytes(endpointId, payload.asBytes());
        }

        @Override
        public void onPayloadTransferUpdate(String endpointId, PayloadTransferUpdate update) {
            if (update.getStatus() == PayloadTransferUpdate.Status.FAILURE
                    || update.getStatus() == PayloadTransferUpdate.Status.CANCELED) {
                operationFailed("transfer", Integer.toString(update.getStatus()));
            }
        }
    };

    private void receiveBytes(String endpointId, byte[] bytes) {
        purgeExpiredChunks();
        if (bytes.length >= 3 && bytes[0] == 'R' && bytes[1] == 'G' && bytes[2] == '0') {
            emitOnHost(SIGNAL_MESSAGE_RECEIVED, endpointId,
                    new String(bytes, 3, bytes.length - 3, StandardCharsets.UTF_8));
            return;
        }
        String frame = new String(bytes, StandardCharsets.UTF_8);
        if (!frame.startsWith("RG1|")) {
            operationFailed("receive", "invalid_frame");
            return;
        }
        String[] parts = frame.split("\\|", 5);
        if (parts.length != 5) {
            operationFailed("receive", "invalid_chunk_header");
            return;
        }
        try {
            int index = Integer.parseInt(parts[2]);
            int count = Integer.parseInt(parts[3]);
            if (count < 1 || count > 20 || index < 0 || index >= count) {
                throw new IllegalArgumentException("chunk_range");
            }
            String key = endpointId + ":" + parts[1];
            if (!pendingChunks.containsKey(key) && pendingChunks.size() >= MAX_PENDING_MESSAGES) {
                operationFailed("receive", "chunk_budget_exceeded");
                return;
            }
            ChunkAccumulator accumulator = pendingChunks.computeIfAbsent(key,
                    unused -> new ChunkAccumulator(count));
            if (accumulator.count != count) {
                pendingChunks.remove(key);
                throw new IllegalArgumentException("chunk_count_changed");
            }
            accumulator.put(index, parts[4]);
            if (!accumulator.complete()) {
                return;
            }
            pendingChunks.remove(key);
            byte[] decoded = Base64.decode(accumulator.join(), Base64.NO_WRAP);
            if (decoded.length > MAX_MESSAGE_BYTES) {
                throw new IllegalArgumentException("message_too_large");
            }
            emitOnHost(SIGNAL_MESSAGE_RECEIVED, endpointId,
                    new String(decoded, StandardCharsets.UTF_8));
        } catch (IllegalArgumentException error) {
            operationFailed("receive", error.getMessage() == null ? "invalid_chunk" : error.getMessage());
        }
    }

    private void sendBytes(String endpointId, byte[] bytes) {
        client.sendPayload(endpointId, Payload.fromBytes(bytes))
                .addOnFailureListener(error -> operationFailed("send", safeError(error)));
    }

    private boolean readyForConnections(String operation) {
        if (!isAvailable()) {
            operationFailed(operation, "google_play_services_unavailable");
            return false;
        }
        if (!hasRequiredPermissions()) {
            operationFailed(operation, "permissions_required");
            return false;
        }
        return true;
    }

    private List<String> requiredPermissions() {
        if (Build.VERSION.SDK_INT >= 32) {
            return Arrays.asList(
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.BLUETOOTH_SCAN,
                    "android.permission.NEARBY_WIFI_DEVICES"
            );
        }
        if (Build.VERSION.SDK_INT >= 31) {
            return Arrays.asList(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                    Manifest.permission.BLUETOOTH_SCAN
            );
        }
        if (Build.VERSION.SDK_INT >= 29) {
            return Collections.singletonList(Manifest.permission.ACCESS_FINE_LOCATION);
        }
        return Collections.singletonList(Manifest.permission.ACCESS_COARSE_LOCATION);
    }

    private String sanitizeEndpointName(String value) {
        // The advertised endpoint name intentionally contains `|` delimiters:
        // RG4|ROOM_CODE|HOST_NAME. Strip only control characters so discovery
        // can still parse and match the requested room code.
        String clean = value == null ? "RaceGlyph" : value.replaceAll("\\p{Cntrl}", " ").trim();
        return clean.isEmpty() ? "RaceGlyph" : clean.substring(0, Math.min(clean.length(), 80));
    }

    private String safeError(Exception error) {
        String message = error == null ? "unknown" : error.getMessage();
        if (message == null || message.trim().isEmpty()) {
            return error == null ? "unknown" : error.getClass().getSimpleName();
        }
        return message.replaceAll("[\\r\\n]", " ").substring(0, Math.min(message.length(), 160));
    }

    private void operationFailed(String operation, String reason) {
        emitOnHost(SIGNAL_OPERATION_FAILED, operation, reason == null ? "unknown" : reason);
    }

    private void emitOnHost(String signal, Object... args) {
        runOnHostThread(() -> emitSignal(signal, args));
    }

    private void purgeExpiredChunks() {
        long cutoff = System.currentTimeMillis() - CHUNK_TTL_MS;
        pendingChunks.entrySet().removeIf(entry -> entry.getValue().createdAtMs < cutoff);
    }

    private void removePendingForEndpoint(String endpointId) {
        String prefix = endpointId + ":";
        pendingChunks.keySet().removeIf(key -> key.startsWith(prefix));
    }

    private static final class ChunkAccumulator {
        private final int count;
        private final String[] chunks;
        private final long createdAtMs = System.currentTimeMillis();
        private int received;

        private ChunkAccumulator(int count) {
            this.count = count;
            this.chunks = new String[count];
        }

        private void put(int index, String value) {
            if (chunks[index] == null) {
                chunks[index] = value;
                received++;
            }
        }

        private boolean complete() {
            return received == count;
        }

        private String join() {
            StringBuilder builder = new StringBuilder();
            for (String chunk : chunks) {
                builder.append(chunk);
            }
            return builder.toString();
        }
    }
}
