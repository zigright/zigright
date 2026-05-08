fn foo() void {
    const n = undefined;
    var i = 1;
    var sum = 0;
    while (i <= n) {
        sum = 0;
        var j = 1;
        while (j <= i) {
            sum = sum + j;
            j = j + 1;
        }
        i = i + 1;
    }
    if (i < n) {
        i += 2;
    } else {
        i -= 1;
    }
    switch (i) {
        0 => {
            i += 3;
        },
        1, 2, 3 => {
            i += 4;
        },
        else => {},
    }
    if (i == 9) i += 9;
    for (i > 10) |_| i -= 1;
    for (0..10) |_| i -= 1 else i += 1;
    return;
}
