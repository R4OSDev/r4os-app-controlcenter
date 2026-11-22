const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// `zig build` erzeugt das Modul allein aus diesem Verzeichnis, ohne den Rest
/// von R4OS. Die Datei zeigt nur auf module.R4MF - Name, Klasse, Quellen,
/// Ziel, Imports und Metadaten stehen dort und nirgends sonst.
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    const desktop_wire = b.dependency("r4os_r4desk", .{ .@"contract-only" = true }).path("Contract/desktop_check_v2.zig");
    const libraries = b.lazyImport(@This(), "r4os_libraries") orelse return;
    const fonts = b.dependencyFromBuildZig(libraries, .{}).namedLazyPath("r4font_app_fonts");
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{ .zig_module_roots = &.{ desktop_wire, fonts } });
}
