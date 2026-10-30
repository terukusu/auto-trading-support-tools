#!/usr/bin/env bats
# templates/ip_rules_v4.txt / ip_rules_v6.txt (#146): the sshd rule takes its port from %%SSH_PORT%%,
# the HTTP/HTTPS rules are commented out, the comment block at the top explains the replacement and
# P14, and every other rule is the same as before (checked against fixed lines, not git, so that a
# checkout without master works too). Same static grep style as crontab_template.bats.

load test_helper

setup() {
  atst_test_setup_sandbox
  repo=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
}

teardown() {
  atst_test_teardown_sandbox
}

# The rule lines of the template before #146, without the HTTP/HTTPS lines (port 22 for the sshd rule).
expected_rules() {
  case "$1" in
    v4)
      cat <<'EOT'
*filter
:INPUT   DROP   [0:0]
:FORWARD DROP   [0:0]
:OUTPUT  ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp --tcp-flags ALL NONE -j DROP
-A INPUT -p tcp ! --syn -m state --state NEW -j DROP
-A INPUT -p tcp --tcp-flags ALL ALL -j DROP
-A INPUT -p icmp --icmp-type echo-request -m hashlimit --hashlimit-name t_icmp --hashlimit 1/m --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-htable-expire 120000 -j ACCEPT
-A INPUT -p icmp ! --icmp-type echo-request -j ACCEPT
-A INPUT -p tcp -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p udp -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp -m state --syn --state NEW --dport 22 -m hashlimit --hashlimit-name t_sshd --hashlimit 1/m --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-htable-expire 120000 -j ACCEPT
COMMIT
EOT
      ;;
    v6)
      cat <<'EOT'
*filter
:INPUT   DROP   [0:0]
:FORWARD DROP   [0:0]
:OUTPUT  ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp --tcp-flags ALL NONE -j DROP
-A INPUT -p tcp ! --syn -m state --state NEW -j DROP
-A INPUT -p tcp --tcp-flags ALL ALL -j DROP
-A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 128 -m hashlimit --hashlimit-upto 1/min --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-name t_icmp --hashlimit-htable-expire 120000 -j ACCEPT
-A INPUT -p ipv6-icmp -m icmp6 ! --icmpv6-type 128 -j ACCEPT
-A INPUT -p tcp -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p udp -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 --tcp-flags FIN,SYN,RST,ACK SYN -m hashlimit --hashlimit-upto 1/min --hashlimit-burst 10 --hashlimit-mode srcip --hashlimit-name t_sshd --hashlimit-htable-expire 120000 -j ACCEPT
COMMIT
EOT
      ;;
    *) return 1 ;;
  esac
}

@test "IR-01 (TP-1): %%SSH_PORT%% is there, on exactly one rule line (AC2)" {
  local v f
  for v in v4 v6; do
    f="$repo/templates/ip_rules_$v.txt"
    [ "$(grep -c '%%SSH_PORT%%' "$f")" -ge 1 ] || { echo "$v: none"; false; }
    [ "$(grep -vE '^[[:space:]]*#' "$f" | grep -c '%%SSH_PORT%%')" -eq 1 ] || { echo "$v: not one rule line"; false; }
  done
}

@test "IR-02 (TP-2): no '--dport 22 ' anywhere, comments included (AC3)" {
  local v
  for v in v4 v6; do
    [ "$(grep -c -- '--dport 22 ' "$repo/templates/ip_rules_$v.txt")" -eq 0 ] || { echo "$v"; false; }
  done
}

@test "IR-03 (TP-3): the HTTP/HTTPS rules are commented out with their spacing kept (AC4)" {
  local v f
  for v in v4 v6; do
    f="$repo/templates/ip_rules_$v.txt"
    [ "$(grep -cE '^#.*--dport (80|443)' "$f")" -eq 2 ] || { echo "$v: commented"; false; }
    [ "$(grep -cE '^[^#].*--dport (80|443)' "$f")" -eq 0 ] || { echo "$v: active"; false; }
  done
  [ "$(grep -cx -- '# -A INPUT -p tcp --dport 80   -j ACCEPT' "$repo/templates/ip_rules_v4.txt")" -eq 1 ]
  [ "$(grep -cx -- '# -A INPUT -p tcp --dport 443  -j ACCEPT' "$repo/templates/ip_rules_v4.txt")" -eq 1 ]
  [ "$(grep -cx -- '# -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT' "$repo/templates/ip_rules_v6.txt")" -eq 1 ]
  [ "$(grep -cx -- '# -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT' "$repo/templates/ip_rules_v6.txt")" -eq 1 ]
}

@test "IR-04 (TP-4): the comments explain the port, sshd -T, --test and setup_iptables.sh (AC10)" {
  local v f
  for v in v4 v6; do
    f="$repo/templates/ip_rules_$v.txt"
    [ "$(grep -c 'SSH_PORT' "$f")" -ge 2 ] || { echo "$v: SSH_PORT"; false; }
    [ "$(grep -E '^#' "$f" | grep -c 'sshd -T')" -ge 1 ] || { echo "$v: sshd -T"; false; }
    [ "$(grep -E '^#' "$f" | grep -c -- '--test')" -ge 1 ] || { echo "$v: --test"; false; }
    [ "$(grep -E '^#' "$f" | grep -c 'setup_iptables.sh')" -ge 1 ] || { echo "$v: setup_iptables.sh"; false; }
  done
}

@test "IR-05 (TP-5): every other rule is unchanged, spacing included (AC5)" {
  local v
  for v in v4 v6; do
    diff <(expected_rules "$v") \
      <(grep -vE '^[[:space:]]*(#|$)' "$repo/templates/ip_rules_$v.txt" | sed 's/%%SSH_PORT%%/22/') \
      || { echo "$v differs"; false; }
  done
}

@test "IR-06 (TP-6): one *filter and one COMMIT, comments only at the start of a line" {
  local v f first
  for v in v4 v6; do
    f="$repo/templates/ip_rules_$v.txt"
    [ "$(grep -cx '\*filter' "$f")" -eq 1 ] || { echo "$v: *filter"; false; }
    [ "$(grep -cx 'COMMIT' "$f")" -eq 1 ] || { echo "$v: COMMIT"; false; }
    first=$(grep -vE '^[[:space:]]*$' "$f" | head -n 1)
    [[ "$first" == '#'* ]] || [ "$first" = '*filter' ] || { echo "$v: first line"; false; }
    [ "$(grep -cE '^[^#].*#' "$f")" -eq 0 ] || { echo "$v: inline comment"; false; }
  done
}
