// The first reference to a token within a scope is the canonical one.
// Often, this is the variable definition or function prototype.
pub const CanonicalToken = std.zig.Ast.TokenIndex;

pub fn Set(comptime T: type) type {
    return std.AutoHashMap(T, void);
}

pub const SourceState = union(enum) {
    Uninit: void,
    Alloc: CanonicalToken,
    Maybe: CanonicalToken,
    FnInput: void,
};

pub const SinkState = union(enum) {
    Uninit: void,
    Dealloc: CanonicalToken,
    Maybe: CanonicalToken,
};

pub const MemoryOperation = union(enum) {
    Allocation: struct {
        allocator: CanonicalToken,
        result: CanonicalToken,
    },
    FunctionCall: struct {
        arguments: []CanonicalToken,
        result: ?CanonicalToken,
    },
    Deallocation: struct {
        allocator: CanonicalToken,
        variable: CanonicalToken,
    },
    Deinit: struct {
        variable: CanonicalToken,
    },
    DeinitExplicit: struct {
        allocator: CanonicalToken,
        variable: CanonicalToken,
    },
};

pub const CFGNode = struct {
    nodes_in: []*CFGNode,
    nodes_out: []*CFGNode,
    kind: enum {
        Normal,
        // One per function
        Return,
        // One per function
        Start,
    },
    // The token is the "canonical" token for a given variable -- the declaration, for example.
    // If a token doesn't have an entry, it is implicitly Uninit.
    sources_out: std.AutoHashMap(CanonicalToken, Set(SourceState)),
    sinks_out: std.AutoHashMap(CanonicalToken, Set(SinkState)),
    ast_nodes: []std.zig.Ast.Node.Index,
    // At most one memory operation per node.
    mem_op: ?MemoryOperation,
};
const std = @import("std");
