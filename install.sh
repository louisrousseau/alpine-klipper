#!/usr/bin/env bash

set -euxo pipefail

: ${DATA_PATH:="$HOME/printer_data"}

: ${CONFIG_PATH:="$DATA_PATH/config"}
: ${GCODE_PATH:="$DATA_PATH/gcodes"}
: ${LOG_PATH:="$DATA_PATH/logs"}
: ${COMMS_PATH:="$DATA_PATH/comms"}

: ${KLIPPER_REPO:="https://github.com/Klipper3d/klipper.git"}
: ${KLIPPER_PATH:="$HOME/klipper"}
: ${KLIPPY_VENV_PATH:="$HOME/venv/klippy"}

: ${MOONRAKER_REPO:="https://github.com/Arksine/moonraker"}
: ${MOONRAKER_PATH:="$HOME/moonraker"}
: ${MOONRAKER_VENV_PATH:="$HOME/venv/moonraker"}

# Choose "mainsail" or "fluidd"
: ${CLIENT:="mainsail"}
: ${CLIENT_PATH:="$HOME/$CLIENT"}

if [ $(id -u) = 0 ]; then
    echo "This script must not run as root"
    exit 1
fi

################################################################################
# PRE
################################################################################

# Packages now included in my build config
#sudo apk add git unzip libffi-dev make gcc g++ \
#ncurses-dev avrdude gcc-avr binutils-avr avr-libc \
#python3 py3-virtualenv \
#python3-dev freetype-dev fribidi-dev harfbuzz-dev jpeg-dev lcms2-dev openjpeg-dev tcl-dev tiff-dev tk-dev zlib-dev \
#jq patch libsodium caddy curl polkit grep iproute2

case $CLIENT in
  fluidd)
    CLIENT_RELEASE_URL=`curl -Ls https://api.github.com/repos/fluidd-core/fluidd/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  mainsail)
    CLIENT_RELEASE_URL=`curl -Ls https://api.github.com/repos/mainsail-crew/mainsail/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  *)
    echo "Unknown client $CLIENT (choose fluidd or mainsail)"
    exit 2
    ;;
esac

################################################################################
# KLIPPER
################################################################################

mkdir -p $DATA_PATH
mkdir -p $CONFIG_PATH
mkdir -p $LOG_PATH
mkdir -p $GCODE_PATH
mkdir -p $COMMS_PATH

touch $CONFIG_PATH/printer.cfg

test -d $KLIPPER_PATH || git clone $KLIPPER_REPO $KLIPPER_PATH
test -d $KLIPPY_VENV_PATH || virtualenv -p python3 $KLIPPY_VENV_PATH
$KLIPPY_VENV_PATH/bin/python -m pip install --upgrade pip
$KLIPPY_VENV_PATH/bin/pip install -r $KLIPPER_PATH/scripts/klippy-requirements.txt

sudo tee /etc/init.d/klipper <<EOF
#!/sbin/openrc-run
command="$KLIPPY_VENV_PATH/bin/python"
command_args="$KLIPPER_PATH/klippy/klippy.py $CONFIG_PATH/printer.cfg -l $LOG_PATH/klippy.log -a $COMMS_PATH/klippy.sock"
command_background=true
command_user="$USER"
pidfile="/run/klipper.pid"
EOF

sudo chmod +x /etc/init.d/klipper
sudo rc-update add klipper
sudo service klipper start

################################################################################
# MOONRAKER
################################################################################

test -d $MOONRAKER_PATH || git clone $MOONRAKER_REPO $MOONRAKER_PATH
test -d $MOONRAKER_VENV_PATH || virtualenv -p python3 $MOONRAKER_VENV_PATH
$MOONRAKER_VENV_PATH/bin/python -m pip install --upgrade pip
$MOONRAKER_VENV_PATH/bin/pip install -r $MOONRAKER_PATH/scripts/moonraker-requirements.txt

sudo tee /etc/init.d/moonraker <<EOF
#!/sbin/openrc-run
command="${MOONRAKER_VENV_PATH}/bin/python"
command_args="${MOONRAKER_PATH}/moonraker/moonraker.py -d ${DATA_PATH}"
command_background=true
command_user="$USER"
pidfile="/run/moonraker.pid"
depend() {
  before klipper
}
EOF

sudo chmod a+x /etc/init.d/moonraker

cat > $CONFIG_PATH/moonraker.conf <<EOF
[server]
host: 0.0.0.0
port: 7125
# The maximum size allowed for a file upload (in MiB).  Default 1024 MiB
max_upload_size: 1024
# Path to klippy Unix Domain Socket
klippy_uds_address: $COMMS_PATH/klippy.sock

[machine]
# There are no OpenRC-compatible options at the moment
provider: none
validate_service: False

[file_manager]
# post processing for object cancel. Not recommended for low resource SBCs such as a Pi Zero. Default False
enable_object_processing: False

[authorization]
cors_domains:
    *://my.mainsail.xyz
    *://*.home.arpa
    *://*.local
    *://*.lan
trusted_clients:
    10.0.0.0/8
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.168.0.0/16
    FE80::/10
    ::1/128

# enables partial support of Octoprint API
[octoprint_compat]

# enables moonraker to track and store print history.
[history]

# this enables moonraker announcements for mainsail
[announcements]
subscriptions:
    mainsail

# this enables moonraker's update manager
[update_manager]
refresh_interval: 168
enable_auto_refresh: True
# System packages updates are only possible with apt
enable_system_updates: False

[update_manager mainsail]
type: web
channel: stable
repo: mainsail-crew/mainsail
path: ~/mainsail

[update_manager fluidd]
type: web
repo: cadriel/fluidd
path: ~/fluidd
EOF

sudo rc-update add moonraker
sudo service moonraker start

################################################################################
# MAINSAIL/FLUIDD
################################################################################

sudo mkdir -p /etc/caddy
# To reformat the Caddyfile: sudo caddy fmt --overwrite /etc/caddy/Caddyfile

sudo tee /etc/caddy/Caddyfile <<EOF
:80

encode gzip

root * $CLIENT_PATH

@moonraker {
  path /server/* /websocket /printer/* /access/* /api/* /machine/*
}

route @moonraker {
  reverse_proxy localhost:7125
}

route /webcam {
  reverse_proxy localhost:8081
}

route {
  try_files {path} {path}/ /index.html
  file_server
}
EOF

test -d $CLIENT_PATH && rm -rf $CLIENT_PATH
mkdir -p $CLIENT_PATH
(cd $CLIENT_PATH && wget -q -O $CLIENT.zip $CLIENT_RELEASE_URL && unzip $CLIENT.zip && rm $CLIENT.zip)

sudo rc-update add caddy
sudo service caddy start

################################################################################
# AUTO DELETE OLD GCODE
################################################################################

sudo tee /etc/periodic/15min/klipper <<END
#!/bin/sh
find $GCODE_PATH -mtime +5 -type f -delete
END

sudo chmod a+x /etc/periodic/15min/klipper

sudo service crond start
sudo rc-update add crond

# UPDATE SCRIPT

cat > $HOME/update <<'EOF'
#!/usr/bin/env bash

set -exo pipefail

: \${CLIENT:="$CLIENT"}
: \${CLIENT_PATH:="$CLIENT_PATH"}

case \$CLIENT in
  fluidd)
    CLIENT_RELEASE_URL=`curl -Ls https://api.github.com/repos/fluidd-core/fluidd/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  mainsail)
    CLIENT_RELEASE_URL=`curl -Ls https://api.github.com/repos/mainsail-crew/mainsail/releases | jq -r ".[0].assets[0].browser_download_url"`
    ;;
  *)
    echo "Unknown client \$CLIENT (choose fluidd or mainsail)"
    exit 2
    ;;
esac

# KLIPPER
sudo service klipper stop
(cd $KLIPPER_PATH && git fetch && git rebase origin/master)
$KLIPPY_VENV_PATH/bin/pip install -r $KLIPPER_PATH/scripts/klippy-requirements.txt
test -z "\$FLASH_DEVICE" || (cd $KLIPPER_PATH && make && make flash)
sudo service klipper start

# MOONRAKER
sudo service moonraker stop
(cd $MOONRAKER_PATH && git fetch && git rebase origin/master)
$MOONRAKER_VENV_PATH/bin/pip install -r $MOONRAKER_PATH/scripts/moonraker-requirements.txt
sudo service moonraker start

# CLIENT
rm -Rf \$CLIENT_PATH
mkdir -p \$CLIENT_PATH
(cd \$CLIENT_PATH && wget -q -O \$CLIENT.zip \$CLIENT_RELEASE_URL && unzip \$CLIENT.zip && rm \$CLIENT.zip)
sudo service caddy start
EOF

chmod a+x $HOME/update
