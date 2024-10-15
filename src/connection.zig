const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("lib.zig");
const ConnectionConfig = lib.ConnectionConfig;
const Statement = @import("statement.zig").Statement;
const r = @import("result.zig");

const c = lib.c;
const assert = std.debug.assert;

//Single DB connection
pub const Connection = struct {
    const Self = @This();

    // C type Connection struct
    mysql: *c.MYSQL,

    allocator: Allocator,

    dirty: bool,

    next: ?*Self,

    idle: bool,

    pooled: bool,

    // Creates a connection
    pub fn newConnection(allocator: Allocator, config: ConnectionConfig) !*Self {
        const newSelf = try allocator.create(Self);
        newSelf.allocator = allocator;
        newSelf.dirty = false;
        newSelf.next = null;
        newSelf.idle = true;
        newSelf.mysql = try lib.initConnection(config);

        return newSelf;
    }

    // Execute query. Returns result in json format
    pub fn executeQuery(self: *Self, query: [*c]const u8, parameters: anytype) !*r.Result {
        self.dirty = true;
        return try lib.executeQuery(self.allocator, self.mysql, query, parameters);
    }

    pub fn close(self: *Self) void {
        if (self.pooled) {
            std.debug.panic("Attempt to close a pooled connection\n", .{});
        }
        c.mysql_close(self.mysql);
        self.allocator.destroy(self);
    }

    // Create prepared statement
    pub fn prepare(self: *Self, query: [*c]const u8) !*Statement {
        //if(self.dirty) return error.connectionDirty;
        return try Statement.init(self.allocator, self.mysql, query);
    }

    /// Returns the number of rows changed, deleted, or
    /// inserted by the last statement if it was an UPDATE, DELETE, or INSERT. For SELECT statements,
    /// it returns number of rows fetched.
    pub fn getAffectedRows(self: *Self) u64 {
        return c.mysql_affected_rows(self.mysql);
    }

    /// Sets autocommit mode on if mode is true, off if mode is false.
    /// returns true for success
    pub fn setAutoCommitMode(self: *Self, mode: bool) bool {
        const cmode: u8 = @intFromBool(mode);
        return c.mysql_autocommit(self.mysql, cmode) != 0;
    }

    /// Changes the user and causes the database specified by db to become the default (current) database
    /// on the connection specified.
    /// Zero for success. Nonzero if an error occurred.
    pub fn changeUser(self: *Self, user: lib.User) bool {
        if (c.mysql_change_user(self.mysql, user.username, user.password, user.database orelse null) == 0) {
            return true;
        }

        return false;
    }

    /// Returns the default character set name for the current connection.
    pub fn getCharacterSetName(self: *Self) [*c]const u8 {
        return c.mysql_character_set_name(self.mysql);
    }

    /// Commits the current transaction.
    pub fn commit(self: *Self) bool {
        return !c.mysql_commit(self.mysql);
    }

    /// Returns the error code for the most recently
    /// invoked API function that can succeed or fail.
    pub fn errorCode(self: *Self) u16 {
        return c.mysql_errno(self.mysql);
    }

    /// Returns a null-terminated string containing
    /// the error message for the most recently invoked API function that failed.
    pub fn errorMessage(self: *Self) [*c]const u8 {
        return c.mysql_error(self.mysql);
    }

    /// Returns the number of columns for the most recent query on the connection.
    pub fn fieldCount(self: *Self) u16 {
        return c.mysql_field_count(self.mysql);
    }

    /// Returns the value generated for an AUTO_INCREMENT column by the previous INSERT or UPDATE
    /// statement.
    pub fn lastInsertedId(self: *Self) u64 {
        return c.mysql_insert_id(self.mysql);
    }

    pub fn ping(self: *Self) bool {
        if (c.mysql_ping(self.mysql) == 0) {
            return true;
        }

        return false;
    }

    /// Resets the connection to clear the session state.
    pub fn reset(self: *Self) bool {
        if (c.mysql_reset_connection(self.mysql) == 0) {
            return true;
        }
        return false;
    }

    /// Rolls back the current transaction.
    pub fn rollBack(self: *Self) bool {
        if (c.mysql_rollback(self.mysql) != 0) {
            return false;
        }
        return true;
    }

    /// Causes the database specified by db to become the default (current) database on the connection
    pub fn selectDB(self: *Self, db: [*c]const u8) bool {
        if (c.mysql_select_db(self.mysql, db) == 0) {
            return true;
        }
        return false;
    }

    /// Returns a null-terminated string containing the SQLSTATE error code for the most recently executed
    /// SQL statement. The error code consists of five characters. '00000' means “no error.”
    pub fn sqlState(self: *Self) [*c]const u8 {
        return c.mysql_sqlstate(self.mysql);
    }
};

test "mem leak" {
    //const config: ConnectionConfig = .{ .databaseName = "events", .host = "localhost", .password = "1234Victor", .username = "vic" };
    //const conn = try Connection.newConnection(std.testing.allocator, config);
    //const res = try conn.executeQuery("select * from users where name = ?", .{"karanja"});
    //defer std.testing.allocator.free(res);
    //defer conn.close();
}

test "connect" {
    const p = try Connection.newConnection(std.testing.allocator, lib.testConfig);
    p.close();
}

const dbname = "testdb";
test "create db" {
    const p = try Connection.newConnection(std.testing.allocator, lib.testConfig);
    const res = p.executeQuery("CREATE DATABASE IF NOT EXISTS testdb", .{});
    if (res) |value| {
        std.debug.print("result: {} \n", .{value});
        value.deinit();
    } else |err| {
        std.debug.print("err: {} \n", .{err});
        std.debug.print("err: {s} \n", .{p.errorMessage()});
    }
    p.close();
}

test "use db" {
    const p = try Connection.newConnection(std.testing.allocator, lib.testConfig);
    const selected = p.selectDB(dbname);
    assert(selected);
    const res = p.executeQuery("SELECT DATABASE()", .{});
    if (res) |value| {
        const resName = value.firstSet.?.firstRow.?.columns.?.get(0).?;
        assert(std.mem.eql(u8, resName, dbname));
        value.deinit();
    } else |err| {
        std.debug.print("err: {} \n", .{err});
        std.debug.print("err: {s} \n", .{p.errorMessage()});
        assert(false);
    }
    p.close();
}

test "drop table if exists" {
    const p = try Connection.newConnection(std.testing.allocator, lib.testConfig);
    _ = p.selectDB(dbname);
    const query =
        \\DROP TABLE IF EXISTS test_user_table;
    ;
    const res = p.executeQuery(query, .{});
    if (res) |value| {
        std.debug.print("result: {} \n", .{value});
        value.deinit();
    } else |err| {
        std.debug.print("err: {} \n", .{err});
        std.debug.print("err: {s} \n", .{p.errorMessage()});
        assert(false);
    }
    p.close();
}
test "create table" {
    const p = try Connection.newConnection(std.testing.allocator, lib.testConfig);
    _ = p.selectDB(dbname);
    const query =
        \\CREATE TABLE IF NOT EXISTS test_user_table (
        \\    id INT AUTO_INCREMENT PRIMARY KEY,
        \\    name VARCHAR(255) NOT NULL,
        \\    lastname VARCHAR(255),
        \\    isActive BOOLEAN NOT NULL DEFAULT TRUE,
        \\    created TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\);
    ;
    const res = p.executeQuery(query, .{});
    if (res) |value| {
        std.debug.print("result: {} \n", .{value});
        value.deinit();
    } else |err| {
        std.debug.print("err: {} \n", .{err});
        std.debug.print("err: {s} \n", .{p.errorMessage()});
        assert(false);
    }
    p.close();
}

test "insert into table" {
    const p = try Connection.newConnection(std.testing.allocator, lib.testConfig);
    _ = p.selectDB(dbname);
    const query =
        \\INSERT INTO test_user_table (name, lastname, isActive) 
        \\VALUES ('John Doe', NULL, TRUE);
    ;
    const res = p.executeQuery(query, .{});
    if (res) |value| {
        std.debug.print("Inserted rows: {d} \n", .{value.affectedRows});
        assert(value.affectedRows == 1);
        value.deinit();
    } else |err| {
        std.debug.print("err: {} \n", .{err});
        std.debug.print("err: {s} \n", .{p.errorMessage()});
        assert(false);
    }
    p.close();
}

test "select from table" {
    const p = try Connection.newConnection(std.testing.allocator, lib.testConfig);
    _ = p.selectDB(dbname);
    const query =
        \\select name, lastname, isActive from test_user_table;
    ;
    const res = p.executeQuery(query, .{});
    if (res) |value| {
        std.debug.print("result: {} \n", .{value});
        const name = value.firstSet.?.firstRow.?.columns.?.get(0).?;
        const lastname = value.firstSet.?.firstRow.?.columns.?.get(1);
        const isactive = value.firstSet.?.firstRow.?.columns.?.get(2).?;
        assert(std.mem.eql(u8, name, "John Doe"));
        assert(lastname == null);
        assert(std.mem.eql(u8, isactive, "1"));
        value.deinit();
    } else |err| {
        std.debug.print("err: {} \n", .{err});
        std.debug.print("err: {s} \n", .{p.errorMessage()});
        assert(false);
    }
    p.close();
}
