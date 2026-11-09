//! A string in every binary that contains the dev agent (agent.zig), and
//! in no other: `package_tool check-no-agent` refuses to package a binary
//! that has it. Only agent.zig (development builds) and package_tool
//! import this file.

pub const marker = "oriel-dev-agent:7d3f91c2-do-not-ship";
