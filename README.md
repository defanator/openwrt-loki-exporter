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
Thankfully, the ash/dash shell bundled with BusyBox supports some bash-specific extensions,
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

Copyright © 2024 Andrei Belov. Released under the [MIT License](LICENSE).
