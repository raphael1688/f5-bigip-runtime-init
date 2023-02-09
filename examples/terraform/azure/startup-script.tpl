#!/bin/bash -x

# NOTE: Startup Script is run once / initialization only (Cloud-Init behavior vs. typical re-entrant for Azure Custom Script Extension )
# For 15.1+ and above, Cloud-Init will run the script directly and can remove Azure Custom Script Extension

# Send output to log file and serial console
mkdir -p  /var/log/cloud /config/cloud /var/config/rest/downloads
LOG_FILE=/var/log/cloud/startup-script.log
[[ ! -f $LOG_FILE ]] && touch $LOG_FILE || { echo "Run Only Once. Exiting"; exit; }
npipe=/tmp/$$.tmp
trap "rm -f $npipe" EXIT
mknod $npipe p
tee <$npipe -a $LOG_FILE /dev/ttyS0 &
exec 1>&-
exec 1>$npipe
exec 2>&1

# Run Immediately Before MCPD starts
/usr/bin/setdb provision.extramb 1000
/usr/bin/setdb restjavad.useextramb true

# Download or Render BIG-IP Runtime Init Config
cat << 'EOF' > /config/cloud/runtime-init-conf.yaml
---
controls:
  logLevel: silly
  logFilename: /var/log/cloud/bigIpRuntimeInit.log
pre_onboard_enabled: []
runtime_parameters:
    - name: ADMIN_PASS
      type: secret
      secretProvider:
        environment: azure
        type: KeyVault
        vaultUrl: 'https://${vault_name}.vault.azure.net'
        secretId: ${secret_id}
    - name: HOST_NAME
      type: metadata
      metadataProvider:
        environment: azure
        type: compute
        field: name
    - name: SELF_IP_EXTERNAL
      type: metadata
      metadataProvider:
        environment: azure
        type: network
        field: ipv4
        index: 1
    - name: SELF_IP_INTERNAL
      type: metadata
      metadataProvider:
        environment: azure
        type: network
        field: ipv4
        index: 2
    - name: DEFAULT_GW
      type: metadata
      metadataProvider:
        environment: azure
        type: network
        field: ipv4
        index: 1
        ipcalc: first
    - name: MGMT_GW
      type: metadata
      metadataProvider:
        environment: azure
        type: network
        field: ipv4
        index: 0
        ipcalc: first
bigip_ready_enabled: []
extension_packages:
  install_operations:
    - extensionType: do
      extensionVersion: 1.35.0
      extensionHash: 44df23fab10547d5cb0999689b2f9b2a01d7a82e616898b5ccd57172876d2793
    - extensionType: as3
      extensionVersion: 3.42.0
      extensionHash: dcb869775f00b2d1a4c8a7600beeb596a8da469caa7ddb30df02c4cdc48c37e2
    - extensionType: ts
      extensionVersion: 1.32.0
      extensionHash: a6bf242728a5ba1b8b8f26b59897765567db7e0f0267ba9973f822be3ab387b6
    - extensionType: fast
      extensionVersion: 1.23.0
      extensionHash: d2580309047ff379820460be09e5b7202fe287e7fc5ffaad65106233aeb6e845
extension_services:
  service_operations:
    - extensionType: do
      type: inline
      value:
        schemaVersion: 1.0.0
        class: Device
        async: true
        label: Example 3NIC BIG-IP with Runtime-Init
        Common:
          class: Tenant
          My_DbVariables:
            class: DbVariables
            provision.extramb: 1000
            restjavad.useextramb: true
            ui.advisory.enabled: true
            ui.advisory.color: blue
            ui.advisory.text: BIG-IP VE Runtime Init Example
            config.allow.rfc3927: enable
            dhclient.mgmt: disable
          My_System:
            class: System
            hostname: '{{{ HOST_NAME }}}.local'
            cliInactivityTimeout: 1200
            consoleInactivityTimeout: 1200
            autoPhonehome: true
          My_Dns:
            class: DNS
            nameServers:
             - 168.63.129.16
          My_Ntp:
            class: NTP
            servers:
              - 0.pool.ntp.org
            timezone: UTC
          My_Provisioning:
            class: Provision
            ltm: nominal
          admin:
            class: User
            userType: regular
            partitionAccess:
              all-partitions:
                role: admin
            password: '{{{ ADMIN_PASS }}}'
            shell: bash
          ${admin_username}:
            class: User
            userType: regular
            partitionAccess:
              all-partitions:
                role: admin
            password: '{{{ ADMIN_PASS }}}'
            shell: bash
          external:
            class: VLAN
            tag: 4094
            mtu: 1500
            interfaces:
              - name: '1.1'
                tagged: false
          internal:
            class: VLAN
            tag: 4093
            mtu: 1500
            interfaces:
              - name: '1.2'
                tagged: false
          default:
            class: ManagementRoute
            gw: '{{{ MGMT_GW }}}'
            network: default
          dhclient_route1:
            class: ManagementRoute
            gw: '{{{ MGMT_GW }}}'
            network: 168.63.129.16/32
          azureMetadata:
            class: ManagementRoute
            gw: '{{{ MGMT_GW }}}'
            network: 169.254.169.254/32
          external-self:
            class: SelfIp
            address: '{{{ SELF_IP_EXTERNAL }}}'
            vlan: external
            allowService: default
            trafficGroup: traffic-group-local-only
          internal-self:
            class: SelfIp
            address: '{{{ SELF_IP_INTERNAL }}}'
            vlan: internal
            allowService: default
            trafficGroup: traffic-group-local-only
          defaultRoute:
            class: Route
            gw: '{{{ DEFAULT_GW }}}'
            network: default
            mtu: 1500
post_onboard_enabled: []
EOF

# Download
for i in {1..30}; do
    curl -fv --retry 1 --connect-timeout 5 -L "${package_url}" -o "/var/config/rest/downloads/f5-bigip-runtime-init.gz.run" && break || sleep 10
done
# Install
bash /var/config/rest/downloads/f5-bigip-runtime-init.gz.run -- "--cloud azure --telemetry-params templateName:f5-bigip-runtime-init/examples/terraform/azure/main.tf"
# Run
f5-bigip-runtime-init --config-file /config/cloud/runtime-init-conf.yaml
