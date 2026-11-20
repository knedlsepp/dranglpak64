# wlan: connect the Pi to a WiFi, e.g. from a phone via SSH at the booth.
# Talks to wpa_supplicant via wpa_cli. Networks added here are saved in
# /etc/wpa_supplicant.conf. DECLARED_NETWORKS (set by uplink.nix) are in the
# NixOS configuration and can't be removed here. HOTSPOT_SSID, the Pi's own
# hotspot, isn't offered.

IF=wlanup
TITLE="DranglPak64 WLAN"
CONFIG=/etc/wpa_supplicant.conf
# Above the declared networks, so a network chosen here wins when in range
PRIORITY=20
# Answers 204 with internet, a captive portal answers something else
CONNECTIVITY_CHECK=http://connectivitycheck.gstatic.com/generate_204

w() { wpa_cli -i "$IF" "$@"; }

# Runs a wpa_cli command that answers OK or FAIL
w_ok() { [ "$(w "$@")" = OK ]; }

status_value() { w status | sed -n "s/^$1=//p"; }

# wpa_cli prints SSIDs with \xNN escapes for anything but ASCII
decode() { printf '%b' "$1"; }

# Unquoted hex works for any SSID
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

msg() { dialog --title "$TITLE" --msgbox "$1" 10 60; }

status_text() {
  local state ssid ip signal
  state=$(status_value wpa_state)
  if [ "$state" = COMPLETED ]; then
    ssid=$(decode "$(status_value ssid)")
    ip=$(status_value ip_address)
    signal=$(iw dev "$IF" link | awk '/signal:/ { print $2 }')
    printf 'Verbunden mit %s (%s dBm)\nIP: %s' "$ssid" "${signal:-?}" "${ip:-noch keine}"
  else
    printf 'Nicht verbunden (%s)' "$state"
  fi
}

# Offers to log in with lynx if a captive portal is in the way
check_internet() {
  local code portal
  dialog --title "$TITLE" --infobox "Prüfe die Internetverbindung …" 3 40
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$CONNECTIVITY_CHECK" || true)
  case $code in
    204)
      msg "$(status_text)\n\nInternet: ja"
      ;;
    000)
      msg "$(status_text)\n\nInternet: nein. Das WLAN selbst hat keine Verbindung nach draußen."
      ;;
    *)
      portal=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 8 "$CONNECTIVITY_CHECK" || true)
      if dialog --title "$TITLE" --yesno "$(status_text)\n\nInternet: noch nicht, das WLAN will eine Anmeldung.\n\nAnmeldeseite im Textbrowser lynx öffnen? (Beenden mit q)" 12 60; then
        lynx -accept_all_cookies "${portal:-http://neverssl.com}"
        check_internet
      fi
      ;;
  esac
}

# connect <ssid> <open|password|sae> [hidden]
connect() {
  local ssid=$1 security=$2 hidden=${3:-} password="" id state i
  if [ "$security" != open ]; then
    password=$(dialog --stdout --title "$TITLE" --insecure --passwordbox "Passwort für $ssid" 8 60) || return 0
    if [ ${#password} -lt 8 ] || [ ${#password} -gt 63 ]; then
      msg "WLAN-Passwörter haben 8 bis 63 Zeichen."
      return 0
    fi
  fi

  id=$(w add_network)
  if ! {
    w_ok set_network "$id" ssid "$(hex "$ssid")" &&
      case $security in
        open) w_ok set_network "$id" key_mgmt NONE ;;
        password) w_ok set_network "$id" psk "\"$password\"" ;;
        # WPA3: also allows WPA2 if the network offers both
        sae) w_ok set_network "$id" psk "\"$password\"" &&
          w_ok set_network "$id" key_mgmt "WPA-PSK SAE" &&
          w_ok set_network "$id" ieee80211w 1 ;;
      esac &&
      { [ -z "$hidden" ] || w_ok set_network "$id" scan_ssid 1; } &&
      w_ok set_network "$id" priority "$PRIORITY" &&
      w_ok enable_network "$id"
  }; then
    w remove_network "$id" >/dev/null
    msg "wpa_supplicant hat das Netz nicht angenommen."
    return 0
  fi
  # The passphrase ends up in there
  chmod 600 "$CONFIG"
  w save_config >/dev/null
  w reassociate >/dev/null

  for i in $(seq 30); do
    dialog --title "$TITLE" --infobox "Verbinde mit $ssid … ($i s)" 3 50
    state=$(status_value wpa_state)
    if [ "$state" = COMPLETED ] && [ "$(decode "$(status_value ssid)")" = "$ssid" ] && [ -n "$(status_value ip_address)" ]; then
      check_internet
      return 0
    fi
    sleep 1
  done
  if dialog --title "$TITLE" --yesno "Die Verbindung mit $ssid hat nicht geklappt (falsches Passwort? zu weit weg?).\n\nNetz wieder entfernen?" 10 60; then
    w remove_network "$id" >/dev/null
    w save_config >/dev/null
    w reassociate >/dev/null
  fi
}

scan_and_connect() {
  local -a ssids=() securities=() items=()
  local -A seen=()
  local _bssid _freq signal flags ssid security label choice
  dialog --title "$TITLE" --infobox "Suche Netze …" 3 30
  w scan >/dev/null
  sleep 5
  # Strongest first, each network once
  while IFS=$'\t' read -r _bssid _freq signal flags ssid; do
    ssid=$(decode "$ssid")
    if [ -z "$ssid" ] || [ "$ssid" = "$HOTSPOT_SSID" ] || [ -n "${seen[$ssid]:-}" ]; then
      continue
    fi
    seen[$ssid]=1
    case $flags in
      *EAP*) security=enterprise label="Firmen-Login" ;;
      *SAE*) security=sae label="Passwort, WPA3" ;;
      *WPA*) security=password label="Passwort" ;;
      *WEP*) security=wep label="WEP" ;;
      *) security=open label="offen" ;;
    esac
    ssids+=("$ssid")
    securities+=("$security")
    items+=("${#ssids[@]}" "$ssid ($signal dBm, $label)")
  done < <(w scan_results | tail -n +2 | sort -t $'\t' -k 3 -n -r)

  if [ ${#ssids[@]} -eq 0 ]; then
    msg "Keine Netze gefunden."
    return 0
  fi
  choice=$(dialog --stdout --title "$TITLE" --menu "Mit welchem Netz verbinden?" 20 70 12 "${items[@]}") || return 0
  ssid=${ssids[$((choice - 1))]}
  case ${securities[$((choice - 1))]} in
    enterprise) msg "$ssid braucht Benutzername und Passwort (WPA-Enterprise). Das kann dieses Menü nicht." ;;
    wep) msg "$ssid ist mit WEP verschlüsselt. Das kann dieses Menü nicht." ;;
    *) connect "$ssid" "${securities[$((choice - 1))]}" ;;
  esac
}

hidden_network() {
  local ssid security
  ssid=$(dialog --stdout --title "$TITLE" --inputbox "Name des versteckten Netzes" 8 60) || return 0
  [ -n "$ssid" ] || return 0
  security=$(dialog --stdout --title "$TITLE" --menu "Verschlüsselung von $ssid" 10 60 2 \
    password "Mit Passwort (WPA2/WPA3)" open "Offen") || return 0
  [ "$security" = password ] && security=sae
  connect "$ssid" "$security" hidden
}

forget() {
  local -a items=()
  local id ssid choice
  while IFS=$'\t' read -r id ssid _; do
    ssid=$(decode "$ssid")
    if ! grep -Fxq -- "$ssid" <<<"$DECLARED_NETWORKS"; then
      items+=("$id" "$ssid")
    fi
  done < <(w list_networks | tail -n +2)
  if [ ${#items[@]} -eq 0 ]; then
    msg "Es gibt keine hier hinzugefügten Netze.\n\nFest konfiguriert (in uplink.nix):\n$DECLARED_NETWORKS"
    return 0
  fi
  choice=$(dialog --stdout --title "$TITLE" --menu "Welches Netz vergessen?" 15 60 8 "${items[@]}") || return 0
  w remove_network "$choice" >/dev/null
  w save_config >/dev/null
  w reassociate >/dev/null
}

if [ "$(id -u)" != 0 ]; then
  echo "wlan: bitte als root starten" >&2
  exit 1
fi

while true; do
  choice=$(dialog --stdout --title "$TITLE" --cancel-label Beenden --menu "$(status_text)" 15 60 5 \
    connect "Netz suchen und verbinden" \
    hidden "Verstecktes Netz eingeben" \
    forget "Hinzugefügtes Netz vergessen" \
    internet "Internetverbindung prüfen" \
    refresh "Status aktualisieren") || break
  case $choice in
    connect) scan_and_connect ;;
    hidden) hidden_network ;;
    forget) forget ;;
    internet) check_internet ;;
  esac
done
clear
