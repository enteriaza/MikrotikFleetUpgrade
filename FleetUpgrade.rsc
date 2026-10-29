# Configuration (bytes unless noted).
:local baseUrl "http://192.168.0.1/firmware_files/mikrotik/"
:local serverIP "192.168.0.1"
:local scriptName "FleetUpgrade"
:local schedulerName "FleetUpgrade-startup"
:local versionMetaFile "fleet-upgrade-version"
:local v6Baseline "6.49.23"
:local v6Major 6
:local v6Minor 49
:local v6Patch 23
:local requiredTargetMajor 7
:local reachabilityAttempts 60
:local maxStageAttempts 2
:local minRam 67108864
# Retain this much free storage before every fetch. This is a
# conservative guard, not a substitute for a signed size manifest.
:local minFreeHdd 554432

# wifiwave2 (RouterOS 7.0-7.12) to 7.13+ split-driver mapping. Entries
# are exact "/system routerboard get model" strings. Lookup is exact
# first; if nothing matches, a trailing "&<modem>" part and a trailing
# "-TC" are removed and the lookup is repeated. A board found in neither
# list, or in both, stops the upgrade. Extend only from fleet inventory
# after confirming the radio family (see fleet-upgrade-wifiwave2-mapping.md).
# wifi-qcom-ac: ARM 802.11ac wave2 (IPQ4018/4019, QCA9984). arm only.
:local wifiQcomAcModels {"RBD25G-5HPacQD2HPnD";"RBD25GR-5HPacQD2HPnD";"RBD53G-5HacD2HnD";"RBD53G-5HacD2HnD-TC";"RBD53GR-5HacD2HnD";"RBD52G-5HacD2HnD";"RBD52G-5HacD2HnD-TC";"RBD53iG-5HacD2HnD";"RBcAPGi-5acD2nD";"RBcAPGi-5acD2nD-XL";"RBLDFG-5acD";"RBLHGG-5acD-XL";"RBLHGG-5HPacD2HPnD-XL";"RBD23UGS-5HPacD2HnD-NM";"RBD22UGS-5HPacD2HnD-15S";"RBwAPG-5HacD2HnD";"RBSXTsqG-5acD"}
# wifi-qcom: 802.11ax Qualcomm (IPQ50xx/IPQ60xx/IPQ807x). arm and arm64.
:local wifiQcomModels {"C52iG-5HaxD2HaxD";"C52iG-5HaxD2HaxD-TC";"C53UiG+5HPaxD2HPaxD";"L41G-2axD";"cAPGi-5HaxD2HaxD";"wAPG-5HaxD2HaxD";"S53UG+5HaxD2HaxD";"S53UG+5HaxD2HaxD-TC";"S53UG+M-5HaxD2HaxD";"S53UG+M-5HaxD2HaxD-TC";"H53UiG-5HaxQ2HaxQ";"L009UiGS-2HaxD-IN";"L009UiGS-2HaxD";"L22UGS-5HaxD2HaxD-15S";"L23UGSR-5HaxD2HaxD-NM";"L11UG-5HaxD-NB";"SXTsq-5axD"}
# wifi-qcom/wifi-qcom-ac NPKs first exist in this RouterOS 7 minor.
# Before it, legacy wireless drivers live inside the routeros bundle.
:local wifiSplitMinor 13
# Devices with radios but no enabled standalone driver row (RouterOS v6
# bundles wireless inside routeros) get the legacy "wireless" NPK on the
# v7 jump: /interface wireless configuration and CAPsMAN v1 survive.
# Set true to pick wifi-qcom-ac instead on boards in wifiQcomAcModels;
# that discards the wireless configuration and is not for unattended use.
:local preferQcomAcOnJump false

# Prevent scheduler/manual overlap from racing files or markers.
#:do {
#    :if ([/system script job print count-only where script=$scriptName] > 1) do={
#        :log error ("FleetUpgrade: stage=init attempt=0 reason=another script instance is running")
#        :error "duplicate instance"
#    }
#} on-error={
#    :log error ("FleetUpgrade: stage=init attempt=0 reason=single-instance check failed")
#    :error "FleetUpgrade: single-instance check failed"
#}

# Locate exactly one installed script object.
:local scriptId ""
:do {
    :set scriptId [/system script find where name=$scriptName]
} on-error={
    :log error ("FleetUpgrade: stage=init attempt=0 reason=script lookup failed")
    :error "FleetUpgrade: script lookup failed"
}
:if ([:len $scriptId] != 1) do={
    :log error ("FleetUpgrade: stage=init attempt=0 reason=expected exactly one script named " . $scriptName)
    :error "FleetUpgrade: script object missing or duplicated"
}

# Create or normalize one startup scheduler. interval=0s means
# startup-only, avoiding a periodic retry/reboot loop.
:local schedulerId ""
:do {
    :set schedulerId [/system scheduler find where name=$schedulerName]
} on-error={
    :log error ("FleetUpgrade: stage=init attempt=0 reason=scheduler lookup failed")
    :error "FleetUpgrade: scheduler lookup failed"
}
:if ([:len $schedulerId] > 1) do={
    :log error ("FleetUpgrade: stage=init attempt=0 reason=duplicate startup schedulers")
    :error "FleetUpgrade: duplicate startup schedulers"
}
:do {
    :if ([:len $schedulerId] = 0) do={
        /system scheduler add name=$schedulerName start-time=startup interval=0s \
            on-event=("/system script run " . $scriptName) \
            policy=ftp,reboot,read,write,policy,test disabled=no
        :set schedulerId [/system scheduler find where name=$schedulerName]
    } else={
        /system scheduler set $schedulerId start-time=startup interval=0s \
            on-event=("/system script run " . $scriptName) \
            policy=ftp,reboot,read,write,policy,test disabled=no
    }
} on-error={
    :log error ("FleetUpgrade: stage=init attempt=0 reason=scheduler create/update failed")
    :error "FleetUpgrade: startup scheduler unavailable"
}
:if ([:len $schedulerId] != 1) do={
    :log error ("FleetUpgrade: stage=init attempt=0 reason=scheduler verification failed")
    :error "FleetUpgrade: startup scheduler verification failed"
}

# Wait at most five minutes for routing/server reachability.
:local serverReachable false
:local reachAttempt 0
:while (($serverReachable = false) && ($reachAttempt < $reachabilityAttempts)) do={
    :set reachAttempt ($reachAttempt + 1)
    :do {
        :if ([/ping address=$serverIP count=2 interval=1s] > 0) do={
            :set serverReachable true
        }
    } on-error={
        :set serverReachable false
    }
    :if ($serverReachable = false) do={ :delay 5s }
}
:if ($serverReachable = false) do={
    :log error ("FleetUpgrade: stage=metadata attempt=" . $reachAttempt . \
        " reason=package server unreachable; no reboot")
    :error "FleetUpgrade: package server unreachable"
}

# Remove stale metadata; a remove failure is unsafe because stale
# contents could otherwise be mistaken for the authoritative target.
:do {
    :local staleMeta [/file find where name=$versionMetaFile]
    :if ([:len $staleMeta] > 0) do={ /file remove $staleMeta }
    :if ([:len [/file find where name=$versionMetaFile]] > 0) do={
        :error "stale metadata remains"
    }
} on-error={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=stale metadata cleanup failed")
    :error "FleetUpgrade: metadata cleanup failed"
}

:local versionUrl ($baseUrl . "version")
:do {
    /tool fetch url=$versionUrl mode=http dst-path=$versionMetaFile keep-result=yes
} on-error={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=target fetch failed url=" . $versionUrl)
    :error "FleetUpgrade: target fetch failed"
}

:local versionMetaId ""
:local versionMetaSize 0
:local targetRaw ""
:do {
    :set versionMetaId [/file find where name=$versionMetaFile]
    :if ([:len $versionMetaId] != 1) do={ :error "metadata file missing or duplicated" }
    :set versionMetaSize [/file get $versionMetaId size]
    :if ($versionMetaSize = 0) do={ :error "metadata file empty" }
    :set targetRaw [/file get $versionMetaId contents]
} on-error={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=target file read/size verification failed")
    :error "FleetUpgrade: target metadata unavailable"
}

# Trim ASCII whitespace at both edges.
:local targetVersion $targetRaw
:local trimming true
:while ($trimming) do={
    :local n [:len $targetVersion]
    :if ($n = 0) do={
        :set trimming false
    } else={
        :local c [:pick $targetVersion 0 1]
        :if (($c = " ") || ($c = "\t") || ($c = "\r") || ($c = "\n")) do={
            :set targetVersion [:pick $targetVersion 1 $n]
        } else={ :set trimming false }
    }
}
:set trimming true
:while ($trimming) do={
    :local n [:len $targetVersion]
    :if ($n = 0) do={
        :set trimming false
    } else={
        :local c [:pick $targetVersion ($n - 1) $n]
        :if (($c = " ") || ($c = "\t") || ($c = "\r") || ($c = "\n")) do={
            :set targetVersion [:pick $targetVersion 0 ($n - 1)]
        } else={ :set trimming false }
    }
}

# Strictly accept digits.digits.digits only. Character validation is
# required because :tonum alone may accept ambiguous input.
:local tDot1 [:find $targetVersion "."]
:if ([:typeof $tDot1] = "nil") do={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=target is not major.minor.patch value=" . $targetVersion)
    :error "FleetUpgrade: malformed target metadata"
}
:local tDot2 [:find $targetVersion "." ($tDot1 + 1)]
:if ([:typeof $tDot2] = "nil") do={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=target is not major.minor.patch value=" . $targetVersion)
    :error "FleetUpgrade: malformed target metadata"
}
:local targetParts {[:pick $targetVersion 0 $tDot1];[:pick $targetVersion ($tDot1 + 1) $tDot2];[:pick $targetVersion ($tDot2 + 1) [:len $targetVersion]]}
:local targetDigitsOk true
:foreach part in=$targetParts do={
    :if ([:len $part] = 0) do={
        :set targetDigitsOk false
    } else={
        :for i from=0 to=([:len $part] - 1) do={
            :local c [:pick $part $i ($i + 1)]
            :if ([:typeof [:find "0123456789" $c]] = "nil") do={ :set targetDigitsOk false }
        }
    }
}
:if ($targetDigitsOk = false) do={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=target contains non-digits value=" . $targetVersion)
    :error "FleetUpgrade: malformed target metadata"
}
:local targetMajor [:tonum [:pick $targetVersion 0 $tDot1]]
:local targetMinor [:tonum [:pick $targetVersion ($tDot1 + 1) $tDot2]]
:local targetPatch [:tonum [:pick $targetVersion ($tDot2 + 1) [:len $targetVersion]]]
:if (([:typeof $targetMajor] = "nil") || ([:typeof $targetMinor] = "nil") || \
    ([:typeof $targetPatch] = "nil")) do={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=target numeric conversion failed value=" . $targetVersion)
    :error "FleetUpgrade: malformed target metadata"
}
:if (($targetMajor != $requiredTargetMajor) || ($targetMinor < 0) || ($targetPatch < 0)) do={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=unsupported target policy value=" . $targetVersion)
    :error "FleetUpgrade: target must be a RouterOS v7 major.minor.patch"
}
:do {
    /file remove $versionMetaId
    :if ([:len [/file find where name=$versionMetaFile]] > 0) do={ :error "metadata remains" }
} on-error={
    :log error ("FleetUpgrade: stage=metadata attempt=0 reason=metadata cleanup after parse failed")
    :error "FleetUpgrade: target metadata cleanup failed"
}
:log info ("FleetUpgrade: stage=metadata attempt=0 target=" . $targetVersion . " verified")

# Read and strictly parse the installed stable version.
:local versionRaw ""
:local arch ""
:local ram 0
:local freeHdd 0
:do {
    :set versionRaw [/system resource get version]
    :set arch [/system resource get architecture-name]
    :set ram [/system resource get total-memory]
    :set freeHdd [/system resource get free-hdd-space]
} on-error={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=resource read failed")
    :error "FleetUpgrade: resource inventory failed"
}
:local version $versionRaw
:local versionEnd [:find $versionRaw " "]
:if ([:typeof $versionEnd] != "nil") do={ :set version [:pick $versionRaw 0 $versionEnd] }
:local dot1 [:find $version "."]
:if ([:typeof $dot1] = "nil") do={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=installed version malformed value=" . $versionRaw)
    :error "FleetUpgrade: installed version malformed"
}
:local dot2 [:find $version "." ($dot1 + 1)]
:if ([:typeof $dot2] = "nil") do={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=installed version malformed value=" . $versionRaw)
    :error "FleetUpgrade: installed version malformed"
}
:local installedParts {[:pick $version 0 $dot1];[:pick $version ($dot1 + 1) $dot2];[:pick $version ($dot2 + 1) [:len $version]]}
:local installedDigitsOk true
:foreach part in=$installedParts do={
    :if ([:len $part] = 0) do={
        :set installedDigitsOk false
    } else={
        :for i from=0 to=([:len $part] - 1) do={
            :local c [:pick $part $i ($i + 1)]
            :if ([:typeof [:find "0123456789" $c]] = "nil") do={ :set installedDigitsOk false }
        }
    }
}
:if ($installedDigitsOk = false) do={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=installed version is not numeric major.minor.patch value=" . $versionRaw)
    :error "FleetUpgrade: installed version malformed"
}
:local major [:tonum [:pick $version 0 $dot1]]
:local minor [:tonum [:pick $version ($dot1 + 1) $dot2]]
:local patch [:tonum [:pick $version ($dot2 + 1) [:len $version]]]
:if (([:typeof $major] = "nil") || ([:typeof $minor] = "nil") || \
    ([:typeof $patch] = "nil")) do={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=installed numeric conversion failed value=" . $versionRaw)
    :error "FleetUpgrade: installed version malformed"
}
:if (($major != $v6Major) && ($major != $requiredTargetMajor)) do={
    :log error ("FleetUpgrade: stage=policy attempt=0 reason=unsupported installed major value=" . $version)
    :error "FleetUpgrade: unsupported installed RouterOS major"
}

# RouterBOARD access is a prerequisite: this deployment intentionally
# excludes CHR/non-RouterBOARD systems rather than silently skipping it.
:local board ""
:local currentFirmware ""
:local upgradeFirmware ""
:do {
    :set board [/system routerboard get model]
    :set currentFirmware [/system routerboard get current-firmware]
    :set upgradeFirmware [/system routerboard get upgrade-firmware]
} on-error={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=RouterBOARD information unavailable")
    :error "FleetUpgrade: RouterBOARD prerequisite failed"
}
:if (($board = "") || ($currentFirmware = "") || ($upgradeFirmware = "")) do={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=empty RouterBOARD property")
    :error "FleetUpgrade: RouterBOARD inventory incomplete"
}
:log info ("FleetUpgrade: stage=inventory attempt=0 board=" . $board . \
    " architecture=" . $arch . " version=" . $version . " RAM=" . $ram . \
    " free-storage=" . $freeHdd . " current-firmware=" . $currentFirmware . \
    " upgrade-firmware=" . $upgradeFirmware)

# Parse this script's durable marker:
# FleetUpgrade:state=<stage>;expected=<value>;attempt=<number>
:local statePrefix "FleetUpgrade:state="
:local stateComment ""
:local stateOwned false
:local stateStage ""
:local stateExpected ""
:local stateAttempt 0
:do {
    :set stateComment [/system script get $scriptId comment]
} on-error={
    :log error ("FleetUpgrade: stage=state attempt=0 reason=marker read failed")
    :error "FleetUpgrade: durable marker read failed"
}
:if (([:len $stateComment] >= [:len $statePrefix]) && \
    ([:pick $stateComment 0 [:len $statePrefix]] = $statePrefix)) do={
    :set stateOwned true
    :local payload [:pick $stateComment [:len $statePrefix] [:len $stateComment]]
    :local expectedSep [:find $payload ";expected="]
    :if ([:typeof $expectedSep] = "nil") do={
        :log error ("FleetUpgrade: stage=state attempt=0 reason=malformed durable marker")
        :error "FleetUpgrade: malformed durable marker"
    }
    :local expectedStart ($expectedSep + 10)
    :local attemptSep [:find $payload ";attempt=" $expectedStart]
    :if ([:typeof $attemptSep] = "nil") do={
        :log error ("FleetUpgrade: stage=state attempt=0 reason=malformed durable marker")
        :error "FleetUpgrade: malformed durable marker"
    }
    :set stateStage [:pick $payload 0 $expectedSep]
    :set stateExpected [:pick $payload $expectedStart $attemptSep]
    :local attemptText [:pick $payload ($attemptSep + 9) [:len $payload]]
    :local attemptDigitsOk true
    :if ([:len $attemptText] = 0) do={
        :set attemptDigitsOk false
    } else={
        :for i from=0 to=([:len $attemptText] - 1) do={
            :local c [:pick $attemptText $i ($i + 1)]
            :if ([:typeof [:find "0123456789" $c]] = "nil") do={ :set attemptDigitsOk false }
        }
    }
    :if ($attemptDigitsOk = false) do={
        :log error ("FleetUpgrade: stage=state attempt=0 reason=invalid marker attempt")
        :error "FleetUpgrade: malformed durable marker"
    }
    :set stateAttempt [:tonum $attemptText]
    :if ([:typeof $stateAttempt] = "nil") do={
        :log error ("FleetUpgrade: stage=state attempt=0 reason=marker numeric conversion failed")
        :error "FleetUpgrade: invalid durable marker"
    }
    :if (($stateAttempt < 1) || (($stateStage != "pkg-v6-baseline") && \
        ($stateStage != "pkg-v7") && ($stateStage != "routerboard"))) do={
        :log error ("FleetUpgrade: stage=state attempt=" . $stateAttempt . " reason=invalid durable marker state=" . $stateStage)
        :error "FleetUpgrade: invalid durable marker"
    }
}

# Clear a marker only after observing the state it requested.
:local stateSucceeded false
:if ($stateOwned) do={
    :if (($stateStage = "pkg-v6-baseline") && \
        (($version = $stateExpected) || ($major = $requiredTargetMajor))) do={
        :set stateSucceeded true
    }
    :if (($stateStage = "pkg-v7") && ($version = $stateExpected)) do={
        :set stateSucceeded true
    }
    :if (($stateStage = "routerboard") && ($currentFirmware = $stateExpected)) do={
        :set stateSucceeded true
    }
    :if ($stateSucceeded) do={
        :do {
            /system script set $scriptId comment=""
            :if ([/system script get $scriptId comment] != "") do={ :error "marker remains" }
        } on-error={
            :log error ("FleetUpgrade: stage=" . $stateStage . " attempt=" . $stateAttempt . \
                " reason=successful-state marker clear failed")
            :error "FleetUpgrade: durable marker clear failed"
        }
        :log info ("FleetUpgrade: stage=" . $stateStage . " attempt=" . $stateAttempt . \
            " observed-success=" . $stateExpected)
        :set stateOwned false
        :set stateStage ""
        :set stateExpected ""
        :set stateAttempt 0
    }
}

# Select exactly one package stage or the at/above-target firmware path.
:local nextVersion ""
:local packageStage ""
:local atOrAboveTarget false
:if ($major = $v6Major) do={
    :if (($minor > $v6Minor) || (($minor = $v6Minor) && ($patch > $v6Patch))) do={
        :log error ("FleetUpgrade: stage=policy attempt=0 reason=v6 newer than baseline; downgrade prohibited version=" . $version)
        :error "FleetUpgrade: automatic v6 downgrade prohibited"
    }
    :if ($version = $v6Baseline) do={
        :set nextVersion $targetVersion
        :set packageStage "pkg-v7"
    } else={
        :set nextVersion $v6Baseline
        :set packageStage "pkg-v6-baseline"
    }
}
:if ($major = $requiredTargetMajor) do={
    :if (($minor > $targetMinor) || (($minor = $targetMinor) && ($patch >= $targetPatch))) do={
        :set atOrAboveTarget true
    } else={
        :set nextVersion $targetVersion
        :set packageStage "pkg-v7"
    }
}

# Inventory enabled packages only. Disabled/XA rows are intentionally
# excluded from both driver decisions and Extra package selection.
:local enabledPackages
:local needWireless false
:local needWifiQcom false
:local needWifiQcomAc false
:local needWifiWave2 false
:local v6IndividualLayout false
:do {
    :set enabledPackages [/system package find where disabled=no]
    :foreach p in=$enabledPackages do={
        :local pname [/system package get $p name]
        :if (($major = $v6Major) && ($pname = "system")) do={
            :local systemBundle [/system package get $p bundle]
            :if ([:len $systemBundle] = 0) do={ :set v6IndividualLayout true }
        }
        :if (($pname = "wireless") || ($pname = "wireless-cm2") || \
            ($pname = "wireless-fp") || ($pname = "wireless-rep")) do={
            :set needWireless true
        }
        :if ($pname = "wifi-qcom") do={ :set needWifiQcom true }
        :if ($pname = "wifi-qcom-ac") do={ :set needWifiQcomAc true }
        :if ($pname = "wifiwave2") do={ :set needWifiWave2 true }
    }
} on-error={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=enabled package inventory failed")
    :error "FleetUpgrade: package inventory failed"
}

# Wireless hardware detection, v6/v7 safe. The menu paths are compiled
# via :parse at run time so a missing /interface wifi (v6, or v7 without
# a qcom driver) or a missing /interface wireless (v7 without the
# wireless package) is a caught error, not a script-wide parse failure.
:local wirelessIfCount 0
:local wifiIfCount 0
:do {
    :local wlanCountCmd [:parse ":return [:len [/interface wireless find]]"]
    :set wirelessIfCount [$wlanCountCmd]
} on-error={ :set wirelessIfCount 0 }
:if ($major = $requiredTargetMajor) do={
    :do {
        :local wifiCountCmd [:parse ":return [:len [/interface wifi find]]"]
        :set wifiIfCount [$wifiCountCmd]
    } on-error={ :set wifiIfCount 0 }
}
:if ([:typeof $wirelessIfCount] != "num") do={ :set wirelessIfCount 0 }
:if ([:typeof $wifiIfCount] != "num") do={ :set wifiIfCount 0 }
:local hasWirelessHardware false
:if (($wirelessIfCount > 0) || ($wifiIfCount > 0)) do={ :set hasWirelessHardware true }
# On v6 an enabled wireless sub-package row (bundled or individual) is
# also evidence; radios may be absent from the interface list while the
# package is scheduled or the driver did not bind.
:if (($major = $v6Major) && $needWireless) do={ :set hasWirelessHardware true }
:log info ("FleetUpgrade: stage=inventory attempt=0 wireless-interfaces=" . $wirelessIfCount . \
    " wifi-interfaces=" . $wifiIfCount . " wireless-hardware=" . $hasWirelessHardware)

# Board key used by every model-list lookup: exact model first, then the
# model with a trailing "&<modem>" part and a trailing "-TC" removed.
:local boardKey $board
:local ampPos [:find $board "&"]
:if ([:typeof $ampPos] != "nil") do={ :set boardKey [:pick $board 0 $ampPos] }
:local boardKeyLen [:len $boardKey]
:if (($boardKeyLen > 3) && ([:pick $boardKey ($boardKeyLen - 3) $boardKeyLen] = "-TC")) do={
    :set boardKey [:pick $boardKey 0 ($boardKeyLen - 3)]
}

:if ($needWifiQcom && $needWifiQcomAc) do={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=both wifi-qcom and wifi-qcom-ac are enabled")
    :error "FleetUpgrade: conflicting enabled wireless packages"
}
:local wirelessPackage ""
:if ($needWifiQcom) do={ :set wirelessPackage "wifi-qcom" }
:if ($needWifiQcomAc) do={ :set wirelessPackage "wifi-qcom-ac" }

# Enabled wifiwave2 without an explicit split driver: resolve the v7
# driver from the board model maps. Manual NPK installation does not
# convert wifiwave2 automatically, so an unmapped board must stop.
:if (($wirelessPackage = "") && $needWifiWave2) do={
    :if ($targetMinor < $wifiSplitMinor) do={
        :log error ("FleetUpgrade: stage=inventory attempt=0 reason=wifiwave2 split mapping requires target 7." . \
            $wifiSplitMinor . " or newer target=" . $targetVersion . " board=" . $board)
        :error "FleetUpgrade: wifiwave2 target below split release"
    }
    :local inAcMap false
    :local inAxMap false
    :local matchedKey ""
    :foreach m in=$wifiQcomAcModels do={
        :if (($m != "") && ($m = $board)) do={
            :set inAcMap true
            :set matchedKey $m
        }
    }
    :foreach m in=$wifiQcomModels do={
        :if (($m != "") && ($m = $board)) do={
            :set inAxMap true
            :set matchedKey $m
        }
    }
    :if (($inAcMap = false) && ($inAxMap = false)) do={
        :if ($boardKey != $board) do={
            :foreach m in=$wifiQcomAcModels do={
                :if (($m != "") && ($m = $boardKey)) do={
                    :set inAcMap true
                    :set matchedKey $m
                }
            }
            :foreach m in=$wifiQcomModels do={
                :if (($m != "") && ($m = $boardKey)) do={
                    :set inAxMap true
                    :set matchedKey $m
                }
            }
        }
    }
    :if ($inAcMap && $inAxMap) do={
        :log error ("FleetUpgrade: stage=inventory attempt=0 reason=board listed in both wifiQcomAcModels and wifiQcomModels board=" . $board)
        :error "FleetUpgrade: wifiwave2 mapping conflict"
    }
    :if ($inAcMap) do={ :set wirelessPackage "wifi-qcom-ac" }
    :if ($inAxMap) do={ :set wirelessPackage "wifi-qcom" }
    :if ($wirelessPackage = "") do={
        :log error ("FleetUpgrade: stage=inventory attempt=0 reason=wifiwave2 requires board-specific v7 split mapping; add board to wifiQcomAcModels or wifiQcomModels board=" . $board)
        :error "FleetUpgrade: unmapped wifiwave2 migration"
    }
    :log info ("FleetUpgrade: stage=inventory attempt=0 wifiwave2 mapped board=" . $board . \
        " package=" . $wirelessPackage . " match=" . $matchedKey)
}
# wireless and wifi-qcom/wifi-qcom-ac cannot be active together; the
# split driver wins and the legacy NPK is not requested for v7.
:if (($wirelessPackage != "") && $needWireless) do={
    :log warning ("FleetUpgrade: stage=inventory attempt=0 reason=legacy wireless enabled alongside " . \
        $wirelessPackage . "; wireless NPK not requested for v7 board=" . $board)
}
:if (($wirelessPackage = "") && $needWireless) do={ :set wirelessPackage "wireless" }

# Radios present but no driver package resolved: on RouterOS v6 the
# driver is inside the routeros bundle, and a v7 device may have lost
# its driver row. Without a driver NPK the v7 target set would boot
# with no WiFi. Default to legacy wireless so /interface wireless
# configuration and CAPsMAN v1 survive; wifi-qcom-ac only on request.
:local wirelessFromHardware false
:if (($wirelessPackage = "") && $hasWirelessHardware && ($packageStage = "pkg-v7")) do={
    :set wirelessPackage "wireless"
    :set wirelessFromHardware true
    :if ($preferQcomAcOnJump) do={
        :local inAcMapHw false
        :foreach m in=$wifiQcomAcModels do={
            :if (($m != "") && (($m = $board) || ($m = $boardKey))) do={ :set inAcMapHw true }
        }
        :if ($inAcMapHw) do={
            :if ($arch != "arm") do={
                :log error ("FleetUpgrade: stage=inventory attempt=0 reason=preferQcomAcOnJump selected wifi-qcom-ac but it is arm-only architecture=" . \
                    $arch . " board=" . $board)
                :error "FleetUpgrade: wifi-qcom-ac unavailable for architecture"
            }
            :if ($targetMinor < $wifiSplitMinor) do={
                :log error ("FleetUpgrade: stage=inventory attempt=0 reason=preferQcomAcOnJump requires target 7." . \
                    $wifiSplitMinor . " or newer target=" . $targetVersion . " board=" . $board)
                :error "FleetUpgrade: wifi-qcom-ac target below split release"
            }
            :set wirelessPackage "wifi-qcom-ac"
            :log warning ("FleetUpgrade: stage=inventory attempt=0 reason=preferQcomAcOnJump selected wifi-qcom-ac; " . \
                "/interface wireless configuration and CAPsMAN v1 will not migrate board=" . $board)
        }
    }
    :log info ("FleetUpgrade: stage=inventory attempt=0 wireless hardware without enabled driver package; v7 package=" . \
        $wirelessPackage . " board=" . $board . " preferQcomAcOnJump=" . $preferQcomAcOnJump)
}
:if (($wirelessPackage = "") && $hasWirelessHardware && ($packageStage = "pkg-v7")) do={
    :log error ("FleetUpgrade: stage=inventory attempt=0 reason=wireless hardware detected but no wireless NPK could be resolved board=" . \
        $board . " architecture=" . $arch)
    :error "FleetUpgrade: wireless driver resolution failed"
}

# At/above target: never install packages. Firmware alignment may be an
# upgrade or downgrade. The same expected firmware can reboot at most
# maxStageAttempts times without observed convergence.
:if ($atOrAboveTarget) do={
    :log info ("FleetUpgrade: stage=routerboard attempt=0 RouterOS=" . $version . \
        " target=" . $targetVersion . " package installation skipped")
    :if ($currentFirmware = $upgradeFirmware) do={
        :if ($stateOwned) do={
            :log error ("FleetUpgrade: stage=" . $stateStage . " attempt=" . $stateAttempt . \
                " reason=pending marker conflicts with converged at-target state")
            :error "FleetUpgrade: inconsistent durable marker"
        }
        :log info ("FleetUpgrade: stage=complete attempt=0 reason=RouterOS at/above target and RouterBOARD firmware aligned")
    } else={
        :local fwAttempt 1
        :if ($stateOwned) do={
            :if (($stateStage != "routerboard") || ($stateExpected != $upgradeFirmware)) do={
                :log error ("FleetUpgrade: stage=" . $stateStage . " attempt=" . $stateAttempt . \
                    " reason=pending marker does not match required firmware operation")
                :error "FleetUpgrade: inconsistent durable marker"
            }
            :set fwAttempt ($stateAttempt + 1)
        }
        :if ($fwAttempt > $maxStageAttempts) do={
            :log error ("FleetUpgrade: stage=routerboard attempt=" . $stateAttempt . \
                " reason=firmware did not converge current=" . $currentFirmware . \
                " expected=" . $upgradeFirmware . "; retry limit reached; no reboot")
            :error "FleetUpgrade: RouterBOARD convergence retry limit reached"
        }
        :local fwMarker ("FleetUpgrade:state=routerboard;expected=" . $upgradeFirmware . ";attempt=" . $fwAttempt)
        :do {
            /system script set $scriptId comment=$fwMarker
            :if ([/system script get $scriptId comment] != $fwMarker) do={ :error "marker mismatch" }
        } on-error={
            :log error ("FleetUpgrade: stage=routerboard attempt=" . $fwAttempt . " reason=marker persistence failed; no reboot")
            :error "FleetUpgrade: firmware marker persistence failed"
        }
        :do {
            /system routerboard upgrade
        } on-error={
            :log error ("FleetUpgrade: stage=routerboard attempt=" . $fwAttempt . \
                " reason=RouterBOARD upgrade command failed; no reboot")
            :error "FleetUpgrade: RouterBOARD upgrade failed"
        }
        :log warning ("FleetUpgrade: stage=routerboard attempt=" . $fwAttempt . \
            " action=reboot current=" . $currentFirmware . " expected=" . $upgradeFirmware)
        :delay 5s
        :do { /system reboot } on-error={
            :log error ("FleetUpgrade: stage=routerboard attempt=" . $fwAttempt . " reason=reboot command failed")
            :error "FleetUpgrade: reboot command failed"
        }
    }
} else={
    # Package path prerequisites.
    :if (($nextVersion = "") || ($packageStage = "")) do={
        :log error ("FleetUpgrade: stage=policy attempt=0 reason=no valid next package stage")
        :error "FleetUpgrade: package stage selection failed"
    }
    :if ($ram < $minRam) do={
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=0 reason=insufficient RAM bytes=" . $ram)
        :error "FleetUpgrade: insufficient RAM"
    }
    :if ($freeHdd < $minFreeHdd) do={
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=0 reason=insufficient free storage bytes=" . \
            $freeHdd . " required=" . $minFreeHdd)
        :error "FleetUpgrade: insufficient free storage"
    }
    :if (($arch != "arm") && ($arch != "arm64") && ($arch != "mipsbe") && \
        ($arch != "mmips") && ($arch != "smips") && ($arch != "tile") && \
        ($arch != "powerpc") && ($arch != "ppc") && ($arch != "x86")) do={
        :log error ("FleetUpgrade: stage=" . $packageStage . \
            " attempt=0 reason=unsupported package architecture value=" . $arch)
        :error "FleetUpgrade: unsupported package architecture"
    }

    :local stageAttempt 1
    :if ($stateOwned) do={
        :if (($stateStage != $packageStage) || ($stateExpected != $nextVersion)) do={
            :log error ("FleetUpgrade: stage=" . $stateStage . " attempt=" . $stateAttempt . \
                " reason=pending package marker conflicts with selected stage=" . $packageStage . \
                " expected=" . $nextVersion)
            :error "FleetUpgrade: inconsistent durable marker"
        }
        :set stageAttempt ($stateAttempt + 1)
    }
    :if ($stageAttempt > $maxStageAttempts) do={
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stateAttempt . \
            " reason=installed version did not reach " . $nextVersion . \
            "; retry limit reached; no reboot")
        :error "FleetUpgrade: package stage retry limit reached"
    }

    # v6 bundle: routeros-arch-version.npk
    # v6 individual/Extra and v7: name-version-arch.npk
    # RouterOS v6 reports powerpc; Extra/v7 repositories use ppc.
    :local v7NpkNaming true
    :if ($packageStage = "pkg-v6-baseline") do={ :set v7NpkNaming false }
    :local packageArch $arch
    :if ($packageArch = "powerpc") do={ :set packageArch "ppc" }
    :local extraArchSuffix ("-" . $packageArch)
    :if ($packageArch = "x86") do={ :set extraArchSuffix "" }
    :local rosNpk ""
    :if ($v7NpkNaming) do={
        :set rosNpk ("routeros-" . $nextVersion . $extraArchSuffix . ".npk")
    } else={
        :if ($v6IndividualLayout) do={
            :set rosNpk ("system-" . $nextVersion . $extraArchSuffix . ".npk")
        } else={
            :set rosNpk ("routeros-" . $arch . "-" . $nextVersion . ".npk")
        }
    }
    :local files {$rosNpk}
    :local optionalPackages
    :if ($v7NpkNaming) do={
        :set optionalPackages {"calea";"container";"dude";"extra-nic";"gps";"iot";"iot-bt-extra";"lora";"lte";"openflow";"rose-storage";"switch-marvell";"tr069-client";"ups";"user-manager";"wifi-halow-mm";"wifi-mediatek";"wifi-qcom";"wifi-qcom-ac";"wifi-qcom-be";"wireless";"zerotier"}
    } else={
        :if ($v6IndividualLayout) do={
            # Preserve all enabled known individual v6 components.
            :set optionalPackages {"advanced-tools";"calea";"dhcp";"dude";"gps";"hotspot";"iot";"ipv6";"kvm";"lcd";"lora";"lte";"mpls";"multicast";"ntp";"openflow";"ppp";"routing";"security";"tr069-client";"ups";"user-manager";"wireless"}
        } else={
            # The v6 routeros bundle already carries normal component
            # rows; append only separately distributed Extras.
            :set optionalPackages {"calea";"dude";"gps";"iot";"lora";"lte";"tr069-client";"ups";"user-manager"}
        }
    }

    :local wantWirelessNpk false
    :if ($v7NpkNaming) do={
        :if ($wirelessPackage != "") do={ :set wantWirelessNpk true }
        # Before 7.13 legacy wireless ships inside the routeros bundle and
        # no wireless-<ver>-<arch>.npk exists.
        :if (($wirelessPackage = "wireless") && ($targetMinor < $wifiSplitMinor)) do={
            :set wantWirelessNpk false
            :log info ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
                " package=wireless is bundled in routeros before 7." . $wifiSplitMinor . "; no NPK constructed")
        }
        :if ($wantWirelessNpk && $wirelessFromHardware) do={
            :log info ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
                " package=" . $wirelessPackage . " selected from wireless hardware detection")
        }
    } else={
        :if ($needWireless && $v6IndividualLayout) do={
            :set wantWirelessNpk true
            :set wirelessPackage "wireless"
        }
    }
    :if ($wantWirelessNpk) do={
        :set files ($files , ($wirelessPackage . "-" . $nextVersion . $extraArchSuffix . ".npk"))
    }
    # wifiwave2 has no NPK from 7.13 on; it is superseded by the resolved
    # split driver and is never constructed as an Extra below.
    :if ($v7NpkNaming && $needWifiWave2) do={
        :log info ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
            " package=wifiwave2 superseded by " . $wirelessPackage . "; no wifiwave2 NPK constructed")
    }

    # Include every enabled package in the known separate-Extra set.
    :do {
        :foreach p in=$enabledPackages do={
            :local pname [/system package get $p name]
            :local isWirelessFamily (($pname = "wireless") || ($pname = "wireless-cm2") || \
                ($pname = "wireless-fp") || ($pname = "wireless-rep") || \
                ($pname = "wifi-qcom") || ($pname = "wifi-qcom-ac") || ($pname = "wifiwave2"))
            :if (($pname != "routeros") && ($pname != "system") && ($isWirelessFamily = false)) do={
                :local isOptional false
                :foreach opt in=$optionalPackages do={
                    :if ($opt = $pname) do={ :set isOptional true }
                }
                :if ($isOptional) do={
                    :local candidate ""
                    :set candidate ($pname . "-" . $nextVersion . $extraArchSuffix . ".npk")
                    :local already false
                    :foreach existing in=$files do={
                        :if ($existing = $candidate) do={ :set already true }
                    }
                    :if ($already = false) do={ :set files ($files , $candidate) }
                } else={
                    :log info ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
                        " package=" . $pname . " is bundled/non-downloadable; no NPK constructed")
                }
            }
        }
    } on-error={
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
            " reason=package list construction failed")
        :error "FleetUpgrade: package list construction failed"
    }

    :local fileList ""
    :foreach fn in=$files do={
        :if ($fileList = "") do={ :set fileList $fn } else={ :set fileList ($fileList . "," . $fn) }
    }
    :log info ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
        " packages=" . $fileList)

    # Any unrelated root/file-tree NPK could also be consumed on reboot.
    # Halt rather than silently installing an artifact outside this set.
    :do {
        :foreach f in=[/file find] do={
            :local existingName [/file get $f name]
            :local existingLen [:len $existingName]
            :if (($existingLen >= 4) && \
                ([:pick $existingName ($existingLen - 4) $existingLen] = ".npk")) do={
                :local selected false
                :foreach fn in=$files do={
                    :if ($existingName = $fn) do={ :set selected true }
                }
                :if ($selected = false) do={ :error ("unexpected NPK " . $existingName) }
            }
        }
    } on-error={
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
            " reason=unexpected or unreadable NPK exists; no reboot")
        :error "FleetUpgrade: unmanaged NPK present"
    }

    # Download directly to the final .npk name. RouterOS v6 cannot rename
    # files, so a staging name is not possible; instead every selected
    # NPK is removed again if any download fails, so a partial set is
    # never left behind for a later reboot to install.
    :local downloadFailed false
    :local downloadedBytes 0
    :foreach fn in=$files do={
        :local url ($baseUrl . $fn)
        :do {
            :local beforeFree [/system resource get free-hdd-space]
            :if ($beforeFree < $minFreeHdd) do={ :error "free-storage reserve breached" }
            :local stale [/file find where name=$fn]
            :if ([:len $stale] > 0) do={ /file remove $stale }
            :if ([:len [/file find where name=$fn]] > 0) do={ :error "stale package remains" }
            /tool fetch url=$url mode=http dst-path=$fn keep-result=yes
            :local downloaded [/file find where name=$fn]
            :if ([:len $downloaded] != 1) do={ :error "downloaded package missing or duplicated" }
            :local downloadedSize [/file get $downloaded size]
            :if ($downloadedSize = 0) do={ :error "downloaded package is zero bytes" }
            :set downloadedBytes ($downloadedBytes + $downloadedSize)
        } on-error={
            :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
                " reason=download/remove/verify failed file=" . $fn)
            :set downloadFailed true
        }
    }
    :if ($downloadFailed) do={
        :do {
            :foreach fn in=$files do={
                :local failedFile [/file find where name=$fn]
                :if ([:len $failedFile] > 0) do={ /file remove $failedFile }
                :if ([:len [/file find where name=$fn]] > 0) do={ :error ("package remains " . $fn) }
            }
        } on-error={
            :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
                " reason=failed-set cleanup incomplete; installable NPK may remain; no reboot")
            :error "FleetUpgrade: failed-set cleanup failed"
        }
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
            " reason=one or more packages failed verification; no reboot")
        :error "FleetUpgrade: package verification failed"
    }

    :local stageMarker ("FleetUpgrade:state=" . $packageStage . ";expected=" . \
        $nextVersion . ";attempt=" . $stageAttempt)
    :do {
        /system script set $scriptId comment=$stageMarker
        :if ([/system script get $scriptId comment] != $stageMarker) do={ :error "marker mismatch" }
    } on-error={
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
            " reason=marker persistence failed; no reboot")
        :error "FleetUpgrade: package marker persistence failed"
    }

    :log warning ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
        " action=reboot expected=" . $nextVersion . " downloaded-bytes=" . $downloadedBytes)
    :delay 5s
    :do { /system reboot } on-error={
        :log error ("FleetUpgrade: stage=" . $packageStage . " attempt=" . $stageAttempt . \
            " reason=reboot command failed")
        :error "FleetUpgrade: reboot command failed"
    }
}
