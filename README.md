# MikrotikFleetUpgrade
MikroTik FleetUpgrade: production RouterOS v6→v7 bulk upgrader for large fleets. Fetches a remote target version, upgrades installed packages (incl. wifiwave2→wifi-qcom/wifi-qcom-ac board map), reconciles RouterBOARD firmware, stages NPKs atomically, and fail-closes with reboot-loop guards. Lab-validate before deploy.
