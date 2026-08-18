// RaceGlyph Nakama authoritative room runtime.
// ES5 is required by Nakama's embedded JavaScript runtime.

var MODULE_NAME = "raceglyph_private_room_v4";
var RPC_CREATE = "raceglyph_create_room";
var RPC_JOIN = "raceglyph_join_room";
var RPC_LEAVE = "raceglyph_leave_room";
var ROOM_DIRECTORY_COLLECTION = "raceglyph_private_room_directory_v4";
var PROTOCOL = 4;
var APP_BUILD = "0.4.0";
var TRACK_SCHEMA_VERSION = 2;
var TRACK_GENERATOR_VERSION = 3;
var SUPPORTED_PLATFORMS = {android: true, ios: true, linux: true, macos: true, web: true, windows: true};
var MAX_PLAYERS = 12;
var TICK_RATE = 20;
var SIM_TICKS_PER_MATCH_TICK = 3;
var RECONNECT_TICKS = 20 * TICK_RATE;
var RESERVATION_TICKS = 30 * TICK_RATE;
var EMPTY_CLOSE_TICKS = 30 * TICK_RATE;
var COUNTDOWN_MATCH_TICKS = 3 * TICK_RATE;
var MAX_MESSAGE_BYTES = 65536;
var MAX_TRACK_BYTES = 32768;
var MAX_INPUTS_PER_SECOND = 20;
var MAX_SNAPSHOTS_PER_SECOND = 20;
var MAX_CONTROL_MESSAGES_PER_SECOND = 12;
var MAX_MALFORMED = 8;
var MAX_SAFE_SEQUENCE = 9007199254740991;
var MAX_STALE_INPUT_TICKS = 120;
var MAX_FUTURE_INPUT_TICKS = 6;
var ROOM_CREATE_ATTEMPTS_PER_MINUTE = 5;
var ROOM_JOIN_ATTEMPTS_PER_MINUTE = 10;
var RPC_RATE_WINDOW_SECONDS = 60;
var ALLOWED_LAP_COUNTS = {"1": true, "3": true, "5": true};
var VEHICLE_TEAM_PAIRS = {
    "car-prime": "team-vector", "car-aurora": "team-aurora",
    "car-cinder": "team-cinder", "car-jade": "team-jade",
    "car-solar": "team-solar", "car-violet": "team-violet",
    "car-tide": "team-tide", "car-rose": "team-rose"
};

var OP_ROOM_CONFIG = 2;
var OP_TRACK_MANIFEST = 3;
var OP_GENERATION_REPORT = 5;
var OP_READY_STATE = 6;
var OP_START_AT_TICK = 7;
var OP_INPUT_FRAME = 8;
var OP_STATE_SNAPSHOT = 9;
var OP_RACE_EVENT = 10;
var OP_RESUME = 13;
var OP_ROOM_ENDED = 14;
var OP_ERROR = 15;

function InitModule(ctx, logger, nk, initializer) {
    initializer.registerRpc(RPC_CREATE, rpcCreateRoom);
    initializer.registerRpc(RPC_JOIN, rpcJoinRoom);
    initializer.registerRpc(RPC_LEAVE, rpcLeaveRoom);
    initializer.registerMatch(MODULE_NAME, {
        matchInit: matchInit,
        matchJoinAttempt: matchJoinAttempt,
        matchJoin: matchJoin,
        matchLeave: matchLeave,
        matchLoop: matchLoop,
        matchTerminate: matchTerminate,
        matchSignal: matchSignal
    });
    logger.info("RaceGlyph private-room runtime loaded: protocol=%d max_players=%d", PROTOCOL, MAX_PLAYERS);
}

function rpcCreateRoom(ctx, logger, nk, payload) {
    if (!ctx.userId) return rpcFailure("authentication_required", "Device session is required.");
    var request = parseObject(payload);
    if (!request.ok) return rpcFailure("request_malformed", "Create-room payload must be a JSON object.");
    var displayName = boundedName(request.value.display_name || ctx.username || "Driver");
    if (!displayName) return rpcFailure("display_name_invalid", "Display name is invalid.");
    var cosmetics = validatedCosmetics(request.value.car_id, request.value.team_id);
    if (!cosmetics.ok) return rpcFailure("cosmetics_invalid", "Car and fictional team selection is invalid.");
    var compatibility = validatedCompatibility(request.value.compatibility);
    if (!compatibility.ok) return rpcFailure("update_required", "This build is incompatible with the private-room service. Update RaceGlyph and try again.");
    if (!consumeRpcRate(nk, "create:" + ctx.userId, ROOM_CREATE_ATTEMPTS_PER_MINUTE)) {
        return rpcFailure("room_create_rate_limited", "Too many room creation attempts.");
    }
    var roomCode = "";
    var matchId = "";
    var claimVersion = "";
    for (var attempt = 0; attempt < 8; attempt++) {
        roomCode = roomCodeFromUuid(nk.uuidv4());
        var claim = claimRoomCode(nk, roomCode, ctx.userId);
        if (!claim.ok) continue;
        claimVersion = claim.version;
        try {
            matchId = nk.matchCreate(MODULE_NAME, {
                roomCode: roomCode,
                hostUserId: ctx.userId,
                hostUsername: displayName,
                directoryVersion: claimVersion
            });
        } catch (error) {
            removeRoomDirectory(nk, roomCode, claimVersion);
            logger.warn("Match creation failed; private-room claim released.");
            continue;
        }
        break;
    }
    if (!matchId) return rpcFailure("room_code_exhausted", "Could not allocate a unique room code.");
    var reservation = parseObject(nk.matchSignal(matchId, JSON.stringify({
        action: "reserve",
        user_id: ctx.userId,
        username: displayName,
        car_id: cosmetics.carId,
        team_id: cosmetics.teamId,
        compatibility: compatibility.value,
        host: true
    })));
    if (!reservation.ok || !reservation.value.ok) {
        removeRoomDirectory(nk, roomCode, claimVersion);
        logger.error("Host reservation failed for match %s", matchId);
        return rpcFailure("room_reservation_failed", "Could not reserve the host slot.");
    }
    var published = publishRoomCode(nk, roomCode, matchId, ctx.userId, claimVersion);
    if (!published.ok) {
        removeRoomDirectory(nk, roomCode, claimVersion);
        logger.error("Room directory publication failed for match %s", matchId);
        return rpcFailure("room_directory_failed", "Could not publish the private room.");
    }
    var directorySignal = parseObject(nk.matchSignal(matchId, JSON.stringify({
        action: "directory_version",
        version: published.version
    })));
    if (!directorySignal.ok || !directorySignal.value.ok) {
        removeRoomDirectory(nk, roomCode, published.version);
        logger.error("Room directory acknowledgement failed for match %s", matchId);
        return rpcFailure("room_directory_failed", "Could not publish the private room.");
    }
    return JSON.stringify({
        ok: true,
        room_code: roomCode,
        match_id: matchId,
        room_epoch: reservation.value.room_epoch,
        reconnect_token: reservation.value.reconnect_token
    });
}

function rpcJoinRoom(ctx, logger, nk, payload) {
    if (!ctx.userId) return rpcFailure("authentication_required", "Device session is required.");
    var request = parseObject(payload);
    if (!request.ok) return rpcFailure("request_malformed", "Join-room payload must be a JSON object.");
    var roomCode = String(request.value.room_code || "").toUpperCase();
    var displayName = boundedName(request.value.display_name || ctx.username || "Driver");
    if (!validRoomCode(roomCode)) return rpcFailure("room_code_invalid", "Room code format is invalid.");
    if (!displayName) return rpcFailure("display_name_invalid", "Display name is invalid.");
    var cosmetics = validatedCosmetics(request.value.car_id, request.value.team_id);
    if (!cosmetics.ok) return rpcFailure("cosmetics_invalid", "Car and fictional team selection is invalid.");
    var compatibility = validatedCompatibility(request.value.compatibility);
    if (!compatibility.ok) return rpcFailure("update_required", "This build is incompatible with the private-room service. Update RaceGlyph and try again.");
    if (!consumeRpcRate(nk, "join:" + ctx.userId, ROOM_JOIN_ATTEMPTS_PER_MINUTE)) {
        return rpcFailure("room_join_rate_limited", "Too many room join attempts.");
    }
    var directory = readRoomDirectory(nk, roomCode);
    if (!directory.ok || directory.matchId === "") {
        return rpcFailure("room_not_found", "Private room was not found or is locked.");
    }
    var matchId = directory.matchId;
    var reservation;
    try {
        reservation = parseObject(nk.matchSignal(matchId, JSON.stringify({
            action: "reserve",
            user_id: ctx.userId,
            username: displayName,
            car_id: cosmetics.carId,
            team_id: cosmetics.teamId,
            compatibility: compatibility.value,
            host: false
        })));
    } catch (error) {
        removeRoomDirectory(nk, roomCode, directory.version);
        logger.warn("Stale private-room directory entry removed after match signal failure.");
        return rpcFailure("room_not_found", "Private room was not found or is locked.");
    }
    if (!reservation.ok) return rpcFailure("room_signal_failed", "Room did not accept the reservation request.");
    if (!reservation.value.ok) return JSON.stringify(reservation.value);
    return JSON.stringify({
        ok: true,
        room_code: roomCode,
        match_id: matchId,
        room_epoch: reservation.value.room_epoch,
        reconnect_token: reservation.value.reconnect_token
    });
}

function rpcLeaveRoom(ctx, logger, nk, payload) {
    if (!ctx.userId) return rpcFailure("authentication_required", "Device session is required.");
    var request = parseObject(payload);
    if (!request.ok) return rpcFailure("request_malformed", "Leave-room payload must be a JSON object.");
    var matchId = String(request.value.match_id || "");
    if (!matchId || matchId.length > 256) return rpcFailure("match_id_invalid", "Match ID is invalid.");
    var response;
    try {
        response = parseObject(nk.matchSignal(matchId, JSON.stringify({
            action: "permanent_leave",
            user_id: ctx.userId
        })));
    } catch (error) {
        logger.warn("Permanent leave signal failed.");
        return rpcFailure("room_not_found", "Private room was not found.");
    }
    if (!response.ok) return rpcFailure("room_signal_failed", "Room did not acknowledge departure.");
    return JSON.stringify(response.value);
}

function matchInit(ctx, logger, nk, params) {
    var roomCode = String(params.roomCode || "");
    var state = {
        roomCode: roomCode,
        epoch: 1,
        phase: "LOBBY",
        hostUserId: String(params.hostUserId || ""),
        members: {},
        bannedUserIds: {},
        joinSerial: 0,
        serverSeq: 0,
        manifest: null,
        raceConfig: {laps: 3, collisions: true},
        joinLocked: false,
        countdown: null,
        raceSimulation: null,
        latestSnapshot: null,
        lastSnapshotTick: -1,
        lastSnapshotSequence: -1,
        emptyTicks: 0,
        closeAtTick: -1,
        closeReason: "",
        directoryActive: true,
        directoryVersion: String(params.directoryVersion || "")
    };
    return {state: state, tickRate: TICK_RATE, label: roomLabel(state)};
}

function matchJoinAttempt(ctx, logger, nk, dispatcher, tick, state, presence, metadata) {
    var member = state.members[presence.userId];
    if (!member) return {state: state, accept: false, rejectMessage: "reservation_required"};
    if (member.connected) return {state: state, accept: false, rejectMessage: "already_connected"};
    if (member.reservationDeadline >= 0 && tick > member.reservationDeadline) {
        return {state: state, accept: false, rejectMessage: "reservation_expired"};
    }
    if (member.disconnectDeadline >= 0 && tick > member.disconnectDeadline) {
        return {state: state, accept: false, rejectMessage: "reconnect_expired"};
    }
    if (!metadata || String(metadata.reconnect_token || "") !== member.reconnectToken) {
        return {state: state, accept: false, rejectMessage: "reconnect_token_invalid"};
    }
    return {state: state, accept: true};
}

function matchJoin(ctx, logger, nk, dispatcher, tick, state, presences) {
    var newMembers = [];
    var resumedMembers = [];
    for (var i = 0; i < presences.length; i++) {
        var presence = presences[i];
        var member = state.members[presence.userId];
        if (!member) continue;
        var isReconnect = member.everJoined;
        member.connected = true;
        member.presence = presence;
        member.reservationDeadline = -1;
        member.disconnectDeadline = -1;
        if (isReconnect) {
            member.reconnectCount++;
            member.reconnectToken = nk.sha256Hash(
                nk.uuidv4() + ":" + state.roomCode + ":" + member.userId + ":" + member.reconnectCount
            );
            resumedMembers.push(member);
        } else {
            member.everJoined = true;
            newMembers.push(member);
        }
    }
    state.emptyTicks = 0;
    if (state.manifest && newMembers.length > 0 && state.phase !== "COUNTDOWN" && state.phase !== "RACING") {
        state.phase = "TRACK_SYNC";
    }
    for (var r = 0; r < resumedMembers.length; r++) {
        var resumed = resumedMembers[r];
        if (resumed.userId === state.hostUserId && state.phase === "COUNTDOWN" && state.countdown &&
                tick >= state.countdown.match_start_tick) {
            state.countdown.issued_at_tick = tick * SIM_TICKS_PER_MATCH_TICK;
            state.countdown.start_tick = (tick + COUNTDOWN_MATCH_TICKS) * SIM_TICKS_PER_MATCH_TICK;
            state.countdown.match_start_tick = tick + COUNTDOWN_MATCH_TICKS;
            broadcastEnvelope(nk, dispatcher, tick, state, OP_START_AT_TICK, state.countdown, null, null, true);
        }
    }
    updateLabel(dispatcher, state);
    broadcastRoomConfig(nk, dispatcher, tick, state);
    for (var p = 0; p < resumedMembers.length; p++) {
        broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
            type: "peer_resumed",
            player_id: resumedMembers[p].userId
        }, null, null, true);
    }
    var joinedMembers = newMembers.concat(resumedMembers);
    if (state.manifest) {
        for (var m = 0; m < joinedMembers.length; m++) {
            broadcastEnvelope(nk, dispatcher, tick, state, OP_TRACK_MANIFEST, state.manifest,
                [joinedMembers[m].presence], null, true);
        }
    }
    for (var q = 0; q < resumedMembers.length; q++) {
        var resumedMember = resumedMembers[q];
        broadcastEnvelope(nk, dispatcher, tick, state, OP_RESUME, {
            type: "peer_resumed",
            player_id: resumedMember.userId,
            room_epoch: state.epoch,
            reconnect_token: resumedMember.reconnectToken,
            authoritative_snapshot: state.latestSnapshot
        }, [resumedMember.presence], null, true);
    }
    return {state: state};
}

function matchLeave(ctx, logger, nk, dispatcher, tick, state, presences) {
    for (var i = 0; i < presences.length; i++) {
        var member = state.members[presences[i].userId];
        if (!member) continue;
        member.connected = false;
        member.presence = null;
        member.disconnectDeadline = tick + RECONNECT_TICKS;
        broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
            type: "peer_disconnected",
            player_id: member.userId,
            reconnect_match_ticks: RECONNECT_TICKS
        }, null, null, true);
    }
    updateLabel(dispatcher, state);
    return {state: state};
}

function matchLoop(ctx, logger, nk, dispatcher, tick, state, messages) {
    if (state.closeAtTick >= 0 && tick >= state.closeAtTick) {
        cleanupRoomDirectory(nk, state);
        return null;
    }
    expireMembers(nk, dispatcher, tick, state);
    if (state.phase === "CLOSED") return {state: state};
    for (var i = 0; i < messages.length; i++) {
        processMessage(nk, dispatcher, tick, state, messages[i]);
        if (state.phase === "CLOSED") break;
    }
    if (state.phase === "COUNTDOWN" && state.countdown && tick >= state.countdown.match_start_tick) {
        if (connectedCount(state) > 0) {
            state.phase = "RACING";
            broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
                type: "race_started",
                tick: state.countdown.start_tick
            }, null, null, true);
            updateLabel(dispatcher, state);
        }
    }
    if (state.phase === "RACING") {
        if (!state.raceSimulation) {
            closeRoom(nk, dispatcher, tick, state, "cloud_simulation_unavailable");
        } else {
            for (var simulationStep = 0; simulationStep < SIM_TICKS_PER_MATCH_TICK; simulationStep++) {
                simulateCloudRaceStep(state);
            }
            broadcastCloudSnapshot(dispatcher, state);
            if (cloudRaceComplete(state.raceSimulation)) finishCloudRace(nk, dispatcher, tick, state);
        }
    }
    if (connectedCount(state) === 0) {
        state.emptyTicks++;
        if (state.emptyTicks >= EMPTY_CLOSE_TICKS) {
            cleanupRoomDirectory(nk, state);
            return null;
        }
    } else {
        state.emptyTicks = 0;
    }
    return {state: state};
}

function matchTerminate(ctx, logger, nk, dispatcher, tick, state, graceSeconds) {
    cleanupRoomDirectory(nk, state);
    broadcastEnvelope(nk, dispatcher, tick, state, OP_ROOM_ENDED, {
        reason: "server_shutdown",
        reconnectable: false
    }, null, null, true);
    return {state: state};
}

function matchSignal(ctx, logger, nk, dispatcher, tick, state, data) {
    var parsed = parseObject(data);
    if (!parsed.ok) return {state: state, data: rpcFailure("signal_malformed", "Signal must be JSON.")};
    var request = parsed.value;
    if (request.action === "directory_version") {
        var directoryVersion = String(request.version || "");
        if (!directoryVersion) {
            return {state: state, data: rpcFailure("directory_version_invalid", "Directory version is required.")};
        }
        state.directoryVersion = directoryVersion;
        state.directoryActive = true;
        return {state: state, data: JSON.stringify({ok: true})};
    }
    if (request.action === "permanent_leave") {
        var leavingUserId = String(request.user_id || "");
        if (!leavingUserId || !state.members[leavingUserId]) {
            return {state: state, data: rpcFailure("membership_missing", "Player is not a room member.")};
        }
        permanentLeave(nk, dispatcher, tick, state, leavingUserId, "peer_left");
        return {state: state, data: JSON.stringify({
            ok: true,
            state: state.phase,
            host_id: state.hostUserId,
            room_epoch: state.epoch,
            close_reason: state.closeReason
        })};
    }
    if (request.action !== "reserve") return {state: state, data: rpcFailure("signal_unknown", "Unknown room signal.")};
    var userId = String(request.user_id || "");
    var username = boundedName(request.username || "Driver");
    var cosmetics = validatedCosmetics(request.car_id, request.team_id);
    var compatibility = validatedCompatibility(request.compatibility);
    if (!userId || !username) return {state: state, data: rpcFailure("identity_invalid", "Reservation identity is invalid.")};
    if (!cosmetics.ok) return {state: state, data: rpcFailure("cosmetics_invalid", "Car and fictional team selection is invalid.")};
    if (!compatibility.ok) return {state: state, data: rpcFailure("update_required", "This build is incompatible with the private-room service.")};
    if (state.bannedUserIds[userId]) {
        return {state: state, data: rpcFailure("kicked_from_room", "The host removed this identity from the room.")};
    }
    var existing = state.members[userId];
    if (existing) {
        if (existing.connected) return {state: state, data: rpcFailure("already_connected", "Player is already connected.")};
        if (existing.disconnectDeadline >= 0 && tick > existing.disconnectDeadline) {
            return {state: state, data: rpcFailure("reconnect_expired", "Reconnect window expired.")};
        }
        existing.reservationDeadline = tick + RESERVATION_TICKS;
        return {state: state, data: JSON.stringify({
            ok: true,
            room_epoch: state.epoch,
            reconnect_token: existing.reconnectToken,
            slot: existing.slot,
            resumed: true
        })};
    }
    if (state.joinLocked || state.phase === "COUNTDOWN" || state.phase === "RACING" || state.phase === "RESULTS" || state.phase === "CLOSED") {
        return {state: state, data: rpcFailure("room_locked", "Race has already started.")};
    }
    if (memberCount(state) >= MAX_PLAYERS) return {state: state, data: rpcFailure("room_full", "Room already has 12 players.")};
    state.joinSerial++;
    var slot = firstFreeSlot(state);
    state.members[userId] = {
        userId: userId,
        username: username,
        carId: cosmetics.carId,
        teamId: cosmetics.teamId,
        compatibility: compatibility.value,
        slot: slot,
        joinOrder: state.joinSerial,
        connected: false,
        presence: null,
        reconnectToken: nk.sha256Hash(nk.uuidv4() + ":" + state.roomCode + ":" + userId),
        reservationDeadline: tick + RESERVATION_TICKS,
        disconnectDeadline: -1,
        generationVerified: false,
        ready: false,
        lastSeq: {},
        inputRateTicks: [],
        snapshotRateTicks: [],
        controlRateTicks: [],
        malformedCount: 0,
        everJoined: false,
        reconnectCount: 0,
        lastInputTick: -1,
        latestInput: {steering: 0, throttle: 0, brake: 0}
    };
    updateLabel(dispatcher, state);
    return {state: state, data: JSON.stringify({
        ok: true,
        room_epoch: state.epoch,
        reconnect_token: state.members[userId].reconnectToken,
        slot: slot,
        resumed: false
    })};
}

function processMessage(nk, dispatcher, tick, state, message) {
    var member = state.members[message.sender.userId];
    if (!member || !member.connected) return;
    var text = nk.binaryToString(message.data);
    var envelopeResult = validateEnvelope(text, message.opCode, message.sender.userId, state.epoch);
    if (!envelopeResult.ok) {
        malformed(nk, dispatcher, tick, state, member, message.sender, envelopeResult.code);
        return;
    }
    var envelope = envelopeResult.value;
    var opcode = message.opCode;
    var sequenceKey = String(opcode);
    var lastSeq = Object.prototype.hasOwnProperty.call(member.lastSeq, sequenceKey) ?
        Number(member.lastSeq[sequenceKey]) : -1;
    if (envelope.seq <= lastSeq) {
        var staleCode = opcode === OP_INPUT_FRAME ? "input_sequence_stale" :
            (opcode === OP_STATE_SNAPSHOT ? "snapshot_sequence_stale" : "sequence_stale");
        sendError(nk, dispatcher, tick, state, message.sender, staleCode);
        return;
    }
    member.lastSeq[sequenceKey] = envelope.seq;
    if (opcode !== OP_INPUT_FRAME && opcode !== OP_STATE_SNAPSHOT &&
            !consumeRate(member.controlRateTicks, tick, MAX_CONTROL_MESSAGES_PER_SECOND)) {
        sendError(nk, dispatcher, tick, state, message.sender, "control_rate_limited");
        return;
    }
    if (opcode === OP_ROOM_CONFIG) {
        if (envelope.payload && envelope.payload.type === "room_lock") {
            handleRoomLock(nk, dispatcher, tick, state, member, message.sender, envelope);
        } else {
            handleRaceConfig(nk, dispatcher, tick, state, member, message.sender, envelope);
        }
    } else if (opcode === OP_TRACK_MANIFEST) {
        handleTrackManifest(nk, dispatcher, tick, state, member, message.sender, envelope);
    } else if (opcode === OP_GENERATION_REPORT) {
        handleGeneration(nk, dispatcher, tick, state, member, message.sender, envelope);
    } else if (opcode === OP_READY_STATE) {
        handleReady(nk, dispatcher, tick, state, member, message.sender, envelope);
    } else if (opcode === OP_START_AT_TICK) {
        handleStart(nk, dispatcher, tick, state, member, message.sender);
    } else if (opcode === OP_INPUT_FRAME) {
        handleInput(nk, dispatcher, tick, state, member, message, text, envelope);
    } else if (opcode === OP_STATE_SNAPSHOT) {
        handleSnapshot(nk, dispatcher, tick, state, member, message, text, envelope);
    } else if (opcode === OP_RACE_EVENT) {
        handleRaceEvent(nk, dispatcher, tick, state, member, message.sender, envelope);
    } else if (opcode === OP_ROOM_ENDED) {
        permanentLeave(nk, dispatcher, tick, state, member.userId, "peer_left");
    } else {
        sendError(nk, dispatcher, tick, state, message.sender, "opcode_not_accepted");
    }
}

function handleRaceConfig(nk, dispatcher, tick, state, member, sender, envelope) {
    if (member.userId !== state.hostUserId) return sendError(nk, dispatcher, tick, state, sender, "host_only");
    if (state.joinLocked) return sendError(nk, dispatcher, tick, state, sender, "room_locked");
    if (state.phase === "COUNTDOWN" || state.phase === "RACING" || state.phase === "RESULTS" || state.phase === "CLOSED") {
        return sendError(nk, dispatcher, tick, state, sender, "room_locked");
    }
    var p = envelope.payload;
    if (!p || p.type !== "race_config" || !integerIn(p.laps, 1, 5) ||
            !ALLOWED_LAP_COUNTS[String(p.laps)] || typeof p.collisions !== "boolean") {
        return sendError(nk, dispatcher, tick, state, sender, "race_config_invalid");
    }
    if (state.raceConfig.laps === p.laps && state.raceConfig.collisions === p.collisions) return;
    state.raceConfig = {laps: p.laps, collisions: p.collisions};
    state.countdown = null;
    eachMember(state, function (m) { m.ready = false; });
    state.phase = state.manifest ? (allGenerated(state) ? "READY" : "TRACK_SYNC") : "LOBBY";
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
}

function handleRoomLock(nk, dispatcher, tick, state, member, sender, envelope) {
    if (member.userId !== state.hostUserId) return sendError(nk, dispatcher, tick, state, sender, "host_only");
    if (state.phase === "COUNTDOWN" || state.phase === "RACING" || state.phase === "RESULTS" || state.phase === "CLOSED") {
        return sendError(nk, dispatcher, tick, state, sender, "room_locked");
    }
    if (!envelope.payload || typeof envelope.payload.locked !== "boolean") {
        return sendError(nk, dispatcher, tick, state, sender, "room_lock_invalid");
    }
    if (state.joinLocked === envelope.payload.locked) return;
    state.joinLocked = envelope.payload.locked;
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
}

function handleTrackManifest(nk, dispatcher, tick, state, member, sender, envelope) {
    if (member.userId !== state.hostUserId) return sendError(nk, dispatcher, tick, state, sender, "host_only");
    if (state.joinLocked) return sendError(nk, dispatcher, tick, state, sender, "room_locked");
    if (state.phase === "COUNTDOWN" || state.phase === "RACING" || state.phase === "CLOSED") {
        return sendError(nk, dispatcher, tick, state, sender, "room_locked");
    }
    var validation = validateManifest(nk, envelope.payload);
    if (!validation.ok) return sendError(nk, dispatcher, tick, state, sender, validation.code);
    state.manifest = envelope.payload;
    state.phase = "TRACK_SYNC";
    state.countdown = null;
    eachMember(state, function (m) { m.generationVerified = false; m.ready = false; });
    broadcastEnvelope(nk, dispatcher, tick, state, OP_TRACK_MANIFEST, envelope.payload, null, null, true);
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
}

function handleGeneration(nk, dispatcher, tick, state, member, sender, envelope) {
    var p = envelope.payload;
    var phaseLocked = state.phase === "COUNTDOWN" || state.phase === "RACING" ||
        state.phase === "RESULTS" || state.phase === "CLOSED";
    if (!state.manifest || typeof p.success !== "boolean" || typeof p.source_hash !== "string" ||
            typeof p.generator_version !== "number" || typeof p.compiled_fingerprint !== "string") {
        return sendError(nk, dispatcher, tick, state, sender, "generation_report_malformed");
    }
    if (!p.success || p.source_hash !== state.manifest.source_hash ||
            p.generator_version !== state.manifest.generator_version ||
            p.compiled_fingerprint !== state.manifest.compiled_fingerprint) {
        member.generationVerified = false;
        member.ready = false;
        if (!phaseLocked) state.phase = "TRACK_SYNC";
        broadcastRoomConfig(nk, dispatcher, tick, state);
        updateLabel(dispatcher, state);
        return sendError(nk, dispatcher, tick, state, sender, "track_identity_mismatch");
    }
    member.generationVerified = true;
    if (!phaseLocked && allGenerated(state)) state.phase = "READY";
    broadcastEnvelope(nk, dispatcher, tick, state, OP_GENERATION_REPORT, {
        player_id: member.userId,
        generation_verified: true
    }, null, null, true);
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
}

function handleReady(nk, dispatcher, tick, state, member, sender, envelope) {
    if (state.phase !== "TRACK_SYNC" && state.phase !== "READY") {
        return sendError(nk, dispatcher, tick, state, sender, "ready_unavailable");
    }
    if (typeof envelope.payload.ready !== "boolean") return sendError(nk, dispatcher, tick, state, sender, "ready_malformed");
    if (envelope.payload.ready && !member.generationVerified) {
        return sendError(nk, dispatcher, tick, state, sender, "generation_not_verified");
    }
    member.ready = envelope.payload.ready;
    broadcastEnvelope(nk, dispatcher, tick, state, OP_READY_STATE, {
        player_id: member.userId,
        ready: member.ready
    }, null, null, true);
    broadcastRoomConfig(nk, dispatcher, tick, state);
}

function handleStart(nk, dispatcher, tick, state, member, sender) {
    if (member.userId !== state.hostUserId) return sendError(nk, dispatcher, tick, state, sender, "host_only");
    if (!state.joinLocked) return sendError(nk, dispatcher, tick, state, sender, "room_not_locked");
    if (state.phase !== "READY" || !allReadyConnected(state)) {
        return sendError(nk, dispatcher, tick, state, sender, "players_not_ready");
    }
    state.phase = "COUNTDOWN";
    state.countdown = {
        issued_at_tick: tick * SIM_TICKS_PER_MATCH_TICK,
        start_tick: (tick + COUNTDOWN_MATCH_TICKS) * SIM_TICKS_PER_MATCH_TICK,
        match_start_tick: tick + COUNTDOWN_MATCH_TICKS,
        track_identity: manifestIdentity(state.manifest),
        roster: roster(state),
        race_config: {laps: state.raceConfig.laps, collisions: state.raceConfig.collisions},
        authority: "cloud"
    };
    state.raceSimulation = createCloudRaceSimulation(state);
    if (!state.raceSimulation) return sendError(nk, dispatcher, tick, state, sender, "cloud_simulation_unavailable");
    broadcastEnvelope(nk, dispatcher, tick, state, OP_START_AT_TICK, state.countdown, null, null, true);
    updateLabel(dispatcher, state);
}

function handleInput(nk, dispatcher, tick, state, member, message, text, envelope) {
    if (state.phase !== "RACING") return sendError(nk, dispatcher, tick, state, message.sender, "race_not_running");
    if (!validateInput(envelope)) {
        return malformed(nk, dispatcher, tick, state, member, message.sender, "input_malformed");
    }
    var authorityTick = tick * SIM_TICKS_PER_MATCH_TICK;
    if (envelope.tick < authorityTick - MAX_STALE_INPUT_TICKS) {
        return sendError(nk, dispatcher, tick, state, message.sender, "input_tick_stale");
    }
    if (envelope.tick > authorityTick + MAX_FUTURE_INPUT_TICKS) {
        return sendError(nk, dispatcher, tick, state, message.sender, "input_tick_future");
    }
    if (envelope.tick < member.lastInputTick) {
        return sendError(nk, dispatcher, tick, state, message.sender, "input_tick_out_of_order");
    }
    if (envelope.payload.ack_host_tick > authorityTick + MAX_FUTURE_INPUT_TICKS) {
        return sendError(nk, dispatcher, tick, state, message.sender, "input_ack_future");
    }
    if (!consumeRate(member.inputRateTicks, tick, MAX_INPUTS_PER_SECOND)) {
        return sendError(nk, dispatcher, tick, state, message.sender, "input_rate_limited");
    }
    member.lastInputTick = envelope.tick;
    member.latestInput = {
        steering: envelope.payload.steering,
        throttle: envelope.payload.throttle,
        brake: envelope.payload.brake
    };
}

function handleSnapshot(nk, dispatcher, tick, state, member, message, text, envelope) {
    return sendError(nk, dispatcher, tick, state, message.sender, "server_authority_only");
}

function handleRaceEvent(nk, dispatcher, tick, state, member, sender, envelope) {
    var eventType = String(envelope.payload.type || "");
    if (eventType === "kick_member") {
        if (member.userId !== state.hostUserId) return sendError(nk, dispatcher, tick, state, sender, "host_only");
        if (state.joinLocked) return sendError(nk, dispatcher, tick, state, sender, "room_locked");
        if (state.phase === "COUNTDOWN" || state.phase === "RACING" || state.phase === "RESULTS" || state.phase === "CLOSED") {
            return sendError(nk, dispatcher, tick, state, sender, "room_locked");
        }
        var targetId = String(envelope.payload.player_id || "");
        var target = state.members[targetId];
        if (!target || targetId === member.userId) return sendError(nk, dispatcher, tick, state, sender, "kick_target_invalid");
        if (target.connected && target.presence) {
            broadcastEnvelope(nk, dispatcher, tick, state, OP_ROOM_ENDED, {
                reason: "kicked_by_host", reconnectable: false
            }, [target.presence], null, true);
            dispatcher.matchKick([target.presence]);
        }
        state.bannedUserIds[targetId] = true;
        permanentLeave(nk, dispatcher, tick, state, targetId, "kicked_by_host");
        return;
    }
    if (eventType === "rematch") {
        if (state.phase !== "RESULTS") return sendError(nk, dispatcher, tick, state, sender, "rematch_unavailable");
        if (member.userId !== state.hostUserId) {
            var hostMember = state.members[state.hostUserId];
            if (hostMember && hostMember.connected && hostMember.presence) {
                broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
                    type: "rematch_requested", player_id: member.userId
                }, [hostMember.presence], null, true);
            }
            return;
        }
        state.countdown = null;
        state.raceSimulation = null;
        state.latestSnapshot = null;
        state.lastSnapshotTick = -1;
        state.lastSnapshotSequence = -1;
        eachMember(state, function (m) { m.ready = false; });
        state.phase = allGenerated(state) ? "READY" : "TRACK_SYNC";
        broadcastRoomConfig(nk, dispatcher, tick, state);
        updateLabel(dispatcher, state);
        return;
    }
    if (eventType === "race_complete") return sendError(nk, dispatcher, tick, state, sender, "server_authority_only");
    return sendError(nk, dispatcher, tick, state, sender, "race_event_type_invalid");
}

function validateRaceResults(results, state) {
    if (!Array.isArray(results) || results.length !== memberCount(state) || results.length < 1 || results.length > MAX_PLAYERS) return false;
    var ids = {};
    var slots = {};
    var positions = {};
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        if (!r || typeof r.player_id !== "string" || !state.members[r.player_id] || ids[r.player_id] ||
                !integerIn(r.slot, 0, MAX_PLAYERS - 1) || state.members[r.player_id].slot !== r.slot || slots[String(r.slot)] ||
                !integerIn(r.position, 1, results.length) || positions[String(r.position)] ||
                (r.status !== "finished" && r.status !== "dnf") || !integerIn(r.laps, 0, 99) ||
                !integerIn(r.finish_time_ms, 0, MAX_SAFE_SEQUENCE) || typeof r.dnf_reason !== "string" || r.dnf_reason.length > 40) return false;
        ids[r.player_id] = true;
        slots[String(r.slot)] = true;
        positions[String(r.position)] = true;
    }
    return true;
}

function validateEnvelope(text, opcode, senderId, epoch) {
    if (utf8Length(text) > MAX_MESSAGE_BYTES) return {ok: false, code: "message_too_large"};
    var parsed = parseObject(text);
    if (!parsed.ok) return {ok: false, code: "message_malformed"};
    var e = parsed.value;
    if (e.protocol !== PROTOCOL || e.opcode !== opcode || e.room_epoch !== epoch ||
            e.sender_id !== senderId || typeof e.seq !== "number" || e.seq < 0 || e.seq > MAX_SAFE_SEQUENCE ||
            Math.floor(e.seq) !== e.seq || !e.payload || typeof e.payload !== "object" || Array.isArray(e.payload)) {
        return {ok: false, code: "envelope_invalid"};
    }
    return {ok: true, value: e};
}

function validateManifest(nk, manifest) {
    if (!manifest || typeof manifest !== "object" || Array.isArray(manifest) ||
            !manifest.track_definition || typeof manifest.track_definition !== "object" ||
            !manifest.authority_path || typeof manifest.authority_path !== "object" || Array.isArray(manifest.authority_path) ||
            !validSha(manifest.source_hash) || !validSha(manifest.compiled_fingerprint) ||
            typeof manifest.generator_version !== "number" || manifest.generator_version <= 0 ||
            Math.floor(manifest.generator_version) !== manifest.generator_version) {
        return {ok: false, code: "track_manifest_malformed"};
    }
    var definitionText = JSON.stringify(manifest.track_definition);
    if (utf8Length(definitionText) > MAX_TRACK_BYTES) return {ok: false, code: "track_definition_too_large"};
    var definition = JSON.parse(definitionText);
    if (definition.generator_version !== manifest.generator_version) return {ok: false, code: "generator_version_mismatch"};
    delete definition.content_hash;
    var calculated = nk.sha256Hash(canonicalStringify(definition));
    if (calculated !== manifest.source_hash) return {ok: false, code: "track_source_hash_mismatch"};
    var pathValidation = validateAuthorityPath(nk, manifest.authority_path);
    if (!pathValidation.ok) return pathValidation;
    return {ok: true};
}

function validateInput(envelope) {
    if (typeof envelope.tick !== "number" || Math.floor(envelope.tick) !== envelope.tick ||
            envelope.tick < 0 || envelope.tick > MAX_SAFE_SEQUENCE) return false;
    var p = envelope.payload;
    return integerIn(p.steering, -1000, 1000) && integerIn(p.throttle, 0, 1000) &&
        integerIn(p.brake, 0, 1000) && p.boost === false &&
        integerIn(p.ack_host_tick, 0, MAX_SAFE_SEQUENCE);
}

function validateSnapshot(envelope) {
    if (!integerIn(envelope.tick, 0, MAX_SAFE_SEQUENCE) || !Array.isArray(envelope.payload.cars) ||
            envelope.payload.cars.length > MAX_PLAYERS) return false;
    var seen = {};
    for (var i = 0; i < envelope.payload.cars.length; i++) {
        var c = envelope.payload.cars[i];
        if (!c || !integerIn(c.slot, 0, MAX_PLAYERS - 1) || seen[String(c.slot)] ||
                !integerIn(c.x_q, -1000000000, 1000000000) || !integerIn(c.y_q, -1000000000, 1000000000) ||
                !integerIn(c.rotation_q, -6283185, 6283185) ||
                !integerIn(c.velocity_x_q, -10000000, 10000000) || !integerIn(c.velocity_y_q, -10000000, 10000000) ||
                !integerIn(c.lap, 0, 10000) || !integerIn(c.checkpoint, 0, 1000000) ||
                !integerIn(c.collision_layer, 1, 2) || !integerIn(c.collision_mask, 1, 3) ||
                (c.collision_mask & c.collision_layer) === 0 || !integerIn(c.flags, 0, 2147483647)) return false;
        // Protocol-v1 Formula dynamics are an optional all-or-nothing extension:
        // old clients remain readable, while new clients get bounded drivetrain,
        // steering, and tyre telemetry for prediction/reconciliation.
        var dynamicsKeys = ["gear", "engine_rpm_q", "shift_ticks", "steering_q",
            "slip_angle_q", "wheel_slip_q", "lateral_accel_q"];
        var dynamicsPresent = 0;
        for (var d = 0; d < dynamicsKeys.length; d++) {
            if (Object.prototype.hasOwnProperty.call(c, dynamicsKeys[d])) dynamicsPresent++;
        }
        if (dynamicsPresent !== 0 && dynamicsPresent !== dynamicsKeys.length) return false;
        if (dynamicsPresent === dynamicsKeys.length &&
                (!integerIn(c.gear, -1, 8) || !integerIn(c.engine_rpm_q, 0, 200000) ||
                !integerIn(c.shift_ticks, 0, 120) || !integerIn(c.steering_q, -10000, 10000) ||
                !integerIn(c.slip_angle_q, -15708, 15708) || !integerIn(c.wheel_slip_q, 0, 40000) ||
                !integerIn(c.lateral_accel_q, -2000000, 2000000))) return false;
        // Contact telemetry is another optional all-or-nothing extension. Its
        // serial persists after an impact so delayed guests cannot miss the
        // event; fixed position/normal data lets presentation place one spark
        // burst without trusting client-side proximity guesses.
        var contactKeys = ["contact_serial", "contact_tick", "contact_speed_q",
            "contact_x_q", "contact_y_q", "contact_normal_x_q", "contact_normal_y_q"];
        var contactPresent = 0;
        for (var k = 0; k < contactKeys.length; k++) {
            if (Object.prototype.hasOwnProperty.call(c, contactKeys[k])) contactPresent++;
        }
        if (contactPresent !== 0 && contactPresent !== contactKeys.length) return false;
        if (contactPresent === contactKeys.length) {
            var normalLengthSquared = c.contact_normal_x_q * c.contact_normal_x_q +
                c.contact_normal_y_q * c.contact_normal_y_q;
            if (!integerIn(c.contact_serial, 0, MAX_SAFE_SEQUENCE) ||
                    !integerIn(c.contact_tick, -1, MAX_SAFE_SEQUENCE) ||
                    (c.contact_serial > 0 && c.contact_tick < 0) ||
                    !integerIn(c.contact_speed_q, 0, 2000000) ||
                    !integerIn(c.contact_x_q, -1000000000, 1000000000) ||
                    !integerIn(c.contact_y_q, -1000000000, 1000000000) ||
                    !integerIn(c.contact_normal_x_q, -10000, 10000) ||
                    !integerIn(c.contact_normal_y_q, -10000, 10000) ||
                    normalLengthSquared < 9900 * 9900 || normalLengthSquared > 10100 * 10100) return false;
        }
        seen[String(c.slot)] = true;
    }
    return true;
}

function malformed(nk, dispatcher, tick, state, member, presence, code) {
    member.malformedCount++;
    sendError(nk, dispatcher, tick, state, presence, code);
    if (member.malformedCount >= MAX_MALFORMED) dispatcher.matchKick([presence]);
}

function sendError(nk, dispatcher, tick, state, presence, code) {
    broadcastEnvelope(nk, dispatcher, tick, state, OP_ERROR, {code: code}, [presence], null, true);
}

function broadcastRoomConfig(nk, dispatcher, tick, state) {
    broadcastEnvelope(nk, dispatcher, tick, state, OP_ROOM_CONFIG, {
        room_code: state.roomCode,
        room_epoch: state.epoch,
        state: state.phase,
        host_id: state.hostUserId,
        member_count: memberCount(state),
        members: roster(state),
        track_identity: manifestIdentity(state.manifest),
        race_config: {laps: state.raceConfig.laps, collisions: state.raceConfig.collisions},
        authority: "cloud",
        join_locked: state.joinLocked,
        countdown: state.countdown,
        close_reason: state.closeReason
    }, null, null, true);
}

function broadcastEnvelope(nk, dispatcher, tick, state, opcode, payload, targets, sender, reliable) {
    state.serverSeq++;
    dispatcher.broadcastMessage(opcode, JSON.stringify({
        protocol: PROTOCOL,
        opcode: opcode,
        room_epoch: state.epoch,
        sender_id: "server",
        seq: state.serverSeq,
        tick: tick * SIM_TICKS_PER_MATCH_TICK,
        payload: payload
    }), targets, sender, reliable);
}

function expireMembers(nk, dispatcher, tick, state) {
    var ids = Object.keys(state.members);
    for (var i = 0; i < ids.length; i++) {
        var member = state.members[ids[i]];
        var reservationExpired = !member.connected && member.disconnectDeadline < 0 &&
            member.reservationDeadline >= 0 && tick > member.reservationDeadline;
        var reconnectExpired = !member.connected && member.disconnectDeadline >= 0 && tick > member.disconnectDeadline;
        if (!reservationExpired && !reconnectExpired) continue;
        permanentLeave(nk, dispatcher, tick, state, member.userId,
            reconnectExpired ? "reconnect_expired" : "reservation_expired");
        if (state.phase === "CLOSED") return;
    }
}

function permanentLeave(nk, dispatcher, tick, state, userId, reason) {
    var wasHost = state.hostUserId === userId;
    if ((state.phase === "COUNTDOWN" || state.phase === "RACING") && state.raceSimulation) {
        markCloudCarDnf(state.raceSimulation, userId, reason);
    }
    delete state.members[userId];
    if (!wasHost) {
        if (state.manifest && state.phase !== "COUNTDOWN" && state.phase !== "RACING" &&
                state.phase !== "RESULTS" && state.phase !== "CLOSED") {
            state.phase = allGenerated(state) ? "READY" : "TRACK_SYNC";
        }
        broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
            type: "peer_departed", player_id: userId, reason: reason
        }, null, null, true);
        broadcastRoomConfig(nk, dispatcher, tick, state);
        updateLabel(dispatcher, state);
        return;
    }
    var successor = oldestConnected(state);
    if (!successor) {
        if (state.phase === "COUNTDOWN" || state.phase === "RACING" || state.phase === "RESULTS") {
            state.hostUserId = "";
            broadcastRoomConfig(nk, dispatcher, tick, state);
            updateLabel(dispatcher, state);
            return;
        }
        closeRoom(nk, dispatcher, tick, state, "host_departed_empty_room");
        return;
    }
    state.hostUserId = successor.userId;
    if (state.phase !== "COUNTDOWN" && state.phase !== "RACING" && state.phase !== "RESULTS") {
        state.epoch++;
        state.lastSnapshotSequence = -1;
        state.lastSnapshotTick = -1;
        eachMember(state, function (m) { m.lastSeq = {}; });
    }
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
}

function closeRoom(nk, dispatcher, tick, state, reason) {
    state.phase = "CLOSED";
    state.closeReason = reason;
    state.closeAtTick = tick + TICK_RATE;
    broadcastEnvelope(nk, dispatcher, tick, state, OP_ROOM_ENDED, {
        reason: reason,
        host_departure_policy: "continue_cloud",
        reconnectable: false
    }, null, null, true);
    cleanupRoomDirectory(nk, state);
    updateLabel(dispatcher, state);
}

function updateLabel(dispatcher, state) {
    dispatcher.matchLabelUpdate(roomLabel(state));
}

function roomLabel(state) {
    var open = (state.phase === "LOBBY" || state.phase === "TRACK_SYNC" || state.phase === "READY") &&
        !state.joinLocked && memberCount(state) < MAX_PLAYERS ? 1 : 0;
    return JSON.stringify({room_code: state.roomCode, open: open, phase: state.phase, size: memberCount(state)});
}

function claimRoomCode(nk, roomCode, hostUserId) {
    try {
        var acks = nk.storageWrite([{
            collection: ROOM_DIRECTORY_COLLECTION,
            key: roomCode,
            value: {status: "allocating", host_user_id: hostUserId},
            version: "*",
            permissionRead: 0,
            permissionWrite: 0
        }]);
        if (!acks || acks.length !== 1 || !acks[0].version) return {ok: false, version: ""};
        return {ok: true, version: String(acks[0].version)};
    } catch (error) {
        return {ok: false, version: ""};
    }
}

function publishRoomCode(nk, roomCode, matchId, hostUserId, claimVersion) {
    try {
        var acks = nk.storageWrite([{
            collection: ROOM_DIRECTORY_COLLECTION,
            key: roomCode,
            value: {status: "open", match_id: matchId, host_user_id: hostUserId},
            version: claimVersion,
            permissionRead: 0,
            permissionWrite: 0
        }]);
        if (!acks || acks.length !== 1 || !acks[0].version) return {ok: false, version: ""};
        return {ok: true, version: String(acks[0].version)};
    } catch (error) {
        return {ok: false, version: ""};
    }
}

function readRoomDirectory(nk, roomCode) {
    var objects = nk.storageRead([{collection: ROOM_DIRECTORY_COLLECTION, key: roomCode}]);
    if (!objects || objects.length !== 1 || !objects[0].value) {
        return {ok: false, matchId: "", version: ""};
    }
    var value = objects[0].value;
    if (value.status !== "open" || typeof value.match_id !== "string") {
        return {ok: false, matchId: "", version: String(objects[0].version || "")};
    }
    return {
        ok: true,
        matchId: value.match_id,
        version: String(objects[0].version || "")
    };
}

function removeRoomDirectory(nk, roomCode, version) {
    if (!roomCode) return;
    var request = {collection: ROOM_DIRECTORY_COLLECTION, key: roomCode};
    if (version) request.version = version;
    try {
        nk.storageDelete([request]);
    } catch (error) {
        // Cleanup is best effort. A newer directory version must never be removed
        // by a stale owner, while stale records self-heal on the next join attempt.
    }
}

function cleanupRoomDirectory(nk, state) {
    if (!state.directoryActive) return;
    removeRoomDirectory(nk, state.roomCode, state.directoryVersion);
    state.directoryActive = false;
}

function roster(state) {
    var out = [];
    eachMember(state, function (m) {
        out.push({
            player_id: m.userId,
            display_name: m.username,
            car_id: m.carId,
            team_id: m.teamId,
            slot: m.slot,
            connected: m.connected,
            generation_verified: m.generationVerified,
            ready: m.ready,
            is_host: m.userId === state.hostUserId
        });
    });
    out.sort(function (a, b) { return a.slot - b.slot; });
    return out;
}

function validatedCosmetics(carIdValue, teamIdValue) {
    var carId = String(carIdValue || "car-prime");
    var teamId = String(teamIdValue || "team-vector");
    if (!Object.prototype.hasOwnProperty.call(VEHICLE_TEAM_PAIRS, carId) || VEHICLE_TEAM_PAIRS[carId] !== teamId) {
        return {ok: false, carId: "", teamId: ""};
    }
    return {ok: true, carId: carId, teamId: teamId};
}

function validatedCompatibility(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return {ok: false};
    var platform = String(value.platform || "").toLowerCase();
    if (String(value.app_build || "") !== APP_BUILD || value.protocol_version !== PROTOCOL ||
            value.track_schema_version !== TRACK_SCHEMA_VERSION ||
            value.generator_version !== TRACK_GENERATOR_VERSION ||
            !Object.prototype.hasOwnProperty.call(SUPPORTED_PLATFORMS, platform)) return {ok: false};
    return {ok: true, value: {
        app_build: APP_BUILD,
        protocol_version: PROTOCOL,
        track_schema_version: TRACK_SCHEMA_VERSION,
        generator_version: TRACK_GENERATOR_VERSION,
        platform: platform
    }};
}

function manifestIdentity(manifest) {
    if (!manifest) return {source_hash: "", generator_version: 0, compiled_fingerprint: ""};
    return {
        source_hash: manifest.source_hash,
        generator_version: manifest.generator_version,
        compiled_fingerprint: manifest.compiled_fingerprint
    };
}

function allGenerated(state) {
    var ids = Object.keys(state.members);
    if (ids.length === 0) return false;
    for (var i = 0; i < ids.length; i++) if (!state.members[ids[i]].generationVerified) return false;
    return true;
}

function allReadyConnected(state) {
    var ids = Object.keys(state.members);
    if (ids.length === 0) return false;
    for (var i = 0; i < ids.length; i++) {
        var m = state.members[ids[i]];
        if (!m.connected || !m.generationVerified || !m.ready) return false;
    }
    return true;
}

function connectedCount(state) {
    var count = 0;
    eachMember(state, function (m) { if (m.connected) count++; });
    return count;
}

function memberCount(state) { return Object.keys(state.members).length; }
function hostConnected(state) { return state.members[state.hostUserId] && state.members[state.hostUserId].connected; }

function oldestConnected(state) {
    var oldest = null;
    eachMember(state, function (m) {
        if (m.connected && (!oldest || m.joinOrder < oldest.joinOrder)) oldest = m;
    });
    return oldest;
}

function connectedPresencesExcept(state, excludedUserId) {
    var out = [];
    eachMember(state, function (m) {
        if (m.connected && m.userId !== excludedUserId && m.presence) out.push(m.presence);
    });
    return out;
}

function eachMember(state, fn) {
    var ids = Object.keys(state.members);
    for (var i = 0; i < ids.length; i++) fn(state.members[ids[i]]);
}

function firstFreeSlot(state) {
    var used = {};
    eachMember(state, function (m) { used[String(m.slot)] = true; });
    for (var i = 0; i < MAX_PLAYERS; i++) if (!used[String(i)]) return i;
    return -1;
}

function consumeRpcRate(nk, bucketKey, maximum) {
    var cacheKey = "raceglyph:rpc-rate:" + bucketKey;
    var nowSeconds = Math.floor(Date.now() / 1000);
    var raw = String(nk.localcacheGet(cacheKey, "") || "");
    var bucket = parseObject(raw);
    var start = nowSeconds;
    var count = 0;
    if (bucket.ok && typeof bucket.value.start === "number" && typeof bucket.value.count === "number" &&
            nowSeconds - bucket.value.start < RPC_RATE_WINDOW_SECONDS) {
        start = Math.floor(bucket.value.start);
        count = Math.floor(bucket.value.count);
    }
    if (count >= maximum) return false;
    nk.localcachePut(cacheKey, JSON.stringify({start: start, count: count + 1}), RPC_RATE_WINDOW_SECONDS);
    return true;
}

function consumeRate(ticks, tick, maximum) {
    while (ticks.length > 0 && ticks[0] <= tick - TICK_RATE) ticks.shift();
    if (ticks.length >= maximum) return false;
    ticks.push(tick);
    return true;
}

function parseObject(text) {
    if (!text) return {ok: true, value: {}};
    try {
        var value = JSON.parse(text);
        if (!value || typeof value !== "object" || Array.isArray(value)) return {ok: false};
        return {ok: true, value: value};
    } catch (e) {
        return {ok: false};
    }
}

function rpcFailure(code, message) {
    return JSON.stringify({ok: false, error: {code: code, message: message}});
}

function boundedName(value) {
    var name = String(value || "").replace(/^\s+|\s+$/g, "");
    if (!name || name.length > 24 || /[\x00-\x1f]/.test(name)) return "";
    return name;
}

function validRoomCode(value) { return /^[A-HJ-NP-Z2-9]{6}$/.test(value); }
function validSha(value) { return typeof value === "string" && /^[0-9a-f]{64}$/.test(value); }
function integerIn(value, low, high) { return typeof value === "number" && Math.floor(value) === value && value >= low && value <= high; }
function utf8Length(value) { return unescape(encodeURIComponent(value)).length; }

function roomCodeFromUuid(uuid) {
    var alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    var hex = String(uuid).replace(/-/g, "");
    var output = "";
    for (var i = 0; i < 6; i++) output += alphabet.charAt(parseInt(hex.substr(i * 2, 2), 16) % alphabet.length);
    return output;
}

function validateAuthorityPath(nk, path) {
    var required = ["scale", "centerline_q", "elevation_q", "track_width_q", "total_length_q",
        "start_finish_distance_q", "road_surface", "deterministic_seed", "path_hash"];
    for (var r = 0; r < required.length; r++) {
        if (!Object.prototype.hasOwnProperty.call(path, required[r])) {
            return {ok: false, code: "authority_path_malformed"};
        }
    }
    if (path.scale !== 1000 || !Array.isArray(path.centerline_q) || !Array.isArray(path.elevation_q) ||
            path.centerline_q.length < 3 || path.centerline_q.length > 512 ||
            path.elevation_q.length !== path.centerline_q.length ||
            !integerIn(path.track_width_q, 1000, 4096000) ||
            !integerIn(path.total_length_q, 1, 1000000000) ||
            !integerIn(path.start_finish_distance_q, 0, path.total_length_q - 1) ||
            typeof path.road_surface !== "string" ||
            !/^-?[0-9]{1,20}$/.test(String(path.deterministic_seed || "")) ||
            !validSha(path.path_hash)) return {ok: false, code: "authority_path_malformed"};
    var surfaces = {smooth_asphalt: true, weathered_asphalt: true, bumpy_asphalt: true,
        compact_gravel: true, mud: true};
    if (!surfaces[path.road_surface]) return {ok: false, code: "authority_path_malformed"};
    for (var i = 0; i < path.centerline_q.length; i++) {
        var point = path.centerline_q[i];
        if (!Array.isArray(point) || point.length !== 2 ||
                !integerIn(point[0], -1000000000, 1000000000) ||
                !integerIn(point[1], -1000000000, 1000000000)) {
            return {ok: false, code: "authority_path_malformed"};
        }
        var next = path.centerline_q[(i + 1) % path.centerline_q.length];
        if (Array.isArray(next) && point[0] === next[0] && point[1] === next[1]) {
            return {ok: false, code: "authority_path_degenerate"};
        }
        if (!integerIn(path.elevation_q[i], 0, path.scale)) {
            return {ok: false, code: "authority_path_malformed"};
        }
    }
    if (utf8Length(JSON.stringify(path)) > 48000) return {ok: false, code: "authority_path_too_large"};
    var hashInput = JSON.parse(JSON.stringify(path));
    delete hashInput.path_hash;
    if (nk.sha256Hash(canonicalStringify(hashInput)) !== path.path_hash) {
        return {ok: false, code: "authority_path_hash_mismatch"};
    }
    return {ok: true};
}

function createCloudRaceSimulation(state) {
    if (!state.manifest || !state.manifest.authority_path || !state.countdown) return null;
    var source = state.manifest.authority_path;
    var track = {points: [], segments: [], starts: [], total: 0,
        width: source.track_width_q / source.scale, surface: source.road_surface};
    for (var p = 0; p < source.centerline_q.length; p++) {
        track.points.push({x: source.centerline_q[p][0] / source.scale,
            y: source.centerline_q[p][1] / source.scale,
            elevation: source.elevation_q[p] / source.scale});
    }
    for (var s = 0; s < track.points.length; s++) {
        var a = track.points[s];
        var b = track.points[(s + 1) % track.points.length];
        var dx = b.x - a.x;
        var dy = b.y - a.y;
        var length = Math.sqrt(dx * dx + dy * dy);
        if (!isFinite(length) || length <= 0.001) return null;
        track.starts.push(track.total);
        track.segments.push({x: dx, y: dy, length: length, tx: dx / length, ty: dy / length,
            elevationDelta: track.points[(s + 1) % track.points.length].elevation - a.elevation});
        track.total += length;
    }
    if (!isFinite(track.total) || track.total < 100 || track.total > 1000000) return null;
    var cars = [];
    var members = roster(state);
    for (var i = 0; i < members.length; i++) {
        var row = members[i].slot;
        var gridDistance = -8 - row * 9;
        var sample = cloudTrackSample(track, gridDistance);
        var lateral = (row % 2 === 0 ? -1 : 1) * Math.min(track.width * 0.22, 7);
        cars.push({
            playerId: members[i].player_id,
            slot: members[i].slot,
            x: sample.x + sample.nx * lateral,
            y: sample.y + sample.ny * lateral,
            heading: Math.atan2(sample.ty, sample.tx),
            vx: 0, vy: 0, segment: sample.segment, distance: sample.distance,
            lateral: lateral, raceDistance: gridDistance, laps: 0, checkpoint: 0,
            status: "racing", finishOrder: 0, finishTimeMs: 0, dnfReason: "",
            gear: 1, rpm: 4500, shiftTicks: 0, steering: 0,
            slip: 0, wheelSlip: 0, lateralAcceleration: 0, offtrack: false,
            groundElevation: sample.elevation, verticalOffset: 0, verticalVelocity: 0,
            grounded: true, collisionLayer: sample.elevation > 0.5 ? 2 : 1,
            collisionMask: sample.elevation > 0 && sample.elevation < 1 ? 3 : (sample.elevation > 0.5 ? 2 : 1)
        });
    }
    return {
        tick: state.countdown.start_tick,
        elapsedTicks: 0,
        maximumTicks: 60 * 600,
        lapTarget: state.raceConfig.laps,
        collisions: state.raceConfig.collisions,
        finishSerial: 0,
        track: track,
        cars: cars
    };
}

function simulateCloudRaceStep(state) {
    var simulation = state.raceSimulation;
    simulation.tick++;
    simulation.elapsedTicks++;
    var surface = cloudSurfaceProfile(simulation.track.surface);
    for (var i = 0; i < simulation.cars.length; i++) {
        var car = simulation.cars[i];
        if (car.status !== "racing") continue;
        var member = state.members[car.playerId];
        var input = {steering: 0, throttle: 0, brake: 0};
        if (member && member.connected && member.lastInputTick >= simulation.tick - 12) input = member.latestInput;
        cloudVehicleStep(car, input, simulation.track, surface);
        cloudUpdateProgress(simulation, car);
    }
    if (simulation.collisions) cloudResolveVehicleContacts(simulation.cars, simulation.track);
    if (simulation.elapsedTicks >= simulation.maximumTicks) {
        for (var c = 0; c < simulation.cars.length; c++) {
            if (simulation.cars[c].status === "racing") markCloudCarDnf(simulation, simulation.cars[c].playerId, "time_limit");
        }
    }
}

function cloudVehicleStep(car, rawInput, track, surface) {
    var dt = 1 / 60;
    var previousGroundElevation = car.groundElevation;
    var requestedSteering = clamp(rawInput.steering / 1000, -1, 1);
    var throttle = clamp(rawInput.throttle / 1000, 0, 1);
    var brake = clamp(rawInput.brake / 1000, 0, 1);
    car.steering = moveToward(car.steering, requestedSteering,
        (Math.abs(requestedSteering) <= 0.0001 ? 7.2 : 5.4) * dt);
    var fx = Math.cos(car.heading);
    var fy = Math.sin(car.heading);
    var rx = -fy;
    var ry = fx;
    var longitudinal = car.vx * fx + car.vy * fy;
    var lateral = car.vx * rx + car.vy * ry;
    cloudUpdateDrivetrain(car, throttle, brake, longitudinal);
    var tyreContact = car.grounded;
    var engineFactor = car.offtrack ? 0.42 : 1;
    var acceleration = 0;
    car.wheelSlip = 0;
    if (!tyreContact) {
        acceleration -= 0.00024 * longitudinal * Math.abs(longitudinal);
    } else if (brake > 0) {
        if (longitudinal > 1) {
            var brakeCapacity = (76 + 0.001 * longitudinal * longitudinal) *
                (car.offtrack ? 1 : surface.braking);
            longitudinal = moveToward(longitudinal, 0, brake * brakeCapacity * dt);
        } else {
            acceleration -= brake * 30;
        }
    } else if (throttle > 0 && tyreContact) {
        var requestedDrive = cloudDriveAcceleration(car, throttle) * engineFactor *
            (car.offtrack ? 1 : surface.drive);
        var traction = 43 + 0.00020 * longitudinal * longitudinal;
        traction *= car.offtrack ? 0.48 : surface.traction;
        car.wheelSlip = Math.max(0, (requestedDrive - traction) / Math.max(traction, 1));
        acceleration += Math.min(requestedDrive, traction);
    } else {
        var coast = 3.8 + (car.gear > 0 && longitudinal > 0 ? 10.5 * cloudEngineBrakeFactor(car) : 0);
        longitudinal = moveToward(longitudinal, 0, coast * dt);
    }
    if (tyreContact) acceleration -= 0.00024 * longitudinal * Math.abs(longitudinal);
    if (tyreContact && !car.offtrack) acceleration -= surface.speedDrag * longitudinal;
    longitudinal += acceleration * dt;
    if (!tyreContact) {
        longitudinal = clamp(longitudinal, -58, 310);
    } else if (car.offtrack) {
        var resistanceRatio = clamp(Math.abs(longitudinal) / 80, 0, 1);
        resistanceRatio = resistanceRatio * resistanceRatio * (3 - 2 * resistanceRatio);
        longitudinal = moveToward(longitudinal, 0, mix(6, 125, resistanceRatio) * dt);
    } else {
        longitudinal = moveToward(longitudinal, 0, surface.rolling * dt);
    }
    longitudinal = clamp(longitudinal, -58, 310);
    car.vx = fx * longitudinal + rx * lateral;
    car.vy = fy * longitudinal + ry * lateral;
    var speed = Math.abs(longitudinal);
    var fade = clamp(speed / 235, 0, 1);
    fade = fade * fade * (3 - 2 * fade);
    var steerAngle = mix(0.47, 0.153, fade);
    var requestedYaw = tyreContact ? longitudinal / 18 * Math.tan(car.steering * steerAngle) : 0;
    var lateralCapacity = (65 + 0.00168 * speed * speed) * (car.offtrack ? 0.46 : surface.lateralCapacity);
    var maximumYaw = lateralCapacity / Math.max(speed, 12);
    car.heading = wrapAngle(car.heading + clamp(requestedYaw, -maximumYaw, maximumYaw) * dt);
    fx = Math.cos(car.heading);
    fy = Math.sin(car.heading);
    rx = -fy;
    ry = fx;
    longitudinal = car.vx * fx + car.vy * fy;
    lateral = car.vx * rx + car.vy * ry;
    car.slip = Math.atan2(lateral, Math.max(Math.abs(longitudinal), 1));
    car.lateralAcceleration = 0;
    if (tyreContact) {
        var grip = speed >= 168 && Math.abs(requestedSteering) > 0.55 ? 4.2 : 8.8;
        grip *= car.offtrack ? 0.55 : surface.lateralGrip;
        var excessSlip = Math.max(0, Math.abs(car.slip) / 0.19 - 1);
        var slideFactor = mix(1, 0.56, clamp(excessSlip * 0.55, 0, 1));
        car.lateralAcceleration = clamp(-lateral * grip,
            -lateralCapacity * slideFactor, lateralCapacity * slideFactor);
        lateral += car.lateralAcceleration * dt;
    }
    car.vx = fx * longitudinal + rx * lateral;
    car.vy = fy * longitudinal + ry * lateral;
    car.x += car.vx * dt;
    car.y += car.vy * dt;
    var projection = cloudTrackProject(track, car.x, car.y, car.segment);
    var roadLimit = Math.max(0.1, track.width * 0.5 - 4.5);
    var wallLimit = track.width * 0.5 + 18;
    car.offtrack = Math.abs(projection.lateral) > roadLimit;
    if (Math.abs(projection.lateral) > wallLimit) {
        var boundedLateral = clamp(projection.lateral, -wallLimit, wallLimit);
        car.x = projection.x + projection.nx * boundedLateral;
        car.y = projection.y + projection.ny * boundedLateral;
        var tangentSpeed = car.vx * projection.tx + car.vy * projection.ty;
        car.vx = projection.tx * tangentSpeed * 0.72;
        car.vy = projection.ty * tangentSpeed * 0.72;
        projection = cloudTrackProject(track, car.x, car.y, projection.segment);
    }
    var previousDistance = car.distance;
    car.segment = projection.segment;
    car.distance = projection.distance;
    car.lateral = projection.lateral;
    car.progressDelta = wrappedDelta(previousDistance, car.distance, track.total);
    cloudUpdateVertical(car, previousGroundElevation, projection.elevation, projection.segment,
        track, Math.abs(longitudinal), !car.offtrack);
    cloudRefreshRpm(car, throttle, longitudinal);
    car.x = quantize(car.x, 10000);
    car.y = quantize(car.y, 10000);
    car.vx = quantize(car.vx, 10000);
    car.vy = quantize(car.vy, 10000);
    car.heading = quantize(car.heading, 1000000);
}

function cloudUpdateVertical(car, beforeElevation, afterElevation, segmentIndex, track, speed, onRoad) {
    var dt = 1 / 60;
    var beforeGround = clamp(beforeElevation, 0, 1) * 6;
    var afterGround = clamp(afterElevation, 0, 1) * 6;
    if (!car.grounded) {
        var nextVelocity = car.verticalVelocity - 9.80665 * dt;
        var nextHeight = beforeGround + car.verticalOffset + car.verticalVelocity * dt -
            0.5 * 9.80665 * dt * dt;
        if (nextHeight <= afterGround + 0.001) {
            car.verticalOffset = 0;
            car.verticalVelocity = 0;
            car.grounded = true;
        } else {
            car.verticalOffset = nextHeight - afterGround;
            car.verticalVelocity = nextVelocity;
        }
    } else {
        car.verticalOffset = 0;
        car.verticalVelocity = 0;
        var speedMps = speed * 0.30;
        if (onRoad && speedMps >= 32 && beforeElevation > 0.0002 && beforeElevation < 0.9998 &&
                afterElevation >= 0.9998) {
            var previousSegment = track.segments[positiveModulo(segmentIndex - 1, track.segments.length)];
            var rampRunMeters = Math.max(previousSegment.length * 0.30, 0.001);
            var rampRiseMeters = Math.max(previousSegment.elevationDelta * 6, 0);
            var launchVelocity = speedMps * rampRiseMeters / rampRunMeters * 0.30;
            if (launchVelocity >= 1) {
                car.grounded = false;
                car.verticalVelocity = clamp(launchVelocity, 1, 4.6);
            }
        }
    }
    car.groundElevation = afterElevation;
    car.collisionLayer = afterElevation > 0.5 ? 2 : 1;
    car.collisionMask = afterElevation > 0 && afterElevation < 1 ? 3 : car.collisionLayer;
    car.verticalOffset = quantize(Math.max(car.verticalOffset, 0), 10000);
    car.verticalVelocity = quantize(car.verticalVelocity, 10000);
}

function cloudUpdateDrivetrain(car, throttle, brake, longitudinal) {
    var speed = Math.abs(longitudinal);
    if (car.shiftTicks > 0) {
        car.shiftTicks--;
        cloudRefreshRpm(car, throttle, longitudinal);
        return;
    }
    if (longitudinal < -1 && !(throttle > 0.02 && brake <= 0.02)) {
        car.gear = -1;
        cloudRefreshRpm(car, brake, longitudinal);
        return;
    }
    if (longitudinal <= 1 && brake > 0 && throttle <= 0.02) {
        car.gear = -1;
        cloudRefreshRpm(car, brake, longitudinal);
        return;
    }
    if (car.gear <= 0) car.gear = 1;
    cloudRefreshRpm(car, throttle, longitudinal);
    var downshift = [0, 55, 88, 121, 154, 187, 219, 250];
    if (car.gear < 8 && car.rpm >= 11800) {
        car.gear++;
        car.shiftTicks = 5;
    } else if (car.gear > 1 && speed < downshift[car.gear - 1]) {
        car.gear--;
        car.shiftTicks = 5;
    }
}

function cloudRefreshRpm(car, pedal, longitudinal) {
    var speed = Math.abs(longitudinal);
    if (car.gear < 0) {
        car.rpm = mix(4500, 8496, clamp(speed / 58, 0, 1));
        return;
    }
    var limits = [72, 108, 146, 184, 221, 255, 285, 310];
    var speedLimit = limits[clamp(car.gear - 1, 0, 7)];
    var coupled = 12500 * speed / Math.max(speedLimit, 1);
    var launch = car.gear === 1 && speed < 21.6 ? mix(4500, 6500, clamp(pedal, 0, 1)) : 4500;
    car.rpm = clamp(Math.max(coupled, launch), 4500, 12500);
}

function cloudDriveAcceleration(car, throttle) {
    if (car.gear <= 0) return 0;
    var factors = [1, 0.96, 0.89, 0.82, 0.75, 0.69, 0.63, 0.58];
    var normalized = clamp((car.rpm - 4500) / 8000, 0, 1);
    var powerBand = normalized <= 0.55 ? mix(0.72, 1, normalized / 0.55) :
        mix(1, 0.80, (normalized - 0.55) / 0.45);
    return throttle * 58 * factors[clamp(car.gear - 1, 0, 7)] * powerBand *
        (car.shiftTicks > 0 ? 0.08 : 1);
}

function cloudEngineBrakeFactor(car) {
    return mix(0.35, 1, clamp((car.rpm - 4500) / 8000, 0, 1));
}

function cloudUpdateProgress(simulation, car) {
    var delta = car.progressDelta || 0;
    if (Math.abs(delta) < simulation.track.total * 0.1) car.raceDistance += delta;
    car.raceDistance = Math.max(-200, car.raceDistance);
    var completed = Math.max(0, car.raceDistance);
    car.laps = Math.min(simulation.lapTarget, Math.floor(completed / simulation.track.total));
    var withinLap = completed % simulation.track.total;
    car.checkpoint = Math.floor(withinLap / simulation.track.total * 8);
    if (completed >= simulation.lapTarget * simulation.track.total) {
        simulation.finishSerial++;
        car.status = "finished";
        car.finishOrder = simulation.finishSerial;
        car.finishTimeMs = Math.floor(simulation.elapsedTicks * 1000 / 60);
        car.vx = 0;
        car.vy = 0;
    }
}

function cloudResolveVehicleContacts(cars, track) {
    for (var iteration = 0; iteration < 4; iteration++) {
        for (var i = 0; i < cars.length; i++) {
            if (cars[i].status !== "racing") continue;
            for (var j = i + 1; j < cars.length; j++) {
                if (cars[j].status !== "racing") continue;
                if ((cars[i].collisionMask & cars[j].collisionLayer) === 0 ||
                        (cars[j].collisionMask & cars[i].collisionLayer) === 0) continue;
                var dx = cars[j].x - cars[i].x;
                var dy = cars[j].y - cars[i].y;
                var distanceSquared = dx * dx + dy * dy;
                if (distanceSquared >= 81) continue;
                var distance = Math.sqrt(Math.max(distanceSquared, 0.000001));
                var nx = dx / distance;
                var ny = dy / distance;
                var overlap = 9 - distance;
                cars[i].x -= nx * overlap * 0.5;
                cars[i].y -= ny * overlap * 0.5;
                cars[j].x += nx * overlap * 0.5;
                cars[j].y += ny * overlap * 0.5;
                var relative = (cars[j].vx - cars[i].vx) * nx + (cars[j].vy - cars[i].vy) * ny;
                if (relative < 0) {
                    var impulse = -relative * 0.59;
                    cars[i].vx -= nx * impulse;
                    cars[i].vy -= ny * impulse;
                    cars[j].vx += nx * impulse;
                    cars[j].vy += ny * impulse;
                }
            }
        }
    }
    for (var c = 0; c < cars.length; c++) {
        var projection = cloudTrackProject(track, cars[c].x, cars[c].y, cars[c].segment);
        cars[c].segment = projection.segment;
        cars[c].distance = projection.distance;
        cars[c].lateral = projection.lateral;
    }
}

function broadcastCloudSnapshot(dispatcher, state) {
    var simulation = state.raceSimulation;
    var cars = [];
    for (var i = 0; i < simulation.cars.length; i++) cars.push(cloudCarSnapshot(simulation.cars[i]));
    cars.sort(function (a, b) { return a.slot - b.slot; });
    state.serverSeq++;
    var envelope = {
        protocol: PROTOCOL,
        opcode: OP_STATE_SNAPSHOT,
        room_epoch: state.epoch,
        sender_id: "server",
        seq: state.serverSeq,
        tick: simulation.tick,
        payload: {cars: cars, authority: "cloud"}
    };
    state.latestSnapshot = envelope;
    state.lastSnapshotTick = simulation.tick;
    state.lastSnapshotSequence = envelope.seq;
    dispatcher.broadcastMessage(OP_STATE_SNAPSHOT, JSON.stringify(envelope), null, null, false);
}

function cloudCarSnapshot(car) {
    var flags = car.offtrack ? 1 : 0;
    if (car.status === "finished") flags |= 2;
    if (car.status === "dnf") flags |= 4;
    return {
        slot: car.slot,
        x_q: boundedInteger(car.x * 10000, -1000000000, 1000000000),
        y_q: boundedInteger(car.y * 10000, -1000000000, 1000000000),
        rotation_q: boundedInteger(car.heading * 1000000, -6283185, 6283185),
        velocity_x_q: boundedInteger(car.vx * 10000, -10000000, 10000000),
        velocity_y_q: boundedInteger(car.vy * 10000, -10000000, 10000000),
        lap: car.laps,
        checkpoint: car.checkpoint,
        collision_layer: car.collisionLayer,
        collision_mask: car.collisionMask,
        flags: flags,
        gear: car.gear,
        engine_rpm_q: boundedInteger(car.rpm * 10, 0, 200000),
        shift_ticks: car.shiftTicks,
        steering_q: boundedInteger(car.steering * 10000, -10000, 10000),
        slip_angle_q: boundedInteger(car.slip * 10000, -15708, 15708),
        wheel_slip_q: boundedInteger(car.wheelSlip * 10000, 0, 40000),
        lateral_accel_q: boundedInteger(car.lateralAcceleration * 1000, -2000000, 2000000),
        vertical_offset_q: boundedInteger(car.verticalOffset * 10000, 0, 200000),
        vertical_velocity_q: boundedInteger(car.verticalVelocity * 10000, -100000, 100000),
        grounded: car.grounded ? 1 : 0
    };
}

function cloudRaceComplete(simulation) {
    if (!simulation || simulation.cars.length === 0) return false;
    for (var i = 0; i < simulation.cars.length; i++) if (simulation.cars[i].status === "racing") return false;
    return true;
}

function finishCloudRace(nk, dispatcher, tick, state) {
    if (state.phase !== "RACING" || !state.raceSimulation) return;
    var ordered = state.raceSimulation.cars.slice();
    ordered.sort(function (a, b) {
        if (a.status === "finished" && b.status === "finished") return a.finishOrder - b.finishOrder;
        if (a.status === "finished") return -1;
        if (b.status === "finished") return 1;
        return b.raceDistance - a.raceDistance || a.slot - b.slot;
    });
    var results = [];
    for (var i = 0; i < ordered.length; i++) {
        results.push({
            player_id: ordered[i].playerId,
            slot: ordered[i].slot,
            position: i + 1,
            status: ordered[i].status,
            laps: ordered[i].laps,
            finish_time_ms: ordered[i].finishTimeMs,
            dnf_reason: ordered[i].dnfReason
        });
    }
    state.phase = "RESULTS";
    broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
        type: "race_complete", results: results, authority: "cloud"
    }, null, null, true);
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
}

function markCloudCarDnf(simulation, playerId, reason) {
    if (!simulation) return;
    for (var i = 0; i < simulation.cars.length; i++) {
        var car = simulation.cars[i];
        if (car.playerId !== playerId || car.status !== "racing") continue;
        car.status = "dnf";
        car.dnfReason = String(reason || "peer_departed").substring(0, 40);
        car.finishTimeMs = Math.floor(simulation.elapsedTicks * 1000 / 60);
        car.vx = 0;
        car.vy = 0;
        return;
    }
}

function cloudTrackSample(track, distance) {
    var wrapped = positiveModulo(distance, track.total);
    var segment = 0;
    while (segment + 1 < track.starts.length && track.starts[segment + 1] <= wrapped) segment++;
    var amount = (wrapped - track.starts[segment]) / track.segments[segment].length;
    var point = track.points[segment];
    var line = track.segments[segment];
    return {x: point.x + line.x * amount, y: point.y + line.y * amount,
        tx: line.tx, ty: line.ty, nx: -line.ty, ny: line.tx,
        elevation: point.elevation + line.elevationDelta * amount,
        segment: segment, distance: wrapped};
}

function cloudTrackProject(track, x, y, hint) {
    var best = null;
    var count = track.segments.length;
    var window = Math.min(24, count);
    for (var offset = -window; offset <= window; offset++) {
        var index = positiveModulo((hint || 0) + offset, count);
        best = cloudProjectSegment(track, index, x, y, best);
    }
    if (!best || best.distanceSquared > Math.pow(track.width + 64, 2)) {
        best = null;
        for (var i = 0; i < count; i++) best = cloudProjectSegment(track, i, x, y, best);
    }
    return best;
}

function cloudProjectSegment(track, index, x, y, best) {
    var point = track.points[index];
    var line = track.segments[index];
    var amount = clamp(((x - point.x) * line.x + (y - point.y) * line.y) /
        (line.length * line.length), 0, 1);
    var px = point.x + line.x * amount;
    var py = point.y + line.y * amount;
    var dx = x - px;
    var dy = y - py;
    var distanceSquared = dx * dx + dy * dy;
    if (best && best.distanceSquared <= distanceSquared) return best;
    return {x: px, y: py, tx: line.tx, ty: line.ty, nx: -line.ty, ny: line.tx,
        lateral: dx * -line.ty + dy * line.tx,
        elevation: point.elevation + line.elevationDelta * amount,
        segment: index, distance: positiveModulo(track.starts[index] + line.length * amount, track.total),
        distanceSquared: distanceSquared};
}

function cloudSurfaceProfile(style) {
    var profiles = {
        smooth_asphalt: [1, 1, 1, 1, 1, 0, 0],
        weathered_asphalt: [0.80, 0.78, 0.80, 0.82, 0.93, 0.018, 2.8],
        bumpy_asphalt: [0.82, 0.80, 0.78, 0.80, 0.84, 0.032, 4],
        compact_gravel: [0.62, 0.58, 0.60, 0.62, 0.76, 0.050, 7],
        mud: [0.48, 0.38, 0.42, 0.45, 0.70, 0.070, 7.5]
    };
    var value = profiles[style] || profiles.smooth_asphalt;
    return {traction: value[0], braking: value[1], lateralCapacity: value[2],
        lateralGrip: value[3], drive: value[4], speedDrag: value[5], rolling: value[6]};
}

function clamp(value, minimum, maximum) { return Math.max(minimum, Math.min(maximum, value)); }
function mix(first, second, amount) { return first + (second - first) * amount; }
function moveToward(value, target, delta) {
    if (value < target) return Math.min(value + delta, target);
    return Math.max(value - delta, target);
}
function positiveModulo(value, divisor) { return ((value % divisor) + divisor) % divisor; }
function wrappedDelta(previous, current, total) {
    var delta = current - previous;
    if (delta > total * 0.5) delta -= total;
    if (delta < -total * 0.5) delta += total;
    return delta;
}
function wrapAngle(value) {
    while (value > Math.PI) value -= Math.PI * 2;
    while (value < -Math.PI) value += Math.PI * 2;
    return value;
}
function quantize(value, scale) { return Math.round(value * scale) / scale; }
function boundedInteger(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, Math.round(value)));
}

function canonicalStringify(value) {
    if (value === null) return "null";
    if (typeof value === "number") return canonicalNumber(value);
    if (typeof value === "boolean" || typeof value === "string") return JSON.stringify(value);
    if (Array.isArray(value)) {
        var parts = [];
        for (var i = 0; i < value.length; i++) parts.push(canonicalStringify(value[i]));
        return "[" + parts.join(",") + "]";
    }
    var keys = Object.keys(value).sort();
    var pairs = [];
    for (var k = 0; k < keys.length; k++) pairs.push(JSON.stringify(keys[k]) + ":" + canonicalStringify(value[keys[k]]));
    return "{" + pairs.join(",") + "}";
}

function canonicalNumber(value) {
    if (!isFinite(value)) return JSON.stringify(value < 0 ? "-Infinity" : (value > 0 ? "Infinity" : "NaN"));
    // Mirrors game/core/canonical_json.gd: nine fixed decimals, trimmed.
    // Track schema values are quantized before hashing, so this normalizes the
    // float32 JSON expansion produced by Godot's Vector2 storage.
    var formatted = value.toFixed(9);
    while (formatted.indexOf(".") >= 0 && formatted.charAt(formatted.length - 1) === "0") {
        formatted = formatted.substring(0, formatted.length - 1);
    }
    if (formatted.charAt(formatted.length - 1) === ".") formatted = formatted.substring(0, formatted.length - 1);
    return formatted === "-0" ? "0" : formatted;
}
