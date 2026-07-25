// RaceGlyph Nakama authoritative room runtime.
// ES5 is required by Nakama's embedded JavaScript runtime.

var MODULE_NAME = "raceglyph_private_room_v3";
var RPC_CREATE = "raceglyph_create_room";
var RPC_JOIN = "raceglyph_join_room";
var RPC_LEAVE = "raceglyph_leave_room";
var ROOM_DIRECTORY_COLLECTION = "raceglyph_private_room_directory_v3";
var PROTOCOL = 3;
var APP_BUILD = "0.3.0";
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
var MAX_SNAPSHOTS_PER_SECOND = 15;
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
        if (hostConnected(state)) {
            state.phase = "RACING";
            broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
                type: "race_started",
                tick: state.countdown.start_tick
            }, null, null, true);
            updateLabel(dispatcher, state);
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
        lastInputTick: -1
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
        race_config: {laps: state.raceConfig.laps, collisions: state.raceConfig.collisions}
    };
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
    var host = state.members[state.hostUserId];
    if (host && host.connected && host.userId !== member.userId) {
        dispatcher.broadcastMessage(OP_INPUT_FRAME, text, [host.presence], message.sender, false);
    }
}

function handleSnapshot(nk, dispatcher, tick, state, member, message, text, envelope) {
    if (member.userId !== state.hostUserId) return sendError(nk, dispatcher, tick, state, message.sender, "host_only");
    if (state.phase !== "RACING") return sendError(nk, dispatcher, tick, state, message.sender, "race_not_running");
    if (!validateSnapshot(envelope)) return malformed(nk, dispatcher, tick, state, member, message.sender, "snapshot_malformed");
    var authorityTick = tick * SIM_TICKS_PER_MATCH_TICK;
    if (envelope.tick < state.lastSnapshotTick) {
        return sendError(nk, dispatcher, tick, state, message.sender, "snapshot_tick_stale");
    }
    if (envelope.tick > authorityTick + MAX_FUTURE_INPUT_TICKS) {
        return sendError(nk, dispatcher, tick, state, message.sender, "snapshot_tick_future");
    }
    if (!consumeRate(member.snapshotRateTicks, tick, MAX_SNAPSHOTS_PER_SECOND)) {
        return sendError(nk, dispatcher, tick, state, message.sender, "snapshot_rate_limited");
    }
    state.latestSnapshot = envelope;
    state.lastSnapshotTick = envelope.tick;
    state.lastSnapshotSequence = envelope.seq;
    var targets = connectedPresencesExcept(state, state.hostUserId);
    if (targets.length > 0) dispatcher.broadcastMessage(OP_STATE_SNAPSHOT, text, targets, message.sender, false);
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
        state.latestSnapshot = null;
        state.lastSnapshotTick = -1;
        state.lastSnapshotSequence = -1;
        eachMember(state, function (m) { m.ready = false; });
        state.phase = allGenerated(state) ? "READY" : "TRACK_SYNC";
        broadcastRoomConfig(nk, dispatcher, tick, state);
        updateLabel(dispatcher, state);
        return;
    }
    if (eventType !== "race_complete") return sendError(nk, dispatcher, tick, state, sender, "race_event_type_invalid");
    if (member.userId !== state.hostUserId) return sendError(nk, dispatcher, tick, state, sender, "host_only");
    if (state.phase !== "RACING") return sendError(nk, dispatcher, tick, state, sender, "race_not_running");
    if (!validateRaceResults(envelope.payload.results, state)) {
        return sendError(nk, dispatcher, tick, state, sender, "race_results_invalid");
    }
    state.phase = "RESULTS";
    broadcastEnvelope(nk, dispatcher, tick, state, OP_RACE_EVENT, {
        type: "race_complete",
        results: envelope.payload.results
    }, null, null, true);
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
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
    if (state.phase === "COUNTDOWN" || state.phase === "RACING" || state.phase === "RESULTS") {
        closeRoom(nk, dispatcher, tick, state, "simulation_host_departed");
        return;
    }
    var successor = oldestConnected(state);
    if (!successor) {
        closeRoom(nk, dispatcher, tick, state, "host_departed_empty_room");
        return;
    }
    state.hostUserId = successor.userId;
    state.epoch++;
    state.lastSnapshotSequence = -1;
    state.lastSnapshotTick = -1;
    eachMember(state, function (m) { m.lastSeq = {}; });
    broadcastRoomConfig(nk, dispatcher, tick, state);
    updateLabel(dispatcher, state);
}

function closeRoom(nk, dispatcher, tick, state, reason) {
    state.phase = "CLOSED";
    state.closeReason = reason;
    state.closeAtTick = tick + TICK_RATE;
    broadcastEnvelope(nk, dispatcher, tick, state, OP_ROOM_ENDED, {
        reason: reason,
        host_departure_policy: "end_race",
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
