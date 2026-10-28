# FleetUpgrade

Fail-closed RouterOS script for bulk upgrading a MikroTik RouterBOARD fleet from v6 / v7 to a remote-controlled RouterOS v7 target. Designed for large fleets (100K-scale intent): stop and wait for operator review rather than guess packages, unbounded-reboot, or downgrade outside policy.

Canonical script: [`fleet-upgrade.rsc`](fleet-upgrade.rsc).

## What it does

- Reads the target RouterOS version from a remote `version` file (no hardcoded runtime target).
- Upgrades **enabled** packages only (installed/enabled rows; disabled and XA ignored).
- Stages v6 devices through baseline `6.49.23`, then to the remote v7 target; v7-below-target goes straight to the target.
- Resolves wireless for v7: preserves `wifi-qcom` / `wifi-qcom-ac` / `wireless`, and maps enabled `wifiwave2` via board-model lists (see [wifiwave2 mapping](fleet-upgrade-wifiwave2-mapping.md)).
- Reconciles RouterBOARD firmware when RouterOS is already at/above target — including **allowed** firmware downgrade when `upgrade-firmware` differs from `current-firmware`.
- Downloads NPKs to non-installable `.npk.part` names, verifies nonzero size, then renames to final `.npk` only after the full set passes checks.
- Bounds reboot loops with a durable stage marker (`maxStageAttempts`, default 2) and aborts overlapping script instances.

RouterBOARD access is required. CHR / non-RouterBOARD systems are intentionally unsupported.

## How it works

Ordered stages matching the script:

1. **Init / single-instance** — Abort if another `FleetUpgrade` job is already running. Require exactly one `/system script` named `FleetUpgrade`.
2. **Startup scheduler** — Create or normalize `FleetUpgrade-startup` with `start-time=startup`, `interval=0s` (startup-only; not periodic), and policy `ftp,reboot,read,write,policy,test`.
3. **Reachability** — Ping `$serverIP` up to `$reachabilityAttempts` (60) times with 5s delay between failures. Stop without fetch/reboot if unreachable.
4. **Fetch target version** — Remove any stale local `fleet-upgrade-version`, HTTP-fetch `$baseUrl` + `version`, trim whitespace, accept only numeric `major.minor.patch` with major `7`. Cleanup of the temp file is mandatory.
5. **Inventory** — Read installed version, architecture, RAM, free storage, and RouterBOARD `model` / `current-firmware` / `upgrade-firmware`. Parse installed version strictly as `major.minor.patch` (major must be 6 or 7).
6. **Durable state marker** — Parse `/system script` comment form `FleetUpgrade:state=<stage>;expected=<value>;attempt=<number>`. Clear the marker only after observing the requested outcome (`pkg-v6-baseline`, `pkg-v7`, or `routerboard`). Malformed or conflicting markers hard-fail.
7. **Stage selection** — v6 below baseline → `pkg-v6-baseline`; v6 at baseline → `pkg-v7`; v6 newer than baseline → stop (no automatic v6 downgrade); v7 below target → `pkg-v7`; v7 at/above target → firmware path only (no package install).
8. **Package / wireless inventory** — Scan enabled packages; resolve wireless / wifiwave2 board map; build the NPK file list (or skip packages when at/above target).
9. **Firmware reconcile (at/above target)** — If firmware already aligned, log complete and exit. Otherwise persist a `routerboard` marker, run `/system routerboard upgrade`, reboot (bounded by `$maxStageAttempts`).
10. **Storage / arch gates (package path)** — Require `$minRam`, `$minFreeHdd`, and a supported architecture (`arm`, `arm64`, `mipsbe`, `mmips`, `smips`, `tile`, `powerpc`/`ppc`, `x86`).
11. **Download / verify / rename** — Reject unmanaged root `.npk` files; fetch each selected file as `.npk.part`; verify unique nonzero partials; recheck free storage; rename to final `.npk` names and reverify.
12. **Marker + reboot** — Persist the package-stage marker, delay 5s, `/system reboot`. On the next startup run, observe success or consume a bounded retry; after the limit, stop with the marker retained and **no reboot**.

## Remote web server setup

### Base URL

Default in the script:

```text
http://198.18.0.70/firmware_files/mikrotik/
```

Configured as `$baseUrl`. Reachability uses `$serverIP` (`198.18.0.70` by default) via ping; package and metadata fetches use HTTP under `$baseUrl`.

### Required `version` file

Publish a plain-text file at:

```text
http://198.18.0.70/firmware_files/mikrotik/version
```

Contents must be a single RouterOS **v7** `major.minor.patch` value (example: `7.23.8`), optionally with surrounding whitespace/newlines. Empty, non-numeric, extra-component, or non-v7 major values abort the run. There is no hardcoded target fallback.

### NPK layout and naming

Place every NPK the fleet may request under the same `$baseUrl` directory. Naming expected by the script:

| Stage / layout | Pattern | Example |
| --- | --- | --- |
| v6 combined `routeros` bundle | `routeros-<architecture>-<version>.npk` | `routeros-arm-6.49.23.npk` |
| v6 individual (`system` unbundled) | `system-<version>-<arch>.npk` | `system-6.49.23-arm.npk` |
| v6 Extra / individual component | `<name>-<version>-<arch>.npk` | `wireless-6.49.23-arm.npk` |
| v7 base and Extras | `<name>-<version>-<arch>.npk` | `routeros-7.23.8-arm64.npk` |

Architecture notes:

- Supported package architectures: `arm`, `arm64`, `mipsbe`, `mmips`, `smips`, `tile`, `powerpc`/`ppc`, `x86`.
- RouterOS v6 may report `powerpc`; Extra and v7 filenames use `ppc`.
- `x86` individual/v7 filenames **omit** the architecture suffix (e.g. `routeros-7.23.8.npk`).
- From 7.13 on, `wifiwave2` has no NPK; mapped boards request `wifi-qcom` or `wifi-qcom-ac` instead.

Serve the base `routeros`/`system` package plus every Extra the fleet actually has enabled (for example `tr069-client`, `lte`, `wireless`, `wifi-qcom`, `wifi-qcom-ac`). Missing files cause download verification failure and **no reboot**.

### What must be reachable from the router

- ICMP to `$serverIP` (reachability gate).
- HTTP GET of `$baseUrl` + `version`.
- HTTP GET of every selected `$baseUrl` + `<filename>.npk`.

HTTP is not authenticated. Nonzero size is the only script-level integrity check — use a trusted network/path for production.

## Installing the script on a device

1. Import or paste [`fleet-upgrade.rsc`](fleet-upgrade.rsc) as a `/system script` named exactly **`FleetUpgrade`** (must be unique).
2. On first run the script creates or normalizes scheduler **`FleetUpgrade-startup`**:
   - `start-time=startup`
   - `interval=0s` (startup-only; avoids a periodic retry/reboot loop)
   - `on-event=/system script run FleetUpgrade`
   - policy: `ftp,reboot,read,write,policy,test`
   - `disabled=no`
3. You can also run `/system script run FleetUpgrade` manually for a one-shot attempt.
4. Confirm there is exactly one script and one scheduler with those names before fleet rollout.

Lab-validate on every hardware/package family before production use (see script header and hardening notes).

## Configuration knobs

Edit the locals at the top of `fleet-upgrade.rsc`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `baseUrl` | `http://198.18.0.70/firmware_files/mikrotik/` | HTTP root for `version` and NPKs |
| `serverIP` | `198.18.0.70` | Ping target for reachability |
| `scriptName` | `FleetUpgrade` | `/system script` name |
| `schedulerName` | `FleetUpgrade-startup` | Startup scheduler name |
| `versionMetaFile` | `fleet-upgrade-version` | Local temp name for fetched `version` |
| `v6Baseline` / `v6Major` / `v6Minor` / `v6Patch` | `6.49.23` / `6` / `49` / `23` | Fixed v6 staging baseline |
| `requiredTargetMajor` | `7` | Only remote major accepted |
| `reachabilityAttempts` | `60` | Ping cycles before abort (~5 minutes with 5s delay) |
| `maxStageAttempts` | `2` | Max reboots per identical stage/expected value |
| `minRam` | `67108864` | Minimum total RAM (bytes) for package path |
| `minFreeHdd` | `3554432` | Free-storage reserve (bytes) before/during fetch |
| `wifiQcomAcModels` | board-model list | Maps wifiwave2 → `wifi-qcom-ac` |
| `wifiQcomModels` | board-model list | Maps wifiwave2 → `wifi-qcom` |
| `wifiSplitMinor` | `13` | Minimum v7 minor that has split wifi NPKs |

## Wireless / wifiwave2

- Inventory uses **enabled** packages only.
- Enabled `wifi-qcom` and `wifi-qcom-ac` together → hard stop.
- Explicit `wifi-qcom` or `wifi-qcom-ac` wins; the board map is not consulted.
- Enabled `wifiwave2` without a split driver: exact `/system routerboard get model` lookup in `wifiQcomAcModels` / `wifiQcomModels`, then retry after stripping trailing `&<modem>` and `-TC`. Unmapped, double-mapped, or target below 7.13 → hard stop.
- Legacy `wireless` alongside a resolved split driver → warning; only the split driver NPK is requested for v7.
- Legacy `wireless` alone → `wireless` NPK.

Full board tables, confidence notes, and how to extend the lists: [`fleet-upgrade-wifiwave2-mapping.md`](fleet-upgrade-wifiwave2-mapping.md).

## Safety / fail-closed behavior

The script prefers a **stopped device with a retained marker** over an unsafe continue. Typical hard stops (log + `:error`, no reboot):

- Duplicate script instance, missing/duplicate script or scheduler objects
- Package server unreachable; metadata fetch/parse/policy failure; stale metadata cleanup failure
- Unsupported installed major; automatic v6 downgrade prohibited; RouterBOARD data unavailable
- Conflicting or unmapped wireless; insufficient RAM/storage; unsupported architecture
- Unmanaged `.npk` present; partial/zero-byte download; commit/rename failure
- Durable marker malformed, inconsistent, or unpersistable
- Stage/firmware retry limit exhausted

RouterOS package downgrades are not automated. At/above-target devices never download target NPKs; they may still run `/system routerboard upgrade` to align firmware (upgrade or downgrade to the firmware bundled with the installed release).

**Lab validation is mandatory** on representative hardware, architectures, and package layouts before fleet-wide use. There is no signed size/hash manifest; HTTP + nonzero size is not cryptographic integrity. See [`fleet-upgrade-final-hardening.md`](fleet-upgrade-final-hardening.md) for residual risks and test matrix.

## Logging

All operational messages use the prefix **`FleetUpgrade:`**. Search device logs for that string (stages such as `init`, `metadata`, `inventory`, `policy`, `pkg-v6-baseline`, `pkg-v7`, `routerboard`, `complete`). Stage lines typically include `stage=…` and `attempt=…`.
