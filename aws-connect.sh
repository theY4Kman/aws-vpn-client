#!/usr/bin/env bash

set -e

ORIGINAL_OVPN_CONF="$1"
ORIGINAL_OVPN_NAME="$(basename "$ORIGINAL_OVPN_CONF")"

OVPN_BIN="${OVPN_BIN:-openvpn}"

if [ -z "$TMPDIR" ]; then
  if [ -e "/dev/shm" ]; then
    TMPDIR="/dev/shm"
  else
    TMPDIR="/tmp"
  fi
fi

OVPN_CONF="$(mktemp "${TMPDIR}/${ORIGINAL_OVPN_NAME}.XXXXXX")"
chmod 0600 "$OVPN_CONF"

# Remove conflicting options from the config
sed 's/^\s*\(auth-user-pass\|auth-federate\|auth-retry interact\|remote\|remote-random-hostname\)\(\s\|$\)/#\0/g' "$ORIGINAL_OVPN_CONF" > "$OVPN_CONF"
chmod 0400 "$OVPN_CONF"

_OVPN_REMOTE="$(grep -oP 'remote\s+\K(.+ .+)' "$ORIGINAL_OVPN_CONF")"
VPN_HOST="${_OVPN_REMOTE%% *}"
PORT="${_OVPN_REMOTE#* }"
PROTO="$(grep -oP 'proto\s+\K.+' "$ORIGINAL_OVPN_CONF")"

SERVER_PID=""

wait_file() {
  local file="$1"; shift
  local wait_seconds="${1:-10}"; shift # 10 seconds as default timeout
  until test $((wait_seconds--)) -eq 0 -o -f "$file" ; do sleep 1; done
  ((++wait_seconds))
}

cleanup() {
  if [ -e "$OVPN_CONF" ]; then
    rm "$OVPN_CONF"
  fi
  if [ -z "$SERVER_PID" ]; then
    kill "$SERVER_PID"
  fi
}
trap "cleanup" EXIT

# create random hostname prefix for the vpn gw
RAND=$(openssl rand -hex 12)

# resolv manually hostname to IP, as we have to keep persistent ip address
SRV=$(dig a +short "${RAND}.${VPN_HOST}"|head -n1)

# cleanup
rm -f saml-response.txt

go run server.go &
SERVER_PID=$!

echo "Getting SAML redirect URL from the AUTH_FAILED response (host: ${SRV}:${PORT})"
OVPN_OUT=$($OVPN_BIN --config "${OVPN_CONF}" --verb 3 \
     --proto "$PROTO" --remote "${SRV}" "${PORT}" \
     --auth-user-pass <( printf "%s\n%s\n" "N/A" "ACS::35001" ) \
    2>&1 | grep AUTH_FAILED,CRV1)

echo "Opening browser and wait for the response file..."
URL=$(echo "$OVPN_OUT" | grep -Eo 'https://.+')

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     xdg-open "$URL";;
    Darwin*)    open "$URL";;
    *)          echo "Could not determine 'open' command for this OS"; exit 1;;
esac

wait_file "saml-response.txt" 30 || {
  echo "SAML Authentication time out"
  exit 1
}

# get SID from the reply
VPN_SID=$(echo "$OVPN_OUT" | awk -F : '{print $7}')

echo "Running OpenVPN with sudo. Enter password if requested"

# Finally OpenVPN with a SAML response we got
# Delete saml-response.txt after connect
sudo bash -c "'$OVPN_BIN' --config '${OVPN_CONF}' \
    --verb 3 --auth-nocache --inactive 3600 \
    --proto '$PROTO' --remote $SRV $PORT \
    --script-security 2 \
    --route-up '/usr/bin/env rm saml-response.txt' \
    --auth-user-pass <( printf \"%s\n%s\n\" \"N/A\" \"CRV1::${VPN_SID}::$(cat saml-response.txt)\" )"
