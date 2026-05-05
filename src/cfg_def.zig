const CFGNode = struct {
    nodes_in: []*CFGNode,
    nodes_out: []*CFGNode,
    type: enum {
        Normal,
        // One per function
        Return,
        // One per function
        Start,
    },
    // The token is the "canonical" token for a given variable -- the declaration, for example.
    // If a token doesn't have an entry, it is implicitly Uninit.
    sources_out: std.AutoHashMap(std.zig.Ast.TokenIndex, Set(SourceState)),
    sinks_out: std.AutoHashMap(std.zig.Ast.TokenIndex, Set(SinkState)),
    ast_nodes: []std.zig.Ast.Node.Index,
};
const std = @import("std");
