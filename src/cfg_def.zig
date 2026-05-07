// The first reference to a token within a scope is the canonical one.
// Often, this is the variable definition or function prototype.
pub const CanonicalToken = std.zig.Ast.TokenIndex;

pub fn Set(comptime T: type) type {
    return std.AutoHashMap(T, void);
}

pub const SourceState = union(enum) {
    Uninit,
    Alloc: CanonicalToken,
    Maybe: CanonicalToken,
    FnInput,
};

pub const SinkState = union(enum) {
    Uninit,
    Dealloc: CanonicalToken,
    Maybe: CanonicalToken,
    // When you .deinit() a function argument.
    FnInput,
};

pub const MemoryOperation = union(enum) {
    Allocation: struct {
        allocator: CanonicalToken,
        result: CanonicalToken,
    },
    FunctionCall: struct {
        function_name: CanonicalToken,
        arguments: []CanonicalToken,
        allocator_arg_indices: []u32,
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

pub fn SetDict(comptime T: type) type {
    return std.AutoHashMap(CanonicalToken, Set(T));
}
pub const SourceDict = SetDict(SourceState);
pub const SinkDict = std.AutoHashMap(CanonicalToken, Set(SinkState));

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
    sources_in: SourceDict,
    sinks_in: SinkDict,
    sources_out: SourceDict,
    sinks_out: SinkDict,
    ast_nodes: []std.zig.Ast.Node.Index,
    // At most one memory operation per node.
    mem_op: ?MemoryOperation,
    // This should be initialized to false when creating the node,
    // and will be updated later. This is to prevent a problem with loops.
    annotations_initialized: bool,
};

pub const AnalyzedFn = struct {
    func: ParsedFn,
    analysis: ?BlockFlow,
};

pub const BlockFlow = struct {
    sources: SourceDict,
    sinks: SinkDict,
};

pub const ParsedFn = struct {
    start_node: CFGNode,
    // The tokens for the arguments in the function prototype, such
    // that I can correlate them back.
    arguments: []CanonicalToken,
    // Similarly, the return value's token, if there is one.
    return_tok: ?CanonicalToken,
};

pub const ParsedCFG = struct {
    functions: std.AutoHashMap(CanonicalToken, AnalyzedFn),
    ast: std.zig.Ast,
};

const std = @import("std");
