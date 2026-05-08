# zigright
A Static Analysis Tool for Zig

## Installation
First, install Zig 0.16.0 from [the website](https://ziglang.org/download/). Then, run `zig test src/memory_operations.zig` and `zig test src/test_cfg.zig`.

Those files both demonstrate how to use our tool. Unfortunately, it requires constructing a CFG by hand, which is no easy task. We have included helper functions for you, but it is still quite tedious. Note that each CFG node is allowed at most one allocation/deallocation/function call operation, so structure your code accordingly. We also require that all functions have a single return statement, of the form `return var;`, such that we can track the allocation state of `var`. In theory, this shouldn't be necessary, but this is a very basic implementation. We couldn't get our CFG generator working (not for lack of trying!) but here is some proof that our core idea works.

Logo adapted from [ziglang](https://codeberg.org/ziglang/logo), licensed under the Attribution-ShareAlike 4.0 International [(CC BY-SA 4.0)](https://creativecommons.org/licenses/by-sa/4.0/).
