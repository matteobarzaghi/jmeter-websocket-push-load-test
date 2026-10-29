#!/usr/bin/env bash
# check_vm.sh - read-only snapshot of an injector VM (Push Terminals). Changes NOTHING.
# Usage: bash check_vm.sh   (or from another VM: ssh user@IP 'bash -s' < check_vm.sh)

J=/opt/performance/apache-jmeter-5.6.3
P=/opt/performance/tests/testplans/push-terminals
ok()  { printf '  %-26s %s\n' "$1" "$2"; }

echo "================ $(hostname -s) ($(hostname -I 2>/dev/null | awk '{print $1}')) ================"
echo "SYSTEM"
ok "OS"            "$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
ok "Kernel"        "$(uname -r)"
ok "vCPU"          "$(nproc)"
ok "RAM"           "$(free -g | awk '/Mem:/ {print $2" GB total, "$7" GB available"}')"
ok "Swap"          "$(free -g | awk '/Swap:/ {print $2" GB"}')"
if [ -d /opt/performance ]; then
  ok "/opt/performance" "$(df -h /opt/performance | awk 'NR==2 {print $4" free of "$2}') - owner $(stat -c %U /opt/performance)"
else
  ok "/opt/performance" "MISSING - /opt: $(df -h /opt | awk 'NR==2 {print $4" free"}')"
fi
ok "Time / NTP"    "$(date '+%F %T %Z') - sync: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"
ok "User / sudo"   "$(id -un) - passwordless sudo: $(sudo -n true 2>/dev/null && echo yes || echo no/to be checked)"

echo "SOFTWARE"
ok "Java"          "$(command -v java >/dev/null && java -version 2>&1 | grep -i 'version' | head -1 || echo MISSING)"
ok "JMeter 5.6.3"  "$([ -x $J/bin/jmeter ] && echo present || echo MISSING)"
ok "WS plugin"     "$(ls $J/lib/ext 2>/dev/null | grep -i websocket || echo MISSING)"
ok "user.properties" "$([ -f $J/bin/user.properties ] && grep -E '^(mode|summariser.interval)=' $J/bin/user.properties | tr '\n' ' ' || echo MISSING)"
ok "JVM_ARGS bashrc" "$(grep -q JVM_ARGS ~/.bashrc 2>/dev/null && echo present || echo MISSING)"
ok "Python3"       "$(python3 --version 2>&1 || echo MISSING)"
ok ".jmx md5"      "$([ -f $P/push-terminals-websocket.jmx ] && md5sum $P/push-terminals-websocket.jmx | awk '{print $1}' || echo MISSING)"
ok "device_ids.csv" "$([ -f $P/device_ids.csv ] && echo "$(grep -c . $P/device_ids.csv) lines, min $(tr -d '\r' < $P/device_ids.csv | sort -n | head -1), max $(tr -d '\r' < $P/device_ids.csv | sort -n | tail -1)" || echo MISSING)"
ok "JMeter running" "$(pgrep -f ApacheJMeter >/dev/null && echo YES || echo no)"

echo "OS TUNING"
ok "ulimit -Hn / -Sn" "$(ulimit -Hn) / $(ulimit -Sn)   (expected 1048576)"
ok "port_range"    "$(cat /proc/sys/net/ipv4/ip_local_port_range | tr '\t' ' ')   (expected 1024 65535)"
ok "tcp_tw_reuse"  "$(cat /proc/sys/net/ipv4/tcp_tw_reuse)   (expected 1)"
ok "tcp_fin_timeout" "$(cat /proc/sys/net/ipv4/tcp_fin_timeout)   (expected 15)"
ok "tuning files"  "$(F=$(ls /etc/sysctl.d/99-loadtest.conf /etc/security/limits.d/99-jmeter.conf 2>/dev/null | tr '\n' ' '); echo "${F:-MISSING}")"
ok "conntrack"     "$(lsmod 2>/dev/null | grep -q '^nf_conntrack' && echo LOADED || echo not loaded)"
ok "firewalld"     "$(systemctl is-active firewalld 2>/dev/null || echo '-')"
# pam_limits can be direct or included (RHEL: sshd -> password-auth, login -> system-auth)
for f in /etc/pam.d/sshd /etc/pam.d/login; do
  inc=$(awk '$1=="session" && ($2=="include"||$2=="substack") {print $3}' $f 2>/dev/null | tr '\n' ' ')
  src=""; for g in $f $(for i in $inc; do echo /etc/pam.d/$i; done); do grep -q '^[^#]*pam_limits.so' $g 2>/dev/null && src="$src $(basename $g)"; done
  ok "pam_limits $(basename $f)" "$([ -n "$src" ] && echo "present (in:$src)" || echo MISSING)"
done
ok "nf_conntrack_max" "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '-')"
