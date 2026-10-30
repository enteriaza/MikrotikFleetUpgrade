# ============================================================
# FleetUpgradeBootstrap - console-friendly installer
# Fetches FleetUpgradeInstaller.rsc and /import's it when the
# FleetUpgrade script or FleetUpgrade-startup scheduler is
# missing. No-op when both are already present.
# (c)2026 Chris Knipe <cknipe@opticnetworks.net>
# ============================================================

:local baseUrl "http://192.168.0.1/firmware_files/mikrotik/"
:local scriptName "FleetUpgrade"
:local schedulerName "FleetUpgrade-startup"
:local installerFile "FleetUpgradeInstaller.rsc"

:local scriptPresent false
:local schedulerPresent false
:if ([:len [/system script find where name=$scriptName]] > 0) do={
    :set scriptPresent true
}
:if ([:len [/system scheduler find where name=$schedulerName]] > 0) do={
    :set schedulerPresent true
}

:if (($scriptPresent = true) && ($schedulerPresent = true)) do={
    :log info ("FleetUpgradeBootstrap: script and scheduler already installed; nothing to do")
} else={
    :log info ("FleetUpgradeBootstrap: incomplete install script=" . $scriptPresent . \
        " scheduler=" . $schedulerPresent . "; resetting")

    :do {
        :local staleSched [/system scheduler find where name=$schedulerName]
        :if ([:len $staleSched] > 0) do={ /system scheduler remove $staleSched }
        :local staleScript [/system script find where name=$scriptName]
        :if ([:len $staleScript] > 0) do={ /system script remove $staleScript }
        :if ([:len [/system scheduler find where name=$schedulerName]] > 0) do={
            :error "scheduler remains"
        }
        :if ([:len [/system script find where name=$scriptName]] > 0) do={
            :error "script remains"
        }
    } on-error={
        :log error ("FleetUpgradeBootstrap: failed to remove existing script/scheduler")
        :error "FleetUpgradeBootstrap: cleanup failed"
    }

    :do {
        :local staleInstaller [/file find where name=$installerFile]
        :if ([:len $staleInstaller] > 0) do={ /file remove $staleInstaller }
        :if ([:len [/file find where name=$installerFile]] > 0) do={
            :error "stale installer remains"
        }
        /tool fetch url=($baseUrl . $installerFile) mode=http dst-path=$installerFile keep-result=yes
        :if ([:len [/file find where name=$installerFile]] != 1) do={
            :error "installer missing after fetch"
        }
        :if ([/file get [/file find where name=$installerFile] size] = 0) do={
            :error "installer empty"
        }
    } on-error={
        :log error ("FleetUpgradeBootstrap: fetch failed url=" . $baseUrl . $installerFile)
        :error "FleetUpgradeBootstrap: fetch failed"
    }

    :do {
        /import file-name=$installerFile
    } on-error={
        :log error ("FleetUpgradeBootstrap: import failed file=" . $installerFile)
        :error "FleetUpgradeBootstrap: import failed"
    }

    :if ([:len [/system script find where name=$scriptName]] = 0) do={
        :log error ("FleetUpgradeBootstrap: script missing after import")
        :error "FleetUpgradeBootstrap: script not installed"
    }
    :if ([:len [/system scheduler find where name=$schedulerName]] = 0) do={
        :do {
            /system scheduler add name=$schedulerName start-time=startup interval=0s \
                on-event=("/system script run " . $scriptName) \
                policy=ftp,reboot,read,write,policy,test disabled=no
        } on-error={
            :log error ("FleetUpgradeBootstrap: scheduler create failed after import")
            :error "FleetUpgradeBootstrap: scheduler create failed"
        }
    }
    :if ([:len [/system scheduler find where name=$schedulerName]] = 0) do={
        :log error ("FleetUpgradeBootstrap: scheduler missing after import")
        :error "FleetUpgradeBootstrap: scheduler not installed"
    }

    :do {
        :local doneInstaller [/file find where name=$installerFile]
        :if ([:len $doneInstaller] > 0) do={ /file remove $doneInstaller }
        :if ([:len [/file find where name=$installerFile]] > 0) do={
            :error "installer remains"
        }
    } on-error={
        :log error ("FleetUpgradeBootstrap: installer cleanup failed file=" . $installerFile)
        :error "FleetUpgradeBootstrap: cleanup failed"
    }

    :log info ("FleetUpgradeBootstrap: installed script=" . $scriptName . \
        " scheduler=" . $schedulerName)
}
