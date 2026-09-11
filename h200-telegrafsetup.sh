#!/bin/bash

REPO=$(cat << 'EOF'
[influxdata]
name = InfluxData Repository - Stable
baseurl = https://repos.influxdata.com/rhel/$releasever/$basearch/stable
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdata-archive_compat.key
EOF
)

pdsh -g "H200&&office=kl" "echo -n | sudo tee /etc/yum.repos.d/influxdata.repo; echo '$REPO' | sudo tee /etc/yum.repos.d/influxdata.repo > /dev/null; sudo rpm --import https://repos.influxdata.com/influxdata-archive.key; sudo sed -i 's|influxdata-archive_compat.key|influxdata-archive.key|g' /etc/yum.repos.d/influxdata.repo; sudo dnf clean packages"

CONFIG=$(cat << 'EOF'
[agent]
  interval = "10s"         # Reset agent default back to standard
  round_interval = false
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "1s"    # Flush metrics to InfluxDB immediately when collected
  flush_jitter = "0s"
  precision = "1s"
  logfile = "/var/log/telegraf/telegraf.log"
  logfile_rotation_max_size = "200MB"
  logfile_rotation_max_archives = 5
  log_with_timezone = "local"
  hostname = ""
  omit_hostname = false

[[outputs.influxdb]]
  urls = ["http://lustretest-grafana:8086"]
  database = "lustretest"
  retention_policy = "ninety_days"

[[inputs.ipmi_sensor]]
  path = "/bin/ipmitool"
  use_sudo = true
  use_cache = true         # Caches Sensor Data Records to speed up ipmitool execution
  interval = "15s"         # Set to match actual ipmitool duration to eliminate log warnings
  timeout = "60s"          # Prevents killing ipmitool during slower polling runs
  metric_version = 2

[[inputs.sysstat]]
  sadc_path = "/usr/lib64/sa/sadc" # required
  [inputs.sysstat.options]
    -C = "cpu"
    -B = "paging"
    -b = "io"
    -d = "disk"             # requires DISK activity
    "-n ALL" = "network"
    -q = "queue"
    -r = "mem_util"
    -S = "swap_util"
    -u = "cpu_util"
    -W = "swap"
EOF
)

pdsh -g "H200&&office=kl" "sudo dnf remove telegraf -y; sudo dnf install telegraf -y; echo -n | sudo tee /etc/telegraf/telegraf.conf; echo '$CONFIG' | sudo tee /etc/telegraf/telegraf.conf > /dev/null && echo 'telegraf ALL=(ALL) NOPASSWD: /bin/ipmitool' | sudo tee /etc/sudoers.d/telegraf_ipmitool; sudo chmod 0440 /etc/sudoers.d/telegraf_ipmitool; sudo systemctl restart telegraf"
