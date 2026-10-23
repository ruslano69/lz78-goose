// SPDX-License-Identifier: MIT
// POSIX adapter for gswinargs: the runtime already provides UTF-8 arguments, so no FFI is needed.
// Same API as the Windows module; build_posix.py stages this file over archiver/gswinargs.goose.
namespace gswinargs;
import std;

fn count() -> i64 { return arg_count(); }
fn arg(index: i64, out: u8[>..]&) { out.append(args()[index]); }
