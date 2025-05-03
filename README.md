# Loki exporter for OpenWRT

This project provides a tiny service for exporting system logs from standard
[logd](https://openwrt.org/docs/guide-user/base-system/log.essentials#logd) daemon
to any external endpoint which is capable to receive Loki-compatible log streams
via HTTP/HTTPS.

Under the hood it's just a simple shell script that runs
[logread](https://openwrt.org/docs/guide-user/base-system/log.essentials#logread) client
in tailing mode, parses its output, composes payload, and sends it with the help
of [curl](https://curl.se) (this is the only dependency) to a configured endpoint.

It should be able to run on any [relatively modern] OpenWRT installation.
For the sake of clarity, I have been testing this mostly on OpenWRT 23.05.3 with BusyBox 1.36.1.
Thankfully, the ash shell bundled with BusyBox supports some
[bash-specific extensions](https://github.com/mirror/busybox/blob/1_36_1/shell/ash.c#L54-L57),
making it easier to test the script locally as well (bash 5.2+ worked fine to me so far).

# Why?

While there are plenty of other solutions available out there to do the same job, like
[promtail](https://grafana.com/docs/loki/latest/send-data/promtail/) or
[telegraf](https://github.com/influxdata/telegraf),
those are quite greedy in terms of resources, especially RAM.
This could be a major concern for limited hardware.

Shell script + dedicated instance of `logread` consume around 1 MB of RSS on one of my
QCA956X-based routers with 128 MB of total RAM:
```
# ps w | egrep "PID|loki_exporter|logread"
  PID USER       VSZ STAT COMMAND
 7317 root      1396 S    {loki_exporter} /bin/ash -u /usr/bin/loki_exporter
 7365 root      1680 S    /sbin/logread -l 3 -tf

# grep -i -- "^vmrss" /proc/7317/status
VmRSS:	     668 kB

# grep -i -- "^vmrss" /proc/7365/status
VmRSS:	     512 kB
```

Before implementing this in shell, I spent some time crafting the same in Python.
Let alone extra disk space for Python itself plus requirements like `python3-requests`,
overall RAM consumption of a simple script was around 22 MB which reached almost 1/5
of all available memory of a router I was running it on.

# Installation

Follow these steps to install the exporter package on your OpenWrt system (assuming SSH access is enabled):

1. Pick the latest release from [GitHub releases page](https://github.com/defanator/openwrt-loki-exporter/releases).
1. Download the `.ipk` binary package from release assets to your OpenWrt router (hint: copy link and run `curl -LO link_to_the_ipk` command directly on your router; make sure you have curl installed - `opkg update && opkg install curl` will do the thing).
1. Install downloaded package with `opkg install loki-exporter_x.x.x-x_all.ipk`.

Alternatively, you can use LuCI web interface (System -> Software) to download and install the package by web link.
This method does not require shell access (SSH), but you will still need shell to configure the exporter.
You may want to check [this guide](https://openwrt.org/docs/guide-quick-start/walkthrough_login) and related [article](https://openwrt.org/docs/guide-quick-start/sshadministration) to learn how to enable and configure SSH access on OpenWrt.

# Configuration

In order to configure the exporter for your particular environment, use these instructions (SSH access required):

1. Configure Loki URL in `/etc/config/loki_exporter` either manually with your favorite editor, or via `uci` tool, e.g. by running:
   ```shell
   % uci set loki_exporter.@loki_exporter[0].loki_push_url='https://your.loki.server/api/v1/push'
   % uci commit loki_exporter
   ```
1. If your server is configured with HTTP basic authentication, you need to set the `loki_auth_header` parameter to base64-encoded string of `%HTTP_USER%:%HTTP_PASSWORD%` format, e.g. if a username is `loki_user` and its password is `loki_pass`, you can construct and set the value with these commands:
   ```shell
   % echo -n "loki_user:loki_pass" | base64
   bG9raV91c2VyOmxva2lfcGFzcw==
   % uci set loki_exporter.@loki_exporter[0].loki_auth_header='bG9raV91c2VyOmxva2lfcGFzcw=='
   % uci commit loki_exporter
   ```
1. Restart the service with `/etc/init.d/loki_exporter restart`.

# Troubleshooting

Exporter is using local log which can be insightful in case of any unexpected issues.
It is located under temporary directory and named like `/tmp/loki_exporter.XXXXXX/log`, e.g.:
```shell
% pwd
/tmp/loki_exporter.DgjnKj
% ls -l
-rw-r--r--    1 root   root     3099 Apr 26 12:40 log
-rw-r--r--    1 root   root    11601 Apr 11 16:05 loki_exporter.boot.payload.gz
-rw-r--r--    1 root   root       98 Apr 11 16:05 loki_exporter.boot.payload.gz-response
prw-r--r--    1 root   root        0 Apr 28 18:50 loki_exporter.pipe
```

The `loki_exporter.boot.payload.gz` under the same directory will contain initial combined payload that is collected on every boot and being sent as a single chunk.

# Caveat

This solution was made with [KISS principle](https://en.wikipedia.org/wiki/KISS_principle) in mind.
It works for me in a given circumstances - a few home-based routers running OpenWRT, generating
relatively small amount of logs.
It is obvious that forking `curl` for every log line might be an overkill in some scenarios,
and there is always room for improvement.
The only corner case which is currently addressed is a reboot of a router: in this case
script will try to collect initial set of messages and send them combined into a single
payload.

# Copyright

Copyright © 2024-2025 Andrei Belov. Released under the [MIT License](LICENSE).
