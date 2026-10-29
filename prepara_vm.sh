#!/usr/bin/env bash
# prepara_vm.sh - prepares a Push Terminals JMeter injector VM (injector01-04).
# Idempotent: safe to re-run, skips what is already done. Acts only on the local VM (no target hosts).
#
# Prerequisite (upload in Binary mode, e.g. WinSCP) in the home directory ~ :
#   apache-jmeter-5.6.3.zip  push-terminals-websocket.jmx  jmeter_injector_tuning.sh  check_vm.sh  prepara_vm.sh
# Usage (as your regular user, NOT with sudo):  bash prepara_vm.sh
# Afterwards: close and reopen the SSH session, then  bash check_vm.sh

set -euo pipefail

JMX_MD5="776563cc77432844b43583ed63e832ce"
BASE=/opt/performance
J=$BASE/apache-jmeter-5.6.3
P=$BASE/tests/testplans/push-terminals
ME=$(id -un)
HOST=$(hostname -s)
JVM_LINE='export JVM_ARGS="-Xms9g -Xmx9g -Xss256k -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ParallelRefProcEnabled -XX:MaxMetaspaceSize=512m -Djava.net.preferIPv4Stack=true -Dsun.net.inetaddr.ttl=0"'
NTP1=ntp1.example.internal
NTP2=ntp2.example.internal

step() { echo; echo "=== $* ==="; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Terminal ID block per VM (no overlap with other injectors: 1-25000, 200001-225000)
case "$HOST" in
  injector01) ID_FROM=225001 ;;
  injector02) ID_FROM=250001 ;;
  injector03) ID_FROM=275001 ;;
  injector04) ID_FROM=300001 ;;
  *) die "unexpected host $HOST (expected injector01-04)" ;;
esac
ID_TO=$((ID_FROM + 24999))

step "0. Initial checks ($HOST)"
[ "$EUID" -ne 0 ] || die "run as $ME, not with sudo (the script uses sudo where needed)"
sudo -n true 2>/dev/null || die "passwordless sudo not available"
for f in apache-jmeter-5.6.3.zip push-terminals-websocket.jmx jmeter_injector_tuning.sh; do
  if [ "$f" = apache-jmeter-5.6.3.zip ] && [ -x $J/bin/jmeter ]; then continue; fi
  [ -f ~/"$f" ] || die "missing ~/$f: upload it first"
done
echo "OK - expected IDs: $ID_FROM - $ID_TO"

step "1. Java 21"
if rpm -q java-21-openjdk-headless >/dev/null 2>&1; then echo "already installed"; else sudo dnf install -y -q java-21-openjdk-headless; fi
java -version 2>&1 | grep version

step "2. NTP (internal servers)"
if grep -q "$NTP1" /etc/chrony.conf; then
  echo "internal servers already present"
else
  [ -f /etc/chrony.conf.bak ] || sudo cp /etc/chrony.conf /etc/chrony.conf.bak
  printf 'server %s iburst\nserver %s iburst\n' "$NTP1" "$NTP2" | sudo tee -a /etc/chrony.conf >/dev/null
  sudo systemctl restart chronyd
  sleep 15
fi
sudo chronyc makestep >/dev/null || true
chronyc tracking | sed -n '1,2p'

step "3. Directories"
sudo mkdir -p $P/results $BASE/tests/results
sudo chown -R "$ME": $BASE
ls -ld $BASE

step "4. JMeter 5.6.3"
if [ -x $J/bin/jmeter ]; then
  echo "already present"
else
  rpm -q unzip >/dev/null 2>&1 || sudo dnf install -y -q unzip
  unzip -q ~/apache-jmeter-5.6.3.zip -d $BASE
  [ -d $J ] || die "the zip did not create $J: check the folder name"
fi
chmod +x $J/bin/jmeter $J/bin/*.sh
ls $J/lib/ext | grep -i websocket || die "WebSocket plugin missing in $J/lib/ext"

step "5. OS tuning"
cp ~/jmeter_injector_tuning.sh $BASE/
sed -i 's/\r$//' $BASE/jmeter_injector_tuning.sh
chmod +x $BASE/jmeter_injector_tuning.sh
sudo env JMETER_USER="$ME" bash $BASE/jmeter_injector_tuning.sh 2>&1 | tee ~/tuning_"$HOST".log \
  | sed -n '/PRE-TEST REPORT/,/^-----/p'
echo "(full log: ~/tuning_$HOST.log - pam_limits warnings are false positives on RHEL)"

step "6. JVM_ARGS and user.properties"
grep -q JVM_ARGS ~/.bashrc || echo "$JVM_LINE" >> ~/.bashrc
grep JVM_ARGS ~/.bashrc
UP=$J/bin/user.properties
[ -z "$(tail -c1 "$UP")" ] || echo >> "$UP"   # ensures a trailing newline before appending lines
grep -q '^mode=' "$UP" || echo 'mode=Stripped' >> "$UP"
grep -q '^summariser.interval=' "$UP" || echo 'summariser.interval=30' >> "$UP"
grep -E '^(mode|summariser.interval)=' "$UP"

step "7. Test plan (.jmx)"
cp ~/push-terminals-websocket.jmx $P/
GOT=$(md5sum $P/push-terminals-websocket.jmx | awk '{print $1}')
[ "$GOT" = "$JMX_MD5" ] || die ".jmx has md5 $GOT, expected $JMX_MD5: upload it again in Binary mode"
echo "md5 OK ($GOT)"

step "8. device_ids.csv ($ID_FROM - $ID_TO)"
CSV=$P/device_ids.csv
if [ -f $CSV ] && [ "$(tr -d '\r' < $CSV | sort -n | sed -n '1p;$p' | tr '\n' ' ')" = "$ID_FROM $ID_TO " ] && [ "$(grep -c . $CSV)" = 25000 ]; then
  echo "already correct"
else
  [ -f $CSV ] && cp $CSV $CSV.bak
  seq $ID_FROM $ID_TO > $CSV
fi
echo "$(grep -c . $CSV) lines, min $(sort -n $CSV | head -1), max $(sort -n $CSV | tail -1)"

echo
echo "=== DONE on $HOST ==="
echo "Now: close and reopen the SSH session, then run:  bash ~/check_vm.sh"
