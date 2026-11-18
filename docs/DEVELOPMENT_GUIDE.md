# HyperDownload — Development & Environment Guide

> **Document Status:** Phase 0 Environment Audit & Developer Setup Guide  
> **Host Audit Date:** 2026-11-18  
> **Host OS:** Windows 11 (Version 10.0.26200.9974, 25H2, `windows_x64`)

---

## 1. Host Environment Audit Results

A live inspection of the repository (`f:\Documents\Flutter\hyper_downloader`) and local toolchain produced the following verified status:

| Component | Status | Verified Version / Path / Notes |
| :--- | :---: | :--- |
| **Git Repository** | ✅ Ready | Initialized on branch `main` (empty, 0 commits) |
| **Flutter SDK** | ✅ Ready | `3.44.1` (stable channel) at `C:\src\flutter\flutter` |
| **Dart SDK** | ✅ Ready | `3.12.1` (`windows_x64`) |
| **Android SDK** | ✅ Ready | Platform `android-36` (`36.0.0`), Build-Tools `36.0.0`, CMake, Emulator `35.5.10.0` at `C:\Users\MuhammadAli\AppData\Local\Android\Sdk` |
| **Android NDK** | ✅ Ready | Versions `28.2.13676358` and `29.0.14206865` installed under `Sdk\ndk\` |
| **Java / JDK** | ✅ Ready | OpenJDK `21.0.6` (`C:\Program Files\Android\Android Studio\jbr\bin\java`) |
| **Android Licenses** | ⚠️ Action Needed | Some Android SDK licenses are not accepted (`flutter doctor --android-licenses`) |
| **Rust (`rustup` / `rustc` / `cargo`)** | ❌ Missing | Not installed (`$env:USERPROFILE\.cargo\bin` absent) |
| **Visual Studio 2022 C++ Build Tools** | ❌ Missing | Required by both Flutter Windows runner and Rust `x86_64-pc-windows-msvc` linker (`link.exe`) |
| **LLVM / Clang (`libclang`)** | ❌ Missing | Required on Windows by `flutter_rust_bridge_codegen` / `ffigen` |
| **Node.js** | ✅ Ready | `24.16.0.0` (`C:\Program Files\nodejs\node.exe`) — satisfies `yt-dlp` JS runtime (`>= 22.0.0`) |
| **Python** | ⚠️ Action Needed (`3.13` for Phase 3) | `3.9.150.1013` found (`yt-dlp` requires `3.11+`; Chaquopy `17.2.0` with Android Python `3.13` requires matching host `buildPython 3.13.x`). Windows `yt-dlp.exe` bypasses host Python, but **Python `3.13`** must be installed before Phase 3. |
| **`yt-dlp.exe` / `deno.exe` / `ffmpeg.exe`** | ❌ Missing on `PATH` | Needed for Phase 2 Windows prototype (`Deno >= 2.3.0`, `QuickJS >= 2025-4-26`, or `Node.js >= 22.0.0`) |

---

## 2. Prerequisite Installation Guide (Before Phase 1)

Run the following setup steps in PowerShell before starting Phase 1 implementation:

### Step 1: Install Visual Studio 2022 Build Tools (C++ Workload)
Install **Visual Studio 2022 Community** or **Visual Studio 2022 Build Tools** with the **"Desktop development with C++"** workload (including MSVC v143 build tools, Windows 11 SDK, and CMake):
```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

### Step 2: Install LLVM / Clang (Required for `flutter_rust_bridge` v2 Codegen)
```powershell
winget install LLVM.LLVM
```
Verify `C:\Program Files\LLVM\bin` contains `libclang.dll` (add to `PATH` or set `LIBCLANG_PATH` if needed).

### Step 3: Install Rust Toolchain & Cross-Compilation Targets
```powershell
winget install Rustlang.Rustup
# Open a fresh PowerShell session after rustup finishes, then run:
rustup default stable
rustup component add rustfmt clippy
rustup target add x86_64-pc-windows-msvc
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
```

### Step 4: Install `flutter_rust_bridge_codegen` v2.13.0
```powershell
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
```

### Step 5: Install Host Python `3.13` (Required for Phase 3 Android Chaquopy `buildPython`)
Chaquopy `17.2.0` targets Android Python `3.13` (recommended for 16 KB page alignment) and strictly requires `buildPython` to match the app's major.minor version (`3.13`):
```powershell
winget install Python.Python.3.13
```

### Step 6: Provision `yt-dlp.exe`, JS Runtime & `ffmpeg.exe` (Phase 2 Windows Prototype)
HyperDownload on Windows uses standalone `yt-dlp.exe` alongside an external JS runtime (**Deno `>= 2.3.0`**, **QuickJS `>= 2025-4-26`**, or local **Node.js `>= 22.0.0`**—your installed **Node.js `24.16.0`** already satisfies this) and FFmpeg for stream merging:
```powershell
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg
winget install DenoLand.Deno
```

### Step 7: Accept Android SDK Licenses & Verify Doctor
```powershell
flutter doctor --android-licenses
flutter doctor -v
rustc --version
cargo --version
rustup target list --installed
```
Verify 16 KB ELF alignment on Android `.so` binaries before Phase 1/Phase 3 completion using NDK `llvm-objdump`:
```powershell
& "$env:LOCALAPPDATA\Android\Sdk\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-objdump.exe" -p path\to\lib.so | Select-String "LOAD|align"
```

---

## 3. Verified Dependency Baseline

All packages and crates below were checked for current stable compatibility across Windows and Android:

### Flutter / Dart (`apps/client/pubspec.yaml`)
- `flutter_rust_bridge: ^2.13.0` (FFI bindings + Cargokit)
- `flutter_bloc: ^9.1.1` & `bloc: ^9.2.1` (State management)
- `equatable: ^3.0.0` (Value equality)
- `go_router: ^18.1.4` (Declarative navigation & deep links)
- `freezed_annotation: ^3.1.0` (Optional immutable model annotations if needed outside FRB models)
- Dev: `bloc_test: ^10.0.0`, `mocktail: ^1.0.5`, `integration_test` (Flutter SDK)

### Rust Workspace (`rust/Cargo.toml`)
- `flutter_rust_bridge = "=2.13.0"`
- `tokio = { version = "1.54", features = ["rt-multi-thread", "macros", "fs", "io-util", "sync", "time"] }`
- `reqwest = { version = "0.13", default-features = false, features = ["json", "stream", "rustls-tls"] }` (uses `rustls-tls` to avoid OpenSSL cross-compilation issues on Android NDK)
- `rusqlite = { version = "0.42", features = ["bundled"] }` (compiles SQLite from source statically so Android and Windows share identical SQLite features and WAL behavior)
- `serde = { version = "1.0", features = ["derive"] }`
- `serde_json = "1.0"`
- `thiserror = "2.0"`
- `url = "2.5.8"`
- `uuid = { version = "1.29", features = ["v4", "serde"] }`
- `async-trait = "0.1.92"`
- `tokio-util = { version = "0.7", features = ["rt"] }`
- Dev (`test_server`): `axum = "0.8.9"`

---

## 4. Standard Build, Codegen & Test Commands (Phase 1+)

### Regenerating FFI Bindings
Whenever `rust/crates/engine_ffi/src/api.rs` or exported `media_models` types change:
```powershell
cd apps/client
flutter_rust_bridge_codegen generate
```

### Rust Verification (Run in `rust/`)
```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

### Flutter Verification (Run in `apps/client/`)
```powershell
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

### Running the Application
```powershell
# Windows Desktop
flutter run -d windows

# Android Emulator / Physical Device
flutter run -d android
```

---

## 5. Revised Implementation Plan & Milestone Protocol

### Phased Rollout Sequence
1. **Phase 1 — Minimal Flutter + Rust FRB v2 Integration:** Scaffold minimal `apps/client` + `rust/crates/engine_ffi` (`ping` / `engine_version` FFI call) and verify **Debug and Release** builds on **Windows Desktop** and **Android** (including 16 KB alignment check on `libengine_ffi.so`).
2. **Phase 2 — Windows `yt-dlp` Prototype:** Build standalone `yt-dlp.exe` + JS runtime (`Node >= 22` / `Deno >= 2.3` / `QuickJS >= 2025-4-26`) + `ffmpeg.exe` prototype validating video inspection, dynamic format discovery, playlist inspection, `DownloadFormatChoice`, structured progress, pause/resume/cancel, and FFmpeg stream muxing.
3. **Phase 3 — Android `yt-dlp` / Chaquopy Feasibility Prototype:** Validate Chaquopy `17.2.0` (Python `3.13` + host `buildPython 3.13`), `yt-dlp` + `yt-dlp-ejs`, `libqjs.so` + `libffmpeg.so` (`useLegacyPackaging = true`, `extractNativeLibs = true`, `filesDir/bin` symlinks, 16 KB alignment), JNI <-> Kotlin <-> Python progress hooks, child-process termination on cancel, and W^X-safe wheel updates.
4. **Phase 4 — Shared Engine & Full Application:** Implement `media_models`, `persistence` (continuous checkpoints + `SIGKILL` recovery), `connection_manager`, `download_core` + `test_server`, `download_queue`, `HyperDownloadJobService` (UIDT), and all 7 Flutter Bloc UI screens.

### Per-Milestone Engineering Protocol
Every milestone after Phase 0 must strictly obey the incremental workflow:
1. Explain the milestone design and list all files to create or modify.
2. Implement only the agreed milestone scope (no speculative abstractions or multi-phase jumps).
3. Run `cargo fmt`, `cargo clippy`, `dart format`, and `flutter analyze`.
4. Run all relevant Rust, Flutter, and `test_server` integration tests.
5. Fix all warnings or test failures before proceeding.
6. Report exact observed test output, remaining limitations, and update docs or ADRs (`docs/decisions/ADR-XXXX.md`) whenever an architectural decision evolves.
