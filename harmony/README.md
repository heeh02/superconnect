# Superconnect — HarmonyOS (Pad) app

Tablet-side app. Phase 0 = a TCP server that speaks the Superconnect wire
protocol: it accepts the Mac's connection (tunnelled over USB by `hdc fport`),
replies `hello_ack` to `hello`, and `pong` to `ping`, showing a live log on
screen.

## What's here (the meaningful, stable parts)

```
harmony/
├── AppScope/app.json5
└── entry/src/main/
    ├── module.json5                         # ability + ohos.permission.INTERNET
    ├── ets/
    │   ├── entryability/EntryAbility.ets
    │   ├── pages/Index.ets                   # status + log UI; starts the server
    │   ├── protocol/FrameCodec.ets           # framing — matches proto/vectors.json
    │   ├── transport/TcpServerTransport.ets  # @ohos.net.socket TCP server (L0/L1)
    │   └── session/Session.ets               # CONTROL handshake (hello/ping)
    ├── cpp/                                  # Phase 1 native module (placeholder)
    └── resources/base/...                    # strings/colors/pages
```

## How to build & run (DevEco Studio)

These sources target **HarmonyOS NEXT / 5.x (API 12+)**. The build system files
(`build-profile.json5`, `oh-package.json5`, `hvigor/`) are intentionally **not**
committed because they are DevEco-version-specific. Easiest path:

1. Install **DevEco Studio** + HarmonyOS SDK (and the **Command Line Tools**, which
   provide `hdc` — add its `toolchains/` to your `PATH`; see `tools/`).
2. In DevEco: **Create Project → Empty Ability**, bundle name `com.superconnect.pad`,
   device type **Tablet**, language **ArkTS**, the API level matching your MatePad.
3. Replace the generated `entry/src/main/ets/` with the files here, and merge:
   - `module.json5` → add the `ohos.permission.INTERNET` block.
   - `resources/base/profile/main_pages.json` → ensure it lists `pages/Index`.
4. Enable **Developer Mode + USB debugging** on the tablet; connect USB; trust the host.
5. **Run** ▶ to install via `hdc` and launch. The screen shows
   `status: listening 127.0.0.1:8888`.
6. On the Mac, set up the tunnel and run the demo client (see repo `README.md` /
   `tools/`): `tools/fport.sh` then `swift run superconnect-mac`.

You should see the tablet log `client connected` → `received hello` and the Mac
print `handshake OK` + three RTT measurements.

## ArkTS strictness note

If the strict ArkTS linter in your DevEco/SDK version flags any socket type name
(`socket.SocketMessageInfo`, `TCPSendOptions`) or the dynamic JSON cast in
`Session.ets`, adjust to your SDK's exact `.d.ts` signatures — the **logic and
the wire format** are what matter and are covered by `proto/vectors.json`.

> The framing in `FrameCodec.ets` is verified byte-identical to the Mac (Swift)
> and the portable C++ via the shared golden vectors. You can sanity-check the
> Swift/C++ side today with no device (`mac/` tests and `shared/cpp/tests`).
