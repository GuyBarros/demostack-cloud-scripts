#!/usr/bin/env bash
set -e
echo "==> Disable UFW"
sudo systemctl stop ufw
sudo systemctl disable ufw

echo "==> Consul (servers)"
if [ ${enterprise} == 0 ]
then
echo "--> Fetching"
install_from_url "consul" "${consul_url}"
else
echo "--> Fetching"
install_from_url "consul" "${consul_ent_url}"
fi


echo "--> Writing configuration"
sudo mkdir -p /mnt/consul
sudo mkdir -p /etc/consul.d
sudo tee /etc/consul.d/config.json > /dev/null <<EOF
{
  "acl_datacenter": "dc1",
  "acl_master_token": "${consul_master_token}",
  "acl_token": "${consul_master_token}",
  "acl_default_policy": "allow",
  "advertise_addr": "${private_ip}",
  "advertise_addr_wan": "${public_ip}",
  "bootstrap_expect": ${consul_servers},
  "bind_addr": "$(private_ip)",
  "node_name": "${node_name}",
  "data_dir": "/mnt/consul",
  "disable_update_check": true,
  "encrypt": "${consul_gossip_key}",
  "leave_on_terminate": true,
  "raft_protocol": 3,
  "retry_join": ["provider=azure tag_name=${consul_join_tag_name}  tag_value=${consul_join_tag_value} tenant_id=${tenant_id} client_id=${client_id} subscription_id=${subscription_id} secret_access_key=${client_secret} "],

  "servers": true,
  "addresses": {
    "http": "0.0.0.0",
    "https": "$(private_ip)"
  },
  "ports": {
    "http": 8500,
    "https": 8533
  },
  "key_file": "/etc/ssl/certs/me.key",
  "cert_file": "/etc/ssl/certs/me.crt",
  "ca_file": "/usr/local/share/ca-certificates/01-me.crt",
  "verify_incoming": false,
  "verify_outgoing": false,
  "verify_servers_hostname": false,
  "ui": true,
 "connect":{
  "enabled": true,
      "proxy": {  "allow_managed_root": true  }
      }
}
EOF

echo "--> Writing profile"
sudo tee /etc/profile.d/consul.sh > /dev/null <<"EOF"
alias conslu="consul"
alias ocnsul="consul"
EOF
source /etc/profile.d/consul.sh

echo "--> Generating systemd configuration"
sudo tee /etc/systemd/system/consul.service > /dev/null <<"EOF"
[Unit]
Description=Consul
Documentation=https://www.consul.io/docs/
Requires=network-online.target
After=network-online.target

[Service]
Restart=on-failure
ExecStart=/usr/local/bin/consul agent -config-dir="/etc/consul.d"
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable consul
sudo systemctl restart consul

echo "--> Installing dnsmasq"
ssh-apt install dnsmasq
sudo tee /etc/dnsmasq.d/10-consul > /dev/null <<"EOF"
servers=/consul/127.0.0.1#8600
no-poll
servers=168.63.129.16
servers=1.1.1.1
cache-size=0
EOF
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

echo "--> Waiting for all Consul servers"
while [ "$(consul members 2>&1 | grep "servers" | grep "alive" | wc -l)" -lt "${consul_servers}" ]; do
  sleep 3
done

echo "--> Waiting for Consul leader"
while [ -z "$(curl -s http://127.0.0.1:8500/v1/status/leader)" ]; do
  sleep 3
done

if [ ${enterprise} == 1 ]
then
sudo consul license put "${consullicense}" > /tmp/consullicense.out


fi


echo "--> Registering prepared query"
curl -so /dev/null -X POST http://127.0.0.1:8500/v1/query \
  -d @- <<BODY
{
  "Name": "nearest-web",
  "Service": {
    "Service": "web",
    "Near": "_agent",
    "OnlyPassing": true
  }
}
BODY

echo "--> Denying anonymous access to vault/ and tmp/"
curl -so /dev/null -X PUT http://127.0.0.1:8500/v1/acl/update \
  -H "X-Consul-Token: ${consul_master_token}" \
  -d @- <<BODY
{
  "ID": "anonymous",
  "Rules": "key \"vault\" { policy = \"deny\" }\n\nkey \"tmp\" { policy = \"deny\" }"
}
BODY

echo "==> Consul is done!"
