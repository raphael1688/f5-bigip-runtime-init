#!/bin/bash -x

# Note that initial autogenerated password should only be temporary as
# the password will be cached by tfstate, in cloud-drive, and initially on the device
# Not recommended for production.
# Recommend changing password immediately 
# For production, F5 also recommends customizing the Runtime-Init Config in startup-script.tpl 
# to using Hashicorp Vault to fetch the secret/password
# See https://github.com/F5Networks/f5-bigip-runtime-init#runtime_parameters

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
/usr/bin/setdb provision.extramb 1000 || true
/usr/bin/setdb restjavad.useextramb true || true
/usr/bin/setdb iapplxrpm.timeout 300 || true
/usr/bin/setdb icrd.timeout 180 || true
/usr/bin/setdb restjavad.timeout 180 || true
/usr/bin/setdb restnoded.timeout 180 || true

# Download or Render BIG-IP Runtime Init Config
cat << 'EOF' > /config/cloud/runtime-init-conf.yaml
---
controls:
  logLevel: silly
  logFilename: /var/log/cloud/bigIpRuntimeInit.log
pre_onboard_enabled: []
runtime_parameters:
  - name: ADMIN_USER
    type: static
    value: ${admin_username}
  - name: ADMIN_PASS
    type: static
    value: ${admin_password}
  - name: HOST_NAME
    type: static
    value: ${hostname}
  - name: LICENSE_KEY
    type: static
    value: ${license_key}
  - name: MGMT_GW
    type: static
    value: ${mgmt_gateway}
  - name: METADATA_ROUTE
    type: static
    value: ${metadata_route}
  - name: SELF_IP_EXTERNAL
    type: static
    value: "${self_ip_external}/${self_ip_external_prefix}"
  - name: SELF_IP_INTERNAL
    type: static
    value: "${self_ip_internal}/${self_ip_internal_prefix}"
  - name: DEFAULT_GW
    type: static
    value: ${default_gateway}
bigip_ready_enabled: []
extension_packages:
  install_operations:
    - extensionType: do
      extensionVersion: 1.37.0
      extensionHash: 25dd5256f9fa563e9b2ef9df228d5b01df1aef6b143d7e1c7b9daac822fb91ef
    - extensionType: as3
      extensionVersion: 3.44.0
      extensionHash: 78ecc5a0d3d6410dabb8cc2a80d3a7287a524b6f7ad4c8ff2c83f11947f597db
    - extensionType: ts
      extensionVersion: 1.33.0
      extensionHash: 573d8cf589d545b272250ea19c9c124cf8ad5bcdd169dbe2139e82ce4d51a449
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
            ui.advisory.enabled: true
            ui.advisory.color: blue
            ui.advisory.text: BIG-IP VE Runtime Init Example
            config.allow.rfc3927: enable
            dhclient.mgmt: disable
            kernel.pti: disable
            systemauth.disablerootlogin: true
          My_System:
            class: System
            hostname: '{{{HOST_NAME}}}'
            cliInactivityTimeout: 1200
            consoleInactivityTimeout: 1200
            autoPhonehome: true
          My_Dns:
            class: DNS
            nameServers:
              - 8.8.8.8
          My_Ntp:
            class: NTP
            servers:
              - pool.ntp.org
            timezone: UTC
          My_License:
            class: License
            licenseType: regKey
            regKey: '{{{LICENSE_KEY}}}'
          My_Provisioning:
            class: Provision
            ltm: nominal
          '{{{ADMIN_USER}}}':
            class: User
            userType: regular
            partitionAccess:
              all-partitions:
                role: admin
            password: '{{{ADMIN_PASS}}}'
            shell: bash
          default:
            class: ManagementRoute
            gw: '{{{MGMT_GW}}}'
            network: default
          cloudMetadata:
            class: ManagementRoute
            gw: '{{{METADATA_ROUTE}}}'
            network: 169.254.169.254/32
          external:
            class: VLAN
            tag: 4094
            mtu: 1460
            interfaces:
              - name: '1.1'
                tagged: false
          internal:
            class: VLAN
            tag: 4093
            mtu: 1460
            interfaces:
              - name: '1.2'
                tagged: false
          external-self:
            class: SelfIp
            address: '{{{SELF_IP_EXTERNAL}}}'
            vlan: external
            allowService: default
            trafficGroup: traffic-group-local-only
          internal-self:
            class: SelfIp
            address: '{{{SELF_IP_INTERNAL}}}'
            vlan: internal
            allowService: default
            trafficGroup: traffic-group-local-only
          default_gateway:
            class: Route
            gw: '{{{DEFAULT_GW}}}'
            mtu: 1460
            network: default
post_onboard_enabled: []
EOF

# Download
for i in {1..30}; do
    curl -fv --retry 1 --connect-timeout 5 -L "${package_url}" -o "/var/config/rest/downloads/f5-bigip-runtime-init.gz.run" && break || sleep 10
done
# Install
bash /var/config/rest/downloads/f5-bigip-runtime-init.gz.run -- "--telemetry-params templateName:f5-bigip-runtime-init/examples/terraform/openstack/main.tf"
# Run
f5-bigip-runtime-init --config-file /config/cloud/runtime-init-conf.yaml

# Cloud-Init usually does this if Datasource = Openstack but for BIG-IP
# Manually Grab SSH KEY associated with VM from metadata
# Requires metadata route first be installed from DO declaration above
mkdir -p /home/${admin_username}/.ssh/ && echo $(curl http://169.254.169.254/2009-04-04/meta-data/public-keys/0/openssh-key) >> /home/${admin_username}/.ssh/authorized_keys