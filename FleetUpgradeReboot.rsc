# ============================================================
# FleetUpgradeReboot - controlled reboot gate for EMS
# Fetches the remote version file; reboots only when RouterOS
# is below the v7 target or RouterBOARD firmware is not
# aligned (current-firmware != upgrade-firmware). No-op when
# already at the desired level. On reboot FleetUpgrade-startup
# runs FleetUpgrade, which performs the actual upgrade.
# RouterOS v6 and v7 compatible. (c)2026 Chris Knipe
#
# CLI-safe: every statement is a single line and all state is
# held in :global variables prefixed fuReboot, so it works when
# sent line by line over SSH, pasted into a terminal, run via
# /import, or stored as a /system script. :local is NOT used
# because the CLI discards :local at the end of each line.
# Globals are removed at the end; a reboot clears them anyway.
# fetch uses as-value so no interactive status screen can eat
# pasted input; reboot goes through :execute so the CLI never
# shows its "Reboot, yes? [y/N]" prompt.
# ============================================================

/system script environment remove [find where name~"^fuReboot"]
:global fuRebootBaseUrl "http://192.168.0.1/firmware_files/mikrotik/"
:global fuRebootMetaFile "fleet-upgrade-reboot-version"
:global fuRebootTargetMajor 7
:global fuRebootOk true
:global fuRebootTarget ""
:global fuRebootVersion ""
:global fuRebootCurFw ""
:global fuRebootUpFw ""
:global fuRebootAction "none"
:global fuRebootN 0
:global fuRebootD1 0
:global fuRebootD2 0
:global fuRebootTMajor 0
:global fuRebootTMinor 0
:global fuRebootTPatch 0
:global fuRebootMajor 0
:global fuRebootMinor 0
:global fuRebootPatch 0

:do { /file remove [/file find where name=$fuRebootMetaFile] } on-error={ }
:if ([:len [/file find where name=$fuRebootMetaFile]] > 0) do={ :set fuRebootOk false; :log error "FleetUpgradeReboot: stage=metadata reason=stale metadata cleanup failed" }

:if ($fuRebootOk = true) do={ :do { /tool fetch url=($fuRebootBaseUrl . "version") dst-path=$fuRebootMetaFile as-value } on-error={ :log warning ("FleetUpgradeReboot: stage=metadata reason=fetch reported error; checking for file url=" . $fuRebootBaseUrl . "version") } }
:set fuRebootN 0
:while (($fuRebootOk = true) && ($fuRebootN < 30) && ([:len [/file find where name=$fuRebootMetaFile]] = 0)) do={ :set fuRebootN ($fuRebootN + 1); :delay 100ms }
:if (($fuRebootOk = true) && ([:len [/file find where name=$fuRebootMetaFile]] != 1)) do={ :set fuRebootOk false; :log error ("FleetUpgradeReboot: stage=metadata reason=target missing after fetch url=" . $fuRebootBaseUrl . "version") }
:if (($fuRebootOk = true) && ([/file get [/file find where name=$fuRebootMetaFile] size] = 0)) do={ :set fuRebootOk false; :log error ("FleetUpgradeReboot: stage=metadata reason=target empty after fetch url=" . $fuRebootBaseUrl . "version") }
:if ($fuRebootOk = true) do={ :set fuRebootTarget [/file get [/file find where name=$fuRebootMetaFile] contents] }
:do { /file remove [/file find where name=$fuRebootMetaFile] } on-error={ }

:while (([:len $fuRebootTarget] > 0) && ([:typeof [:find " \t\r\n" [:pick $fuRebootTarget 0 1]]] != "nil")) do={ :set fuRebootTarget [:pick $fuRebootTarget 1 [:len $fuRebootTarget]] }
:while (([:len $fuRebootTarget] > 0) && ([:typeof [:find " \t\r\n" [:pick $fuRebootTarget ([:len $fuRebootTarget] - 1) [:len $fuRebootTarget]]]] != "nil")) do={ :set fuRebootTarget [:pick $fuRebootTarget 0 ([:len $fuRebootTarget] - 1)] }
:if (($fuRebootOk = true) && ([:len $fuRebootTarget] = 0)) do={ :set fuRebootOk false; :log error "FleetUpgradeReboot: stage=metadata reason=target file is blank" }
:if ($fuRebootOk = true) do={ :for i from=0 to=([:len $fuRebootTarget] - 1) do={ :if ([:typeof [:find "0123456789." [:pick $fuRebootTarget $i ($i + 1)]]] = "nil") do={ :set fuRebootOk false } } }
:if ($fuRebootOk = true) do={ :set fuRebootD1 [:find $fuRebootTarget "."]; :set fuRebootD2 -1; :if ([:typeof $fuRebootD1] != "nil") do={ :set fuRebootD2 [:find $fuRebootTarget "." ($fuRebootD1 + 1)] } }
:if (($fuRebootOk = true) && (([:typeof $fuRebootD1] = "nil") || ([:typeof $fuRebootD2] = "nil") || ($fuRebootD1 = 0) || ($fuRebootD2 = ($fuRebootD1 + 1)) || ($fuRebootD2 = ([:len $fuRebootTarget] - 1)) || ([:typeof [:find $fuRebootTarget "." ($fuRebootD2 + 1)]] != "nil"))) do={ :set fuRebootOk false }
:if (($fuRebootOk = false) && ([:len $fuRebootTarget] > 0)) do={ :log error ("FleetUpgradeReboot: stage=metadata reason=target is not numeric major.minor.patch value=" . $fuRebootTarget) }
:if ($fuRebootOk = true) do={ :set fuRebootTMajor [:tonum [:pick $fuRebootTarget 0 $fuRebootD1]]; :set fuRebootTMinor [:tonum [:pick $fuRebootTarget ($fuRebootD1 + 1) $fuRebootD2]]; :set fuRebootTPatch [:tonum [:pick $fuRebootTarget ($fuRebootD2 + 1) [:len $fuRebootTarget]]] }
:if (($fuRebootOk = true) && ($fuRebootTMajor != $fuRebootTargetMajor)) do={ :set fuRebootOk false; :log error ("FleetUpgradeReboot: stage=metadata reason=target major must be " . $fuRebootTargetMajor . " value=" . $fuRebootTarget) }
:if ($fuRebootOk = true) do={ :log info ("FleetUpgradeReboot: stage=metadata target=" . $fuRebootTarget . " verified") }

:if ($fuRebootOk = true) do={ :set fuRebootVersion [/system resource get version]; :if ([:typeof [:find $fuRebootVersion " "]] != "nil") do={ :set fuRebootVersion [:pick $fuRebootVersion 0 [:find $fuRebootVersion " "]] } }
:if ($fuRebootOk = true) do={ :set fuRebootD1 [:find $fuRebootVersion "."]; :set fuRebootD2 -1; :if ([:typeof $fuRebootD1] != "nil") do={ :set fuRebootD2 [:find $fuRebootVersion "." ($fuRebootD1 + 1)] } }
:if (($fuRebootOk = true) && (([:typeof $fuRebootD1] = "nil") || ([:typeof $fuRebootD2] = "nil") || ($fuRebootD1 = 0) || ($fuRebootD2 = ($fuRebootD1 + 1)) || ($fuRebootD2 = ([:len $fuRebootVersion] - 1)))) do={ :set fuRebootOk false; :log error ("FleetUpgradeReboot: stage=inventory reason=installed version malformed value=" . $fuRebootVersion) }
:if ($fuRebootOk = true) do={ :set fuRebootMajor [:tonum [:pick $fuRebootVersion 0 $fuRebootD1]]; :set fuRebootMinor [:tonum [:pick $fuRebootVersion ($fuRebootD1 + 1) $fuRebootD2]]; :set fuRebootPatch [:tonum [:pick $fuRebootVersion ($fuRebootD2 + 1) [:len $fuRebootVersion]]] }
:if (($fuRebootOk = true) && (([:typeof $fuRebootMajor] != "num") || ([:typeof $fuRebootMinor] != "num") || ([:typeof $fuRebootPatch] != "num"))) do={ :set fuRebootOk false; :log error ("FleetUpgradeReboot: stage=inventory reason=installed version not numeric value=" . $fuRebootVersion) }

:if ($fuRebootOk = true) do={ :do { :set fuRebootCurFw [/system routerboard get current-firmware]; :set fuRebootUpFw [/system routerboard get upgrade-firmware] } on-error={ :set fuRebootOk false; :log error "FleetUpgradeReboot: stage=inventory reason=RouterBOARD information unavailable" } }
:if (($fuRebootOk = true) && (([:len $fuRebootCurFw] = 0) || ([:len $fuRebootUpFw] = 0))) do={ :set fuRebootOk false; :log error "FleetUpgradeReboot: stage=inventory reason=empty RouterBOARD firmware property" }
:if ($fuRebootOk = true) do={ :log info ("FleetUpgradeReboot: stage=inventory version=" . $fuRebootVersion . " target=" . $fuRebootTarget . " current-firmware=" . $fuRebootCurFw . " upgrade-firmware=" . $fuRebootUpFw) }

:if ($fuRebootOk = true) do={ :set fuRebootAction "reboot" }
:if (($fuRebootOk = true) && ($fuRebootMajor = $fuRebootTargetMajor) && (($fuRebootMinor > $fuRebootTMinor) || (($fuRebootMinor = $fuRebootTMinor) && ($fuRebootPatch >= $fuRebootTPatch))) && ($fuRebootCurFw = $fuRebootUpFw)) do={ :set fuRebootAction "none" }

:if (($fuRebootOk = true) && ($fuRebootAction = "none")) do={ :log info ("FleetUpgradeReboot: stage=complete reason=RouterOS at/above target and firmware aligned; no reboot version=" . $fuRebootVersion . " target=" . $fuRebootTarget . " firmware=" . $fuRebootCurFw) }
:if (($fuRebootOk = true) && ($fuRebootAction = "reboot")) do={ :log warning ("FleetUpgradeReboot: stage=reboot action=reboot version=" . $fuRebootVersion . " target=" . $fuRebootTarget . " current-firmware=" . $fuRebootCurFw . " upgrade-firmware=" . $fuRebootUpFw) }
:if ($fuRebootOk = false) do={ :log error "FleetUpgradeReboot: stage=abort reason=preceding check failed; no reboot" }
:if (($fuRebootOk = true) && ($fuRebootAction = "reboot")) do={ :delay 2s; :execute "/system reboot"; :delay 10s } else={ /system script environment remove [find where name~"^fuReboot"] }
