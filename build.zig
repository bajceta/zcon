const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zconn", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const lib = b.addStaticLibrary(.{ .name = "zconn", .root_source_file = b.path("src/root.zig"), .optimize = optimize, .target = target });

    const libs_to_link = [_][]const u8{ "mariadb", "zstd", "ssl", "crypto", "resolv", "m" };
    lib.linkLibC();
    for (libs_to_link) |l| {
        lib.linkSystemLibrary(l);
    }

    module.linkLibrary(lib);

    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("tests.zig"),
        .optimize = optimize,
        .link_libc = true,
    });

    for (libs_to_link) |l| {
        main_tests.linkSystemLibrary(l);
    }

    const run_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    const short = b.addExecutable(.{ .target = target, .name = "short", .root_source_file = b.path("src/main.zig"), .optimize = optimize });

    short.linkLibC();
    for (libs_to_link) |l| {
        short.linkSystemLibrary(l);
    }

    //short.root_module.addImport("zconn", module);
    b.installArtifact(short);

    _ = module;
}
