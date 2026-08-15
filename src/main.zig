const r4os = @import("r4os");
const r4std = @import("r4std");

const service_name = "TIMESVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";

const TimeServiceState = struct {
    config: r4std.time.Config = .{},
    config_loaded: bool = false,
    config_valid: bool = true,
    default_utc: bool = true,
    revision: u32 = 1,
    requests: u64 = 0,
    status_requests: u64 = 0,
    config_writes: u64 = 0,
    reloads: u64 = 0,
    bad_ops: u64 = 0,
    self_tests: u64 = 0,
    last_error: [r4os.abi.time_service_error_bytes]u8 = .{0} ** r4os.abi.time_service_error_bytes,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    var ctx = r4_app.system();
    if (hasArg(ctx.argsRaw(), selftest_arg)) return runSelfTest(&ctx);
    if (hasArg(ctx.argsRaw(), ping_arg)) return runPing(&ctx);
    return runService(&ctx);
}

fn runService(ctx: *const r4os.r4sys.Context) i32 {
    if (!ctx.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < 100 and handle == 0) : (waited += 1) {
        const rc = ctx.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            ctx.write("TIMESVC endpoint handle=");
            ctx.printU64(@intCast(handle));
            ctx.println("");
            break;
        }
        ctx.sleepTicks(1);
    }
    if (handle == 0) {
        ctx.println("TIMESVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state = TimeServiceState{};
    loadConfig(ctx, &state, false);

    while (!ctx.programShouldClose()) {
        const poll = ctx.serviceEndpointPoll(handle);
        if (poll < 0) {
            _ = ctx.serviceEndpointUnregister(handle);
            return poll;
        }
        if (poll > 0) {
            const rc = handleRequest(ctx, handle, &state);
            if (rc < 0) {
                _ = ctx.serviceEndpointUnregister(handle);
                return rc;
            }
        }
        ctx.sleepTicks(1);
    }

    _ = ctx.serviceEndpointUnregister(handle);
    ctx.println("TIMESVC stopped cleanly");
    return 0;
}

fn handleRequest(ctx: *const r4os.r4sys.Context, handle: u32, state: *TimeServiceState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var payload: [r4os.abi.service_api_max_payload]u8 = undefined;
    const got = ctx.serviceEndpointRecv(handle, &header, payload[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    const payload_len: usize = @intCast(got);
    return switch (header.op) {
        r4os.abi.time_service_op_status => replyStatus(ctx, handle, header.request_id, state),
        r4os.abi.time_service_op_set_config => replySetConfig(ctx, handle, header.request_id, state, payload[0..payload_len]),
        r4os.abi.time_service_op_reload => {
            state.reloads +%= 1;
            loadConfig(ctx, state, true);
            return replyStatus(ctx, handle, header.request_id, state);
        },
        else => {
            state.bad_ops +%= 1;
            copyFixed(state.last_error[0..], "bad-op");
            return ctx.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
}

fn replyStatus(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *TimeServiceState) i32 {
    state.status_requests +%= 1;
    const status = makeStatus(ctx, state);
    const bytes: [*]const u8 = @ptrCast(&status);
    return ctx.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.TimeServiceStatus)]);
}

fn replySetConfig(ctx: *const r4os.r4sys.Context, handle: u32, request_id: u32, state: *TimeServiceState, payload: []const u8) i32 {
    var request: r4os.abi.TimeServiceConfig = .{};
    if (!parseConfigRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-config");
        return ctx.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_invalid, "");
    }
    const rc = applyConfigRequest(ctx, state, &request);
    if (rc != r4os.abi.service_api_result_ok) {
        return ctx.serviceEndpointReply(handle, request_id, rc, "");
    }
    return replyStatus(ctx, handle, request_id, state);
}

fn loadConfig(ctx: *const r4os.r4sys.Context, state: *TimeServiceState, bump: bool) void {
    const old_index = state.config.selectedIndex();
    const old_loaded = state.config_loaded;
    const old_valid = state.config_valid;
    const old_default = state.default_utc;
    const old_clock_format = state.config.selectedClockFormat();

    var buffer: [768]u8 = undefined;
    const len = ctx.fileRead(r4std.settings.paths.time, buffer[0..]);
    var next = r4std.time.Config{};
    if (len > 0 and next.loadFromBytes(buffer[0..@intCast(len)])) {
        state.config = next;
        state.config_loaded = true;
        state.config_valid = true;
        state.default_utc = false;
        copyFixed(state.last_error[0..], "ready");
    } else if (len > 0) {
        state.config = .{};
        state.config_loaded = true;
        state.config_valid = false;
        state.default_utc = true;
        copyFixed(state.last_error[0..], "bad-config");
    } else {
        state.config = .{};
        state.config_loaded = false;
        state.config_valid = true;
        state.default_utc = true;
        copyFixed(state.last_error[0..], "default-utc");
    }

    if (bump and (old_index != state.config.selectedIndex() or old_clock_format != state.config.selectedClockFormat() or old_loaded != state.config_loaded or old_valid != state.config_valid or old_default != state.default_utc)) {
        bumpRevision(state);
    }
}

fn applyConfigRequest(ctx: *const r4os.r4sys.Context, state: *TimeServiceState, request: *const r4os.abi.TimeServiceConfig) i32 {
    var next = if (state.config_valid) state.config else r4std.time.Config{};
    const flags = request.flags;
    const legacy_timezone_request = flags == 0;
    var save_config = false;

    if (legacy_timezone_request or (flags & (r4os.abi.time_service_config_flag_timezone_index | r4os.abi.time_service_config_flag_timezone_id)) != 0) {
        const index = requestIndex(request, legacy_timezone_request) orelse {
            copyFixed(state.last_error[0..], "bad-zone");
            return r4os.abi.service_api_result_invalid;
        };
        if (index >= r4std.time.zoneCount()) {
            copyFixed(state.last_error[0..], "bad-zone");
            return r4os.abi.service_api_result_invalid;
        }
        next.setIndex(index);
        save_config = true;
    }

    if ((flags & r4os.abi.time_service_config_flag_clock_format) != 0) {
        if (!validClockFormat(request.clock_format)) {
            copyFixed(state.last_error[0..], "bad-format");
            return r4os.abi.service_api_result_invalid;
        }
        next.setClockFormat(request.clock_format);
        save_config = true;
    }

    if ((flags & r4os.abi.time_service_config_flag_date) != 0) {
        if (!r4std.date.validDateValue(request.date_year, request.date_month, request.date_day)) {
            copyFixed(state.last_error[0..], "bad-date");
            return r4os.abi.service_api_result_invalid;
        }
    }

    if (save_config) {
        const rc = saveConfig(ctx, state, next);
        if (rc != r4os.abi.service_api_result_ok) return rc;
    }

    if ((flags & r4os.abi.time_service_config_flag_date) != 0) {
        const rc = setLocalDate(ctx, next, request.date_year, request.date_month, request.date_day);
        if (rc != r4os.abi.service_api_result_ok) {
            copyFixed(state.last_error[0..], "date-write");
            return rc;
        }
        state.config_writes +%= 1;
        copyFixed(state.last_error[0..], "saved");
        bumpRevision(state);
    }

    return r4os.abi.service_api_result_ok;
}

fn saveConfig(ctx: *const r4os.r4sys.Context, state: *TimeServiceState, next: r4std.time.Config) i32 {
    if (next.selectedIndex() >= r4std.time.zoneCount()) {
        copyFixed(state.last_error[0..], "bad-zone");
        return r4os.abi.service_api_result_invalid;
    }

    r4std.settings.ensureSystemDirs(ctx);
    var buffer: [384]u8 = .{0} ** 384;
    const bytes = next.writeToForState(buffer[0..], ctx.timeState());
    if (bytes.len == 0 or ctx.fileWrite(r4std.settings.paths.time, bytes) <= 0) {
        copyFixed(state.last_error[0..], "write-failed");
        return r4os.abi.service_api_result_config_io;
    }

    state.config = next;
    state.config_loaded = true;
    state.config_valid = true;
    state.default_utc = false;
    state.config_writes +%= 1;
    copyFixed(state.last_error[0..], "saved");
    bumpRevision(state);
    return r4os.abi.service_api_result_ok;
}

fn makeStatus(ctx: *const r4os.r4sys.Context, state: *const TimeServiceState) r4os.abi.TimeServiceStatus {
    const source = ctx.timeState();
    const index = state.config.selectedIndex();
    const zone = state.config.zone();
    const offset = r4std.time.offsetAtState(index, source);
    const local_seconds = r4std.time.secondsInZone(source.seconds_since_midnight, offset);
    const local = r4std.time.splitTime(local_seconds);
    const fallback_local_dt = r4std.date.DateTime{
        .date = .{ .year = source.year, .month = source.month, .day = source.day },
        .time = .{ .hour = local.hours, .minute = local.minutes, .second = local.seconds },
    };
    const local_dt = r4std.time.localDateTimeAtState(index, source) orelse fallback_local_dt;
    const clock_format = state.config.selectedClockFormat();
    var flags: u32 = 0;
    if (state.config_loaded) flags |= r4os.abi.time_service_flag_config_loaded;
    if (state.config_valid) flags |= r4os.abi.time_service_flag_config_valid;
    if (state.default_utc) flags |= r4os.abi.time_service_flag_default_utc;
    if (offset != zone.standard_offset_minutes) flags |= r4os.abi.time_service_flag_dst_active;
    if (clock_format == r4os.abi.clock_format_12h) flags |= r4os.abi.time_service_flag_clock_12h;

    var out = r4os.abi.TimeServiceStatus{
        .flags = flags,
        .revision = state.revision,
        .timezone_index = @intCast(index),
        .zone_count = @intCast(r4std.time.zoneCount()),
        .offset_minutes = offset,
        .standard_offset_minutes = zone.standard_offset_minutes,
        .daylight_offset_minutes = zone.daylight_offset_minutes,
        .utc_seconds_since_midnight = source.seconds_since_midnight,
        .local_seconds_since_midnight = local_seconds,
        .local_hour = local.hours,
        .local_minute = local.minutes,
        .local_second = local.seconds,
        .clock_format = @intCast(clock_format),
        .local_year = local_dt.date.year,
        .local_month = local_dt.date.month,
        .local_day = local_dt.date.day,
        .local_weekday = r4std.date.weekdayNumber(local_dt.date.year, local_dt.date.month, local_dt.date.day),
        .source_time = source,
        .requests = state.requests,
        .status_requests = state.status_requests,
        .config_writes = state.config_writes,
        .reloads = state.reloads,
        .bad_ops = state.bad_ops,
        .self_tests = state.self_tests,
    };
    _ = r4std.time.copyZoneId(out.timezone_id[0..], index);
    _ = r4std.time.copyZoneLabelForState(out.zone_label[0..], index, source);
    copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
}

fn parseConfigRequest(payload: []const u8, out: *r4os.abi.TimeServiceConfig) bool {
    if (payload.len < @sizeOf(r4os.abi.TimeServiceConfig)) return false;
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..@sizeOf(r4os.abi.TimeServiceConfig)], payload[0..@sizeOf(r4os.abi.TimeServiceConfig)]);
    return out.magic == r4os.abi.time_service_config_magic and out.version == r4os.abi.time_service_config_version;
}

fn requestIndex(request: *const r4os.abi.TimeServiceConfig, legacy: bool) ?usize {
    if (legacy or (request.flags & r4os.abi.time_service_config_flag_timezone_index) != 0) {
        if (request.timezone_index < @as(u32, @intCast(r4std.time.zoneCount()))) return @intCast(request.timezone_index);
    }
    if ((request.flags & r4os.abi.time_service_config_flag_timezone_id) == 0 and !legacy) return null;
    const id = spanZ(request.timezone_id[0..]);
    if (id.len != 0) return r4std.time.indexForId(id);
    return null;
}

fn validClockFormat(clock_format: u32) bool {
    return clock_format == r4os.abi.clock_format_24h or clock_format == r4os.abi.clock_format_12h;
}

fn setLocalDate(ctx: *const r4os.r4sys.Context, config: r4std.time.Config, year: u16, month: u8, day: u8) i32 {
    if (!ctx.hasFn("time_set_state")) return r4os.abi.service_api_result_invalid;
    const source = ctx.timeState();
    const current_local = r4std.time.localDateTimeForConfig(config, source) orelse return r4os.abi.service_api_result_invalid;
    const desired_local = r4std.date.DateTime{
        .date = .{ .year = year, .month = month, .day = day },
        .time = current_local.time,
    };
    const local_state = r4std.date.toTimeState(desired_local) orelse return r4os.abi.service_api_result_invalid;
    const offset = r4std.time.offsetAtState(config.selectedIndex(), local_state);
    const shifted_utc = r4std.date.shiftMinutes(desired_local, -@as(i32, offset)) orelse return r4os.abi.service_api_result_invalid;
    var utc_state = r4std.date.toTimeState(shifted_utc.value) orelse return r4os.abi.service_api_result_invalid;
    const roundtrip = r4std.time.localDateTimeAtState(config.selectedIndex(), utc_state) orelse return r4os.abi.service_api_result_invalid;
    if (r4std.date.compareDateTime(roundtrip, desired_local) != 0) return r4os.abi.service_api_result_invalid;
    return if (ctx.timeSetState(&utc_state) == 0) r4os.abi.service_api_result_ok else r4os.abi.service_api_result_config_io;
}

fn runPing(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("TIMESVC ping");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(ctx, &handle)) {
        ctx.println("TIMESVC ping failed");
        return 1;
    }
    defer _ = ctx.serviceClose(handle);

    var status: r4os.abi.TimeServiceStatus = .{};
    if (callStatus(ctx, handle, &status) != r4os.abi.service_api_result_ok or status.zone_count != @as(u32, @intCast(r4std.time.zoneCount()))) {
        ctx.println("TIMESVC ping failed");
        return 1;
    }
    ctx.println("TIMESVC ping: OK");
    return 0;
}

fn runSelfTest(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("TIMESVC selftest");
    if (!ctx.hasFn("service_start")) return fail(ctx, "manager-api");
    if (!ctx.hasFn("service_call")) return fail(ctx, "service-api");

    var handle: u32 = 0;
    if (!ensureRunningAndOpen(ctx, &handle)) return fail(ctx, "open");
    defer _ = ctx.serviceClose(handle);

    var original_status: r4os.abi.TimeServiceStatus = .{};
    if (callStatus(ctx, handle, &original_status) != r4os.abi.service_api_result_ok) return fail(ctx, "original-status");

    var original: [768]u8 = undefined;
    const original_len_raw = ctx.fileRead(r4std.settings.paths.time, original[0..]);
    const had_original = original_len_raw > 0;
    const original_len: usize = if (had_original) @intCast(original_len_raw) else 0;
    defer {
        var restored_date_status: r4os.abi.TimeServiceStatus = .{};
        _ = callSetDate(ctx, handle, original_status.local_year, original_status.local_month, original_status.local_day, &restored_date_status);
        if (had_original) {
            _ = ctx.fileWrite(r4std.settings.paths.time, original[0..original_len]);
        } else {
            _ = ctx.fileDelete(r4std.settings.paths.time);
        }
        var ignored: r4os.abi.TimeServiceStatus = .{};
        _ = callReload(ctx, handle, &ignored);
    }

    _ = ctx.fileDelete(r4std.settings.paths.time);
    var status: r4os.abi.TimeServiceStatus = .{};
    if (callReload(ctx, handle, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "missing-reload");
    if ((status.flags & r4os.abi.time_service_flag_config_loaded) != 0) return fail(ctx, "missing-loaded");
    if ((status.flags & r4os.abi.time_service_flag_default_utc) == 0 or status.timezone_index != @as(u32, @intCast(r4std.time.utc_index))) return fail(ctx, "missing-default");

    r4std.settings.ensureSystemDirs(ctx);
    const bad_config =
        \\# R4OS settings
        \\R4S_FORMAT=1
        \\SCHEMA=TIME
        \\TIMEZONE=No/SuchZone
    ;
    if (ctx.fileWrite(r4std.settings.paths.time, bad_config) <= 0) return fail(ctx, "bad-write");
    if (callReload(ctx, handle, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "bad-reload");
    if ((status.flags & r4os.abi.time_service_flag_config_valid) != 0) return fail(ctx, "bad-valid");
    if ((status.flags & r4os.abi.time_service_flag_default_utc) == 0) return fail(ctx, "bad-default");

    const berlin = r4std.time.indexForId("Europe/Berlin") orelse return fail(ctx, "berlin-index");
    const may: r4os.abi.TimeState = .{ .year = 2026, .month = 5, .day = 14 };
    const january: r4os.abi.TimeState = .{ .year = 2026, .month = 1, .day = 15 };
    if (r4std.time.offsetAtState(berlin, may) != 120) return fail(ctx, "berlin-summer");
    if (r4std.time.offsetAtState(berlin, january) != 60) return fail(ctx, "berlin-winter");

    if (callSetTimezone(ctx, handle, berlin, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "set-berlin");
    if (status.timezone_index != @as(u32, @intCast(berlin))) return fail(ctx, "set-status");
    var file_buf: [384]u8 = undefined;
    const file_len = ctx.fileRead(r4std.settings.paths.time, file_buf[0..]);
    if (file_len <= 0 or !contains(file_buf[0..@intCast(file_len)], "TIMEZONE=Europe/Berlin")) return fail(ctx, "set-file");

    if (callSetClockFormat(ctx, handle, r4os.abi.clock_format_12h, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "set-12h");
    if (@as(u32, status.clock_format) != r4os.abi.clock_format_12h or (status.flags & r4os.abi.time_service_flag_clock_12h) == 0) return fail(ctx, "status-12h");
    const format_len = ctx.fileRead(r4std.settings.paths.time, file_buf[0..]);
    if (format_len <= 0 or !contains(file_buf[0..@intCast(format_len)], "CLOCK_FORMAT=12H")) return fail(ctx, "format-file");
    if (callSetClockFormat(ctx, handle, r4os.abi.clock_format_24h, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "set-24h");
    if (@as(u32, status.clock_format) != r4os.abi.clock_format_24h) return fail(ctx, "status-24h");

    if (callSetDate(ctx, handle, 2026, 5, 14, &status) != r4os.abi.service_api_result_ok) return fail(ctx, "set-date");
    if (status.local_year != 2026 or status.local_month != 5 or status.local_day != 14) return fail(ctx, "date-status");
    if (callSetDate(ctx, handle, 2026, 2, 29, &status) == r4os.abi.service_api_result_ok) return fail(ctx, "bad-date-accepted");

    const near_midnight: r4os.abi.TimeState = .{
        .valid = 1,
        .year = 2026,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 30,
        .second = 0,
        .seconds_since_midnight = 30 * 60,
    };
    const utc_minus_12 = r4std.time.localDateTimeAtState(0, near_midnight) orelse return fail(ctx, "utc-12-local");
    const utc_plus_14 = r4std.time.localDateTimeAtState(37, near_midnight) orelse return fail(ctx, "utc-14-local");
    if (utc_minus_12.date.year != 2025 or utc_minus_12.date.month != 12 or utc_minus_12.date.day != 31) return fail(ctx, "utc-12-date");
    if (utc_plus_14.date.year != 2026 or utc_plus_14.date.month != 1 or utc_plus_14.date.day != 1 or utc_plus_14.time.hour != 14) return fail(ctx, "utc-14-date");

    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [8]u8 = .{0} ** 8;
    const bad_op = ctx.serviceCall(handle, 999, "", &header, response[0..], 120);
    if (bad_op < 0 or header.status != r4os.abi.service_api_result_bad_op) return fail(ctx, "bad-op");

    ctx.println("TIMESVC selftest: OK");
    return 0;
}

fn ensureRunningAndOpen(ctx: *const r4os.r4sys.Context, out_handle: *u32) bool {
    var info: r4os.abi.ServiceInfo = .{};
    const status = ctx.serviceStatus(service_name, &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = ctx.serviceStart(service_name, &info);
        if (start != r4os.abi.service_api_result_ok and start != r4os.abi.service_api_result_running) return false;
    }
    return waitOpen(ctx, out_handle, 160);
}

fn waitOpen(ctx: *const r4os.r4sys.Context, out_handle: *u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var info: r4os.abi.ServiceInfo = .{};
        const rc = ctx.serviceOpen(service_name, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            out_handle.* = info.handle;
            return true;
        }
        ctx.sleepTicks(1);
    }
    return false;
}

fn callStatus(ctx: *const r4os.r4sys.Context, handle: u32, out: *r4os.abi.TimeServiceStatus) i32 {
    return callStatusOp(ctx, handle, r4os.abi.time_service_op_status, "", out);
}

fn callReload(ctx: *const r4os.r4sys.Context, handle: u32, out: *r4os.abi.TimeServiceStatus) i32 {
    return callStatusOp(ctx, handle, r4os.abi.time_service_op_reload, "", out);
}

fn callSetTimezone(ctx: *const r4os.r4sys.Context, handle: u32, index: usize, out: *r4os.abi.TimeServiceStatus) i32 {
    var request = r4os.abi.TimeServiceConfig{
        .timezone_index = @intCast(index),
        .flags = r4os.abi.time_service_config_flag_timezone_index,
    };
    const bytes: [*]const u8 = @ptrCast(&request);
    return callStatusOp(ctx, handle, r4os.abi.time_service_op_set_config, bytes[0..@sizeOf(r4os.abi.TimeServiceConfig)], out);
}

fn callSetClockFormat(ctx: *const r4os.r4sys.Context, handle: u32, clock_format: u32, out: *r4os.abi.TimeServiceStatus) i32 {
    var request = r4os.abi.TimeServiceConfig{
        .clock_format = clock_format,
        .flags = r4os.abi.time_service_config_flag_clock_format,
    };
    const bytes: [*]const u8 = @ptrCast(&request);
    return callStatusOp(ctx, handle, r4os.abi.time_service_op_set_config, bytes[0..@sizeOf(r4os.abi.TimeServiceConfig)], out);
}

fn callSetDate(ctx: *const r4os.r4sys.Context, handle: u32, year: u16, month: u8, day: u8, out: *r4os.abi.TimeServiceStatus) i32 {
    var request = r4os.abi.TimeServiceConfig{
        .date_year = year,
        .date_month = month,
        .date_day = day,
        .flags = r4os.abi.time_service_config_flag_date,
    };
    const bytes: [*]const u8 = @ptrCast(&request);
    return callStatusOp(ctx, handle, r4os.abi.time_service_op_set_config, bytes[0..@sizeOf(r4os.abi.TimeServiceConfig)], out);
}

fn callStatusOp(ctx: *const r4os.r4sys.Context, handle: u32, op: u16, payload: []const u8, out: *r4os.abi.TimeServiceStatus) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [r4os.abi.service_api_max_payload]u8 = undefined;
    const got = ctx.serviceCall(handle, op, payload, &header, response[0..], 120);
    if (got < 0) return got;
    if (header.status != r4os.abi.service_api_result_ok) return header.status;
    if (got < @as(i32, @intCast(@sizeOf(r4os.abi.TimeServiceStatus)))) return r4os.abi.service_api_result_buffer_too_small;
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..@sizeOf(r4os.abi.TimeServiceStatus)], response[0..@sizeOf(r4os.abi.TimeServiceStatus)]);
    if (out.magic != r4os.abi.time_service_status_magic or out.version != r4os.abi.time_service_status_version) return r4os.abi.service_api_result_invalid;
    return r4os.abi.service_api_result_ok;
}

fn bumpRevision(state: *TimeServiceState) void {
    state.revision +%= 1;
    if (state.revision == 0) state.revision = 1;
}

fn fail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("TIMESVC selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and haystack[i + j] == needle[j]) : (j += 1) {}
        if (j == needle.len) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

fn copyFixed(out: []u8, value: []const u8) void {
    if (out.len == 0) return;
    @memset(out, 0);
    const count = @min(value.len, out.len - 1);
    if (count > 0) @memcpy(out[0..count], value[0..count]);
    out[count] = 0;
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}
