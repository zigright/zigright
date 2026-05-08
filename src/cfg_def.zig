const std = @import("std");

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

pub fn recursive_clone(
    comptime T: type,
    set_dict: *const SetDict(T),
    gpa: std.mem.Allocator,
) !SetDict(T) {
    var new = SetDict(T).init(gpa);
    var it = set_dict.iterator();
    while (it.next()) |entry| {
        try new.put(entry.key_ptr.*, try entry.value_ptr.cloneWithAllocator(gpa));
    }
    return new;
}

pub fn recursive_deinit(
    comptime T: type,
    set_dict: *SetDict(T),
) void {
    var it = set_dict.valueIterator();
    while (it.next()) |set| {
        set.deinit();
    }
    set_dict.deinit();
}

pub fn recursive_eq(
    comptime T: type,
    sd1: *const SetDict(T),
    sd2: *const SetDict(T),
) bool {
    if (sd1.count() != sd2.count()) {
        return false;
    }
    var it1 = sd1.iterator();
    while (it1.next()) |entry1| {
        const set2 = sd2.get(entry1.key_ptr.*);
        if (set2 == null or set2.?.count() != entry1.value_ptr.count()) {
            return false;
        }
        var it_set1 = entry1.value_ptr.keyIterator();
        while (it_set1.next()) |state| {
            if (!set2.?.contains(state.*)) {
                return false;
            }
        }
    }
    return true;
}

pub const SourceDict = SetDict(SourceState);
pub const SinkDict = std.AutoHashMap(CanonicalToken, Set(SinkState));

pub const CFGNode = struct {
    const Self = CFGNode;

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
    in: BlockFlow,
    out: BlockFlow,
    ast_nodes: []std.zig.Ast.Node.Index,
    // At most one memory operation per node.
    mem_op: ?MemoryOperation,
    // This should be initialized to false when creating the node,
    // and will be updated later. This is to prevent a problem with loops.
    annotations_initialized: bool,
    // This is to help us save time when doing multiple iterations of the flow algorithm.
    round_visited: u32,

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .nodes_in = undefined,
            .nodes_out = undefined,
            .in = .init(gpa),
            .out = .init(gpa),
            .annotations_initialized = false,
            .kind = .Normal,
            .mem_op = null,
            .round_visited = 0,
            .ast_nodes = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        self.in.deinit();
        self.out.deinit();
    }
};

pub const AnalyzedFn = struct {
    func: ParsedFn,
    analysis: ?BlockFlow,
};

pub const BlockFlow = struct {
    const Self = BlockFlow;

    sources: SourceDict,
    sinks: SinkDict,

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{
            .sources = .init(gpa),
            .sinks = .init(gpa),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sources.deinit();
        self.sinks.deinit();
    }
};

pub const ParsedFn = struct {
    start_node: CFGNode,
    // The tokens for the arguments in the function prototype, such
    // that I can correlate them back.
    decl_params: []CanonicalToken,
    // Similarly, the return value's token, if there is one.
    return_tok: ?CanonicalToken,
};

pub const ParsedCFG = struct {
    functions: std.AutoHashMap(CanonicalToken, AnalyzedFn),
    ast: std.zig.Ast,
};
