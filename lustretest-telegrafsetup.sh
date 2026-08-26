#!/bin/bash

CONFIG=$(cat << 'EOF'
[agent]
  interval = "1s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "1s"
  flush_jitter = "1s"
  precision = "0s"
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

[[inputs.diskio]]
EOF
)

pdsh -w "lustretest-ost[0-23],lustretest-mgs" "sudo dnf remove telegraf -y; sudo dnf install telegraf -y; echo -n | sudo tee /etc/telegraf/telegraf.conf; echo '$CONFIG' | sudo tee /etc/telegraf/telegraf.conf > /dev/null && sudo systemctl restart telegraf"
