use sha2::{Digest, Sha256};
use std::env;
use std::fs;
use std::path::PathBuf;

fn canonical_json(document: &serde_json::Value) -> Vec<u8> {
    let mut raw = serde_json::to_vec(document).expect("serialize Core ABI manifest");
    raw.push(b'\n');
    raw
}

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let target = env::var("TARGET").expect("TARGET");
    for variable in [
        "SC_CORE_FFI_SOURCE_GIT_SHA",
        "SC_CORE_FFI_SOURCE_TREE_SHA",
        "SC_CORE_FFI_BUILD_INPUT_SHA256",
        "SC_CORE_FFI_SOURCE_CLEAN",
        "SC_CORE_FFI_PROFILE",
    ] {
        println!("cargo:rerun-if-env-changed={variable}");
    }
    // Ordinary cargo test/clippy builds remain possible, but only the canonical archive builder
    // supplies fixed Git and profile identities.  Receipt verification rejects these diagnostic
    // sentinels, so an old same-ABI archive cannot be re-labelled at a newer clean source SHA.
    let source_git_sha =
        env::var("SC_CORE_FFI_SOURCE_GIT_SHA").unwrap_or_else(|_| "unbound".to_owned());
    let source_tree_sha =
        env::var("SC_CORE_FFI_SOURCE_TREE_SHA").unwrap_or_else(|_| "unbound".to_owned());
    let build_input_sha256 =
        env::var("SC_CORE_FFI_BUILD_INPUT_SHA256").unwrap_or_else(|_| "unbound".to_owned());
    let source_clean = env::var("SC_CORE_FFI_SOURCE_CLEAN").unwrap_or_else(|_| "0".to_owned());
    let build_profile = env::var("SC_CORE_FFI_PROFILE").unwrap_or_else(|_| "diagnostic".to_owned());
    for (name, value) in [
        ("source Git SHA", source_git_sha.as_str()),
        ("source tree SHA", source_tree_sha.as_str()),
    ] {
        assert!(
            value == "unbound"
                || (value.len() == 40
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))),
            "invalid Core FFI {name}"
        );
    }
    assert!(
        build_input_sha256 == "unbound"
            || (build_input_sha256.len() == 64
                && build_input_sha256
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))),
        "invalid Core FFI build-input identity"
    );
    assert!(matches!(source_clean.as_str(), "0" | "1"));
    assert!(
        matches!(
            build_profile.as_str(),
            "ffi-release" | "dev-ffi" | "diagnostic"
        ),
        "invalid Core FFI build profile"
    );
    let variant = if env::var_os("CARGO_FEATURE_FULL").is_some() {
        "full"
    } else {
        "minimal"
    };
    let config_path = manifest_dir.join("abi/manifest-config-v1.json");
    println!("cargo:rerun-if-changed={}", config_path.display());
    let config_raw = fs::read(&config_path).expect("read Core ABI manifest config");
    let config: serde_json::Value =
        serde_json::from_slice(&config_raw).expect("parse Core ABI manifest config");
    let targets = config["targets"]
        .as_array()
        .expect("Core ABI targets array");
    let target_entry = targets
        .iter()
        .find(|entry| entry["triple"].as_str() == Some(target.as_str()))
        .unwrap_or_else(|| panic!("unsupported canonical Core ABI target: {target}"));
    let surface_name = target_entry["surface"]
        .as_str()
        .expect("Core ABI surface name");
    let surface_path = manifest_dir
        .join("abi/surfaces-v1")
        .join(format!("{surface_name}.json"));
    println!("cargo:rerun-if-changed={}", surface_path.display());
    let surface_raw = fs::read(&surface_path).expect("read canonical Core ABI surface");
    let surface: serde_json::Value =
        serde_json::from_slice(&surface_raw).expect("parse canonical Core ABI surface");
    assert_eq!(
        surface_raw,
        canonical_json(&surface),
        "Core ABI surface must be canonical JSON"
    );
    let excluded = config["variants"][variant]["excludedSymbols"]
        .as_array()
        .expect("Core ABI excluded symbol array");
    let excluded: std::collections::BTreeSet<&str> = excluded
        .iter()
        .map(|value| value.as_str().expect("Core ABI excluded symbol"))
        .collect();
    let mut symbols = surface["symbols"]
        .as_array()
        .expect("Core ABI symbols")
        .clone();
    symbols.retain(|symbol| {
        let name = symbol["name"].as_str().expect("Core ABI symbol name");
        !excluded.contains(name)
    });
    let document = serde_json::json!({
        "enums": surface["enums"].clone(),
        "schemaVersion": 1,
        "structs": surface["structs"].clone(),
        "symbols": symbols,
        "target": target,
        "typedefs": surface["typedefs"].clone(),
        "variant": variant,
    });
    let raw = canonical_json(&document);

    let digest = Sha256::digest(&raw);
    let manifest_sha256 = digest
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let identity = u64::from_be_bytes(digest[..8].try_into().expect("SHA-256 prefix"));
    assert_ne!(identity, 0, "Core ABI identity must not be zero");
    // This is deliberately a private, non-exported object marker rather than a C ABI symbol.
    // Release tooling scans the final static archive for exactly one copy and binds it to the
    // complete canonical manifest, target and feature variant.  Rendering the bytes as integers
    // keeps the marker text itself out of generated debug source strings.
    let archive_marker = format!(
        "SC_CORE_ABI_ARCHIVE_MARKER_V1|sha256={manifest_sha256}|target={target}|variant={variant}|profile={build_profile}|git={source_git_sha}|tree={source_tree_sha}|inputs={build_input_sha256}|clean={source_clean}|END\0"
    );
    let archive_marker_values = archive_marker
        .as_bytes()
        .iter()
        .map(u8::to_string)
        .collect::<Vec<_>>()
        .join(", ");
    let generated = format!(
        "pub const SC_CORE_CANONICAL_ABI_ID_V1: u64 = 0x{identity:016x};\n\
         pub const SC_CORE_CANONICAL_ABI_TARGET_V1: &str = {target:?};\n\
         pub const SC_CORE_CANONICAL_ABI_VARIANT_V1: &str = {variant:?};\n\
         #[used]\n\
         static SC_CORE_ABI_BINDING_MARKER_V1: [u8; {marker_len}] = [{archive_marker_values}];\n",
        marker_len = archive_marker.len(),
    );
    let output_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let materialized_manifest = output_dir.join("core-abi-manifest-v1.json");
    fs::write(&materialized_manifest, &raw).expect("write materialized Core ABI manifest");
    fs::write(output_dir.join("abi_identity.rs"), generated)
        .expect("write generated Core ABI identity");
    println!(
        "cargo:rustc-env=SC_CORE_ABI_MANIFEST_PATH={}",
        materialized_manifest.display()
    );
}
