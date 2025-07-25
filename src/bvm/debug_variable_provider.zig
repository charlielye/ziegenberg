const std = @import("std");

/// Debug variable information for DAP
pub const DebugVariable = struct {
    name: []const u8,
    value: []const u8,
    type: ?[]const u8 = null,
    variablesReference: u32 = 0,
    namedVariables: ?u32 = null,
    indexedVariables: ?u32 = null,
};

/// Debug scope information for DAP
pub const DebugScope = struct {
    name: []const u8,
    presentationHint: ?[]const u8 = null,
    variablesReference: u32,
    namedVariables: ?u32 = null,
    indexedVariables: ?u32 = null,
    expensive: bool = false,
};

/// Interface for providing debug variables to the DAP
pub const DebugVariableProvider = struct {
    // Context pointer - the actual implementation
    context: *anyopaque,
    
    // Function pointers for the interface
    getScopesFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, frame_id: u32) anyerror![]DebugScope,
    getVariablesFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, variables_reference: u32) anyerror![]DebugVariable,
    
    /// Get the scopes available for a given stack frame
    pub fn getScopes(self: *const DebugVariableProvider, allocator: std.mem.Allocator, frame_id: u32) ![]DebugScope {
        return self.getScopesFn(self.context, allocator, frame_id);
    }
    
    /// Get the variables for a given variable reference
    pub fn getVariables(self: *const DebugVariableProvider, allocator: std.mem.Allocator, variables_reference: u32) ![]DebugVariable {
        return self.getVariablesFn(self.context, allocator, variables_reference);
    }
};