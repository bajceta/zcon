const std = @import("std");
const os = std.os;
pub const Bufflist = @import("bufflist.zig").BuffList;
const ArrayList = std.ArrayList;
const json = std.json;
const writeStream = json.writeStream;
const Allocator = std.mem.Allocator;
const time = std.time;
const expect = std.testing.expect;
const r = @import("result.zig");

pub const c = @cImport({
    @cInclude("mysql.h");
    @cInclude("stdlib.h");
});

pub const CustomErr = error{
    sqlErr,
    parameterErr,
    connectionBusy,
    connectionIdle,
    connectionDirty,
};

pub const Options = struct {};

pub const User = struct {
    username: [*c]const u8,
    password: [*c]const u8,

    /// Assign null if you do not want to have a default database.
    database: ?[*c]const u8,
};

pub const ConnectionConfig = struct {
    host: [*c]const u8,
    username: [*c]const u8,
    password: [*c]const u8,
    databaseName: [*c]const u8,
};

pub const testConfig = ConnectionConfig{
    .host = "172.17.0.1",
    .username = "root",
    .password = "my-secret-pw",
    .databaseName = "",
};

//Execute query, results in json
pub fn executeQuery(allocator: Allocator, mysql: *c.MYSQL, query: [*c]const u8, parameters: anytype) !*r.Result {
    if (parameters.len == 0) {
        return try fetchResults2(allocator, mysql, query);
    }

    // create statement
    const statement = try prepareStatement(mysql, query);
    defer {
        _ = c.mysql_stmt_close(@ptrCast(statement));
    }

    //fetch resulst
    if (fetchResults(allocator, statement, parameters)) |res| {
        return res;
    } else |err| {
        switch (err) {
            error.parameterErr => {
                std.debug.panic("Expected number of parameters not met", .{});
            },
            else => |e| {
                return e;
            },
        }
    }

    _ = c.mysql_stmt_close(statement);
}

//create C connection struct
pub fn initConnection(config: ConnectionConfig) CustomErr!*c.MYSQL {
    var mysql: ?*c.MYSQL = null;
    var conn: ?*c.MYSQL = null;
    mysql = c.mysql_init(null);
    if (mysql) |_| {} else {
        return CustomErr.sqlErr;
    }
    conn = c.mysql_real_connect(mysql, config.host, config.username, config.password, config.databaseName, c.MYSQL_PORT, null, c.CLIENT_MULTI_STATEMENTS);
    if (conn) |ptr| {
        return ptr;
    } else {
        const err = c.mysql_error(mysql);
        std.debug.print("Mysql Error failed to connect: {s}\n", .{err});
        return CustomErr.sqlErr;
    }
}

pub fn getColumns(metadata: *c.MYSQL_RES) CustomErr![*c]c.MYSQL_FIELD {
    var colums: ?[*c]c.MYSQL_FIELD = null;
    colums = c.mysql_fetch_fields(metadata);

    if (colums) |ptr| {
        return ptr;
    } else {
        return CustomErr.sqlErr;
    }
}

// creates C statement struct
pub fn prepareStatement(mysql: *c.MYSQL, query: [*c]const u8) !*c.MYSQL_STMT {
    var statement: ?*c.MYSQL_STMT = null;

    statement = c.mysql_stmt_init(mysql);

    if (statement) |_| {} else {
        return CustomErr.sqlErr;
    }

    const c_query = @as([*c]u8, @ptrCast(@constCast(@alignCast(query))));
    const err = c.mysql_stmt_prepare(statement, c_query, std.mem.len(c_query));

    if (err != 0) {
        return CustomErr.sqlErr;
    }

    return statement.?;
}

//Binds query parameters to statement struct
pub fn bindParametersToStatement(statement: ?*c.MYSQL_STMT, parameterList: *Bufflist, lengths: *[]c_ulong) ![*c]c.MYSQL_BIND {
    const param_count = c.mysql_stmt_param_count(statement.?);

    if (param_count != @as(c_ulong, parameterList.size)) {
        return error.parameterErr;
    }

    var p_bind: [*c]c.MYSQL_BIND = @as([*c]c.MYSQL_BIND, @ptrCast(@alignCast(c.malloc(@sizeOf(c.MYSQL_BIND) *% @as(c_ulong, parameterList.size)))));

    for (0..param_count) |i| {
        const wcd = parameterList.get(i).?;
        lengths.*[i] = @as(c_ulong, wcd.len);
        const bf = @as(?*anyopaque, @ptrCast(@as([*c]u8, @ptrCast(@constCast(@alignCast(wcd))))));

        p_bind[i].buffer_type = c.MYSQL_TYPE_STRING;
        p_bind[i].length = &(lengths.*[i]);
        p_bind[i].is_null = 0;
        p_bind[i].buffer = bf;
    }

    const statuss = c.mysql_stmt_bind_param(statement.?, p_bind);

    try std.testing.expect(statuss == false);

    if (statuss) {
        return CustomErr.sqlErr;
    }

    if (statement) |_| {} else {
        return CustomErr.sqlErr;
    }

    try executeStatement(statement.?);

    return p_bind;
}

// fill parameters to a buffer list for binding
pub fn fillParamsList(alloc: Allocator, config: anytype) !*Bufflist {
    const paramLen = config.len;

    var blistParams: *Bufflist = try Bufflist.init(alloc, paramLen);

    inline for (0..paramLen) |i| {
        const T = @TypeOf(config[i]);

        switch (T) {
            i64, i32, i16, i8, i4, bool, comptime_float, comptime_int => |_| {
                var fmtB: [100]u8 = [1]u8{0} ** 100;

                _ = try std.fmt.bufPrint(&fmtB, "{}", .{config[i]});
                const ftmpNullStripped = std.mem.sliceTo(&fmtB, 0);

                try blistParams.initAndSetBuffer(ftmpNullStripped, i);
            },

            else => {
                try blistParams.initAndSetBuffer(config[i], i);
            },
        }
    }

    return blistParams;
}

//
pub fn executeStatement(statement: *c.MYSQL_STMT) CustomErr!void {
    const err = c.mysql_stmt_execute(statement);
    if (std.testing.expect(err == 0)) |_| {} else |_| {
        return CustomErr.sqlErr;
    }
}

pub fn getColumnCount(meta: *c.MYSQL_RES) usize {
    const column_count = @as(usize, c.mysql_num_fields(meta));
    return column_count;
}

// get metadata of the results
pub fn getResultMetadata(statement: *c.MYSQL_STMT) !*c.MYSQL_RES {
    var res_meta_data: ?*c.MYSQL_RES = null;
    res_meta_data = c.mysql_stmt_result_metadata(statement);

    if (res_meta_data) |val| {
        return val;
    } else {
        return error.sqlErr;
    }
}

// bind result buffers
pub fn bindResultBuffers(allocator: Allocator, statement: *c.MYSQL_STMT, columns: [*c]c.MYSQL_FIELD, columnCount: usize, toBind: *[*c]c.MYSQL_BIND, lengths: *[]c_ulong, nulls: *[*c]bool, errors: *[*c]bool) !*Bufflist {
    toBind.* = @as([*c]c.MYSQL_BIND, @ptrCast(@alignCast(c.malloc(@sizeOf(c.MYSQL_BIND) *% @as(c_ulong, columnCount)))));
    const blist = try Bufflist.init(allocator, @as(usize, columnCount));

    for (0..columnCount) |i| {
        toBind.*[i].buffer_type = c.MYSQL_TYPE_STRING;
        const len = @as(usize, (columns.?[i]).length);
        try blist.initBuffer(i, len);
        toBind.*[i].buffer = blist.getCBuffer(i);
        toBind.*[i].buffer_length = len;
        toBind.*[i].length = &(lengths.*[i]);
        toBind.*[i].@"error" = &(errors.*[i]);
        toBind.*[i].is_null = &(nulls.*[i]);
    }

    const succ = c.mysql_stmt_bind_result(statement, @as([*c]c.MYSQL_BIND, @ptrCast(@alignCast(toBind.*))));
    if (succ != false) {
        return error.sqlErr;
    }

    return blist;
}

// get affected rows for querys that do not return results
pub fn getAffectedRows(statement: *c.MYSQL_STMT) u64 {
    const affectedRows = @as(u64, c.mysql_stmt_affected_rows(statement));
    return affectedRows;
}

// fetch for prepared statements

pub fn fetchResults(allocator: Allocator, statement: *c.MYSQL_STMT, parameters: anytype) !*r.Result {
    // parameter buffer list
    var pbuff: ?*Bufflist = null;

    // structs to bind each parameter to.
    var binded: ?[*c]c.MYSQL_BIND = null;

    // holds lengths of parameters when binding
    var lengths = try allocator.alloc(c_ulong, parameters.len);
    defer allocator.free(lengths);

    defer {
        if (binded) |ptr| {
            c.free(@as(?*anyopaque, @ptrCast(ptr)));
        }

        if (pbuff) |ptr| {
            ptr.deInit();
        }
    }

    // check if parameters are given for binding, else skip binding and only execute statement
    switch (parameters.len > 0) {
        true => {
            pbuff = try fillParamsList(allocator, parameters);

            binded = try bindParametersToStatement(statement, pbuff.?, &lengths);
        },
        else => {
            // execute statement
            try executeStatement(statement);
        },
    }

    const res = try r.Result.init(allocator);

    //problem starts here

    while (true) {
        var metadata: ?*c.MYSQL_RES = null;

        defer {
            if (metadata) |m| {
                _ = c.mysql_free_result(m);
            }
        }

        if (getResultMetadata(statement)) |val| {
            metadata = val;
        } else |_| {
            //metadata = undefined;
            std.debug.print("*********************\n", .{});
            break;
        }

        const columnCount = getColumnCount(metadata.?);

        // holds lengths of each column
        var resLengths = try allocator.alloc(c_ulong, columnCount);
        defer allocator.free(resLengths);

        // holds nullabilty of each col
        var resNulls = try allocator.alloc(bool, columnCount);
        defer allocator.free(resNulls);

        // holds errors of each col
        var resErrs = try allocator.alloc(bool, columnCount);
        defer allocator.free(resErrs);

        // ==========================================================
        const columns = try getColumns(metadata.?);
        // ============================================================

        var resBind: [*c]c.MYSQL_BIND = undefined;
        const resultBuffers = try bindResultBuffers(allocator, statement, columns, columnCount, &resBind, &resLengths, @ptrCast(&resNulls), @ptrCast(&resErrs));
        defer resultBuffers.deInit();

        const resultSet = try r.ResultSet.init(allocator);

        while (c.mysql_stmt_fetch(statement) == @as(c_int, 0)) {
            const row = try r.Row.init(allocator, columnCount);
            row.columns = try resultBuffers.clone();
            resultSet.insertRow(row);
        }

        res.insert(resultSet);

        if (c.mysql_stmt_next_result(statement) != @as(c_int, 0)) {
            break;
        }
    }

    res.affectedRows = getAffectedRows(statement);

    return res;
}

pub fn fetchResults2(allocator: Allocator, mysql: *c.MYSQL, query: [*c]const u8) !*r.Result {
    var status = c.mysql_query(mysql, query);

    if (status != @as(c_int, 0)) {
        return error.sqlErr;
    }

    const res = try r.Result.init(allocator);

    while (true) {
        const result = c.mysql_store_result(mysql);

        if (result != null) {
            const resultSet = try r.ResultSet.init(allocator);
            const numFields = c.mysql_num_fields(result);

            while (true) {
                const row = c.mysql_fetch_row(result);

                if (row != null) {
                    const rw = try r.Row.init(allocator, numFields);

                    const lengths: [*c]c_ulong = c.mysql_fetch_lengths(result);

                    rw.columns = try Bufflist.init(allocator, numFields);

                    for (0..numFields) |i| {
                        if (row[i] != null) {
                            try rw.columns.?.initAndSetBuffer(row[i][0..lengths[i]], i);
                        } else {
                            try rw.columns.?.initAndSetBuffer("", i);
                        }
                    }

                    resultSet.insertRow(rw);
                } else {
                    break;
                }
            }

            res.insert(resultSet);
            c.mysql_free_result(result);
        } else {
            if (c.mysql_field_count(mysql) == 0) {
                res.affectedRows += c.mysql_affected_rows(mysql);
            } else {
                break {
                    return error.sqlErr;
                };
            }
        }

        status = c.mysql_next_result(mysql);

        if (status != 0) {
            break;
        }
    }

    return res;
}

pub fn cStringToZigString(cString: [*]const u8, allocator: Allocator) ![]const u8 {
    var index: usize = 0;
    while (cString[index] != 0) : (index += 1) {}

    const zigString = try allocator.dupe(u8, cString[0..index]);
    return zigString;
}

test "fill " {
    const alloc = std.testing.allocator;
    const a = try fillParamsList(alloc, .{ "hello", "world" });
    try expect(a.size == 2);
    a.deInit();
}
