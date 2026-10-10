# loader

GameSense CS:GO Lua catalogue. Native **LUA → B** list; double-click a name to load/unload. ◇ inactive, ◆ active. `_` is the service row used to detect repeat clicks. No floating panel, repository text box or path settings.

## Install

1. Download `loader.lua` from this repository and add it to GameSense's Lua scripts.
2. Ensure the standard `gamesense/http` library is available. Allow Lua HTTP access according to your client settings.
3. Open the menu. The catalogue and scripts download automatically, sequentially. Initial download is approximately 31 MB and can take a while. Read `Update Log` for errors.
4. Double-click the required script. Double-click again to unload tracked handlers/UI.

The repository is already bound inside the loader. Checks occur at most every five minutes while the menu is open. Downloaded updates do **not** hot-replace running scripts: unload and reload to apply them. Cached scripts remain available if GitHub is unreachable.

Only one full AA script may be active at a time, to prevent incompatible builders overwriting each other. Dormant Aimbot is a separate helper; even helpers may conflict with another script's settings.

## What was changed — and what was not

All 12 supplied originals are preserved byte-for-byte under `sources/`. Their AA/aimbot algorithms were **not** rewritten. Generated `modules/` add a lifecycle adapter: tracked direct callbacks, delayed callbacks suppressed after unloading, hidden owned controls, scalar cvar/reference restoration where possible, and reuse of identical controls when reloading the same version. Repeated identical `renderer.measure_text` calls are cached only within one callback.

This is **not** a promise of zero FPS cost or maximum optimization. Rendering, original algorithms, startup parsing and downloads still cost resources. Large recovered sources can cause a startup pause. No live GameSense performance benchmark has been run.

## Important compatibility / safety limitations

- This loader executes trusted Lua, **not a sandbox**. Downloaded code has the same privileges as an ordinary GameSense Lua. Public repository updates are not independently authenticated by this loader beyond HTTPS and the configured owner/repo.
- FFI/native hooks and handlers created inside external `require` libraries cannot be fully tracked or safely undone by the generic adapter. Some scripts may require a full client restart after unloading. Native reference visibility is restored to `true`, because the documented API has no visibility getter. Shared settings and hotkey modes cannot always be restored exactly.
- Angelwings, Emberlash legacy, Evalate, Resistance and Rinnegan include reconstructed code. Annesty is a diagnostic/recovery build, not a verified production release.
- Donor dependencies/assets are **not** supplied by this archive in every case. Errors for missing `gamesense/*` libraries or native signatures must be handled per script. External libraries can bypass lifecycle tracking.
- Rinnegan contains references to external plain-HTTP services, including `http://62.60.159.30:2001/`. Other scripts reference external resources/services too. Those connections were not tested or endorsed. No comprehensive malware audit is claimed.
- Donors were parsed, **never executed**, during preparation. Static checks used Linux LuaJIT 2.1; this does not establish compatibility with every GameSense client version/native interface.

## Automatic publishing

Edit an original in `sources/` and push to `main`. The Actions workflow regenerates `modules/`, content-derived version IDs, `manifest.json` and `BUILD_REPORT.json`. After the workflow succeeds, the loader's next automatic check sees the new versions. The build transforms text and does **not** execute donor Lua.

`bootstrap/` contains the initial source archive split into base64 parts for transfer. `tools/build.py` verifies its SHA-256 before initial extraction. The workflow needs repository Actions enabled and `contents: write`.

## Checks

`TEST_RESULTS.txt` records syntax and synthetic mocked API tests. These test the loader/adapter, not the donors' gameplay behavior. Treat this as an experimental compatibility release and report the exact console error if a donor fails.
