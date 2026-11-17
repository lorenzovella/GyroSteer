// With SDL built from source on macOS, SDL's Objective-C code calls clang's runtime (for `@available` checks), which
// Rust's link line leaves out. Link it in.
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let target = std::env::var("TARGET").unwrap_or_default();
    if !target.contains("apple-darwin") || std::env::var_os("CARGO_FEATURE_STATIC_SDL").is_none() {
        return;
    }
    let output = Command::new("clang").arg("--print-resource-dir").output().expect("clang not found");
    let resource_dir = String::from_utf8(output.stdout).expect("clang printed a non-UTF-8 path");
    println!("cargo:rustc-link-search=native={}/lib/darwin", resource_dir.trim());
    println!("cargo:rustc-link-lib=static=clang_rt.osx");
}
