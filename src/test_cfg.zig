test "passthrough" {
	// One node in, check outputs are the same as inputs
	var parent: cfg_def.CFGNode = .{
		.nodes_in = [],
		.nodes_out = undefined,
		
	};
}

test "implicit uninit" {
	// Two nodes in, one without anything specified for a variable.
}

test "function call" {
	//
}

test ""

const std = @import("std");
const cfg_def = @import("cfg_def.zig");
