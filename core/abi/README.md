# FOSS Preview ABI

This tree contains the Mac → Android preview subset, not the full commercial Core ABI.
Only Apple macOS arm64/x86_64 and Android arm64 targets are declared. The `full` label in
the existing archive tooling means the complete **95-symbol preview** surface; it does
not authorize linking a Standard/full-commercial archive. `minimal` is retained for
tool compatibility, with a distinct identity and no additional excluded symbols.

`tools/core_abi_manifest.py generate-set` derives signatures, enums, layouts, offsets,
calling conventions and target/variant identities from the trimmed public headers.
Generated identities must never be copied from the commercial tree. Both adapters and
the symbol baseline are checked against this generated surface.

The existing canonical builder still requires a clean commit, snapshots that source,
embeds the exact source/tree/input identity, verifies architecture and symbols, and
generates the archive receipt. No opaque private library is needed to reproduce a build.

Regenerate and check after an intentional preview ABI change:

```sh
python3 tools/core_abi_manifest.py generate-set
python3 tools/core_abi_manifest.py generate-set --check
```

Authentication, records, staged session ingress, capability negotiation, frame/input and
video/control codecs remain. Recovery/UDP/driver and unrelated lifecycle policy reducers
are not exported or included in source. Wire codecs needed for compatible classification
remain unchanged; retaining a codec does not advertise its optional feature.
