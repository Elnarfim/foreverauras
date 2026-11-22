# Tests

Regression tests for ForeverAuras logic that can be checked outside the game.
They load the real addon files with plain Lua, stub the WoW globals those files
touch, and check behavior that players depend on. The layout follows the
[WeakAuras2 tests](https://github.com/WeakAuras/WeakAuras2/tree/main/tests),
with stubs for the Forever client (secret values, the restriction state,
`Private.TimedAPI`).

| File | What it checks |
| --- | --- |
| `aura_environment_test.lua` | The custom-code sandbox: blocked Lua and WoW functions and tables (including the ForeverAuras saved variables and the extra guild, logout and console API), `_G`/`getglobal`/dotted names, the `WeakAuras` and `ForeverAuras` proxies, global writes, the `GetData` copy cache, timed `CreateFrame`, anchor targets (`GetSanitizedFrame`), and the builtin environment. |
| `aura_helpers_test.lua` | `WA_Utf8Sub`, `PadString` and `WA_ClassColorName`, including secret names and class tokens. |
| `common_options_test.lua` | The options panel evaluates stored code only inside the sandbox when it draws the error label under a code box. |
| `transmission_test.lua` | Export and import: round trips, non-transmissable fields, group exports with excluded children, every WeakAuras string format (v0, v1, `!WA:2!`, `!FA:2!`), and pasted text that is not an aura. |
| `aura_saved_data_test.lua` | `aura_env.saved` survives a reload, and saving uses the addon's private LibSerialize copy, not another addon's. |
| `client_api_test.lua` | `ClientAPI.RestrictionsActive` fails closed, and `Secrets.lua` announces only changes of the restriction state. |
| `subscribable_object_test.lua` | Subscriber order, priority and callbacks of `SubscribableObject`. |
| `duration_text_test.lua` | Remaining Time conditions drawn by the client formatter (`DurationTextStyle`), which conditions work in combat (`TimerConditionHandled`), formatter settings, and when the timer text is hidden. |

## What a passing run does not show

A pass is not a security proof or an in-game check. The tests probe only the
routes and cases they name. They do not load the addon in WoW, so they cannot
show `.toc` load order, taint, secure execution, or how the client really
treats secret values. The stubs make these assumptions; check them against the
client when a test depends on them:

- A secret value is an opaque userdata. Indexing a table guarded with
  `stubs.secretKeyGuard` with one raises the client's error. Nothing else
  about secret values is modelled.
- The numeric rule formatter in `duration_text_test.lua` applies a breakpoint
  from its threshold up to the next one, the same reading `Styled` in
  `DurationText.lua` uses.
- `transmission_test.lua` walks groups like `Traverse` in `ForeverAuras.lua`.

## Running

The sandbox is built on `loadstring` and `setfenv`, which Lua 5.2 removed, so
the tests need Lua 5.1 or LuaJIT, the Lua the WoW client runs:

```sh
luajit tests/run.lua
```

On Windows, `winget install DEVCOM.LuaJIT` installs LuaJIT. Open a new
terminal afterwards so `luajit` is on the PATH.

The output of each file is shown as it runs. At the end, a summary lists every
skipped check, every failed check with the file it is in (and the expected and
actual values where the check records them), and every file that a Lua error
stopped, with the error. The run exits with a non-zero status when anything
failed.

### Muted checks

The sandbox checks for `DeleteMacro`, `AbandonSkill` and `PetAbandon`, which
upstream WeakAuras blocks but ForeverAuras does not yet, are muted: they show
up as skipped instead of failing. To run them anyway:

```sh
FA_TESTS_UNMUTE=1 luajit tests/run.lua
```

In PowerShell, set `$env:FA_TESTS_UNMUTE = "1"` before running. Once the three
names are on the block list, remove the mute in `aura_environment_test.lua` so
the checks always run.

Each test file also runs on its own, for example
`luajit tests/aura_environment_test.lua`. A failing expectation prints `FAIL`,
and the process exits with a non-zero status.

### Libraries

`ForeverAuras/Libs` is not in git (see `.gitignore`). `transmission_test.lua`
and `aura_saved_data_test.lua` need the real LibStub, LibDeflate, LibSerialize,
AceSerializer and LibCompress from it. Without them those files print `SKIP`
and pass, so a checkout without the libraries, such as CI, does not run those
checks. The summary line counts skips.

## Adding a test

Put shared WoW stubs in `wow_stubs.lua` and keep them to what the loaded files
touch. Write a new `*_test.lua` that requires `helpers` and `wow_stubs`, loads
the addon file with `T.loadAddonFile`, states expectations with `T.expect` or
`T.expectEqual`, and ends with `T.finish()`. Then add the file name to the list
in `run.lua`. When a sandbox escape is closed, add a case for it here so it
cannot come back.
