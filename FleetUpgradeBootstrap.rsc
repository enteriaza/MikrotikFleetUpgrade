# ============================================================
# FleetUpgradeBootstrap - console-friendly installer
# Fetches FleetUpgradeInstaller.rsc and /import's it when the
# FleetUpgrade script or FleetUpgrade-startup scheduler is
# missing. No-op when both are already present.
# Paste into the terminal wrapped in one { ... } block, or
# /import this file. (c)2026 Chris Knipe
# ============================================================

{
:local baseUrl "http://192.168.0.1/firmware_files/mikrotik/"
:local scriptName "FleetUpgrade"
:local schedulerName "FleetUpgrade-startup"
:local installerFile "FleetUpgradeInstaller.rsc"
:local scriptPresent 0
:local schedulerPresent 0

:if ([:len [/system script find where name=$scriptName]] > 0) do={ :set scriptPresent 1 }
:if ([:len [/system scheduler find where name=$schedulerName]] > 0) do={ :set schedulerPresent 1 }

:if (($scriptPresent = 1) && ($schedulerPresent = 1)) do={
:log info "FleetUpgradeBootstrap: script and scheduler already installed; nothing to do"
} else={
:log info ("FleetUpgradeBootstrap: incomplete install script=" . $scriptPresent . " scheduler=" . $schedulerPresent . "; resetting")

:do {
:local staleSched [/system scheduler find where name=$schedulerName]
:if ([:len $staleSched] > 0) do={ /system scheduler remove $staleSched }
:local staleScript [/system script find where name=$scriptName]
:if ([:len $staleScript] > 0) do={ /system script remove $staleScript }
:if ([:len [/system scheduler find where name=$schedulerName]] > 0) do={ :error "scheduler remains" }
:if ([:len [/system script find where name=$scriptName]] > 0) do={ :error "script remains" }
} on-error={
:log error "FleetUpgradeBootstrap: failed to remove existing script/scheduler"
:error "FleetUpgradeBootstrap: cleanup failed"
}

:do {
:local staleInstaller [/file find where name=$installerFile]
:if ([:len $staleInstaller] > 0) do={ /file remove $staleInstaller }
} on-error={
:log error "FleetUpgradeBootstrap: stale installer remove failed"
:error "FleetUpgradeBootstrap: stale installer remove failed"
}

:do {
/tool fetch url=($baseUrl . $installerFile) dst-path=$installerFile
} on-error={
:log warning ("FleetUpgradeBootstrap: fetch reported error; checking for file url=" . $baseUrl . $installerFile)
}

:local wait 0
:local downloaded 0
:local downloadedSize 0
:while (($downloaded = 0) && ($wait < 30)) do={
:set wait ($wait + 1)
:foreach f in=[/file find where name=$installerFile] do={
:set downloaded ($downloaded + 1)
:set downloadedSize [/file get $f size]
}
:if ($downloaded = 0) do={ :delay 100ms }
}

:if ($downloaded = 0) do={
:log error ("FleetUpgradeBootstrap: installer missing after fetch url=" . $baseUrl . $installerFile)
:error "FleetUpgradeBootstrap: fetch failed"
}
:if ($downloadedSize = 0) do={
:log error ("FleetUpgradeBootstrap: installer empty after fetch file=" . $installerFile)
:error "FleetUpgradeBootstrap: fetch failed"
}

:do {
/import file-name=$installerFile
} on-error={
:log error ("FleetUpgradeBootstrap: import failed file=" . $installerFile)
:error "FleetUpgradeBootstrap: import failed"
}

:do {
:local doneInstaller [/file find where name=$installerFile]
:if ([:len $doneInstaller] > 0) do={ /file remove $doneInstaller }
} on-error={
:log error ("FleetUpgradeBootstrap: installer cleanup failed file=" . $installerFile)
:error "FleetUpgradeBootstrap: cleanup failed"
}

:log info "FleetUpgradeBootstrap: import complete"
}
}
