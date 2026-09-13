# postmarketOS-klipper

Automated Klipper / Moonraker / Mainsail / Fluidd installation script to use with [postmarketOS](https://postmarketos.org/).

## Usage

```
sudo apk add bash curl
curl -Ls https://raw.githubusercontent.com/louisrousseau/postmarketos-klipper/master/install.sh | bash -s
```
## Assorted notes
### `pmbootstrap init` configuration
#### Motorola Moto G5 `motorola-cedric`
- Channel: v26.06
- Vendor: qcom
- Device codename: msm89x7
- User interface: fbkeyboard (I haven't tried installing a graphical interface to run KlipperScreen and don't plan to.)
- Service manager: openrc
- Extra packages: git,bash,nano,curl

### Disabling cellular modem
On `cedric` the Qualcomm WWAN driver causes a timeout and error messages on boot, not using it so let's disable it:
```
sudo rc-service msm-modem-wwan-port stop
sudo rc-update del msm-modem-wwan-port default
```
### Wi-Fi MAC Address Randomization 
By default, postmarketOS emulates Android's randomization behaviour. It is possible to edit `/usr/lib/NetworkManager/conf.d/50-random-mac.conf` to have a fixed value. Not all drivers can access the actual hardware value so they might generate something different on every OS reinstall.
```
# Do not randomize MAC address during WiFi scans
[device]
wifi.scan-rand-mac-address=no 

# Use a set MAC address
[connection]
wifi.cloned-mac-address=preserve
ethernet.cloned-mac-address=preserve
```

### Power and battery considerations
I have removed the batteries on both `cedric` and `harpia` then bridged the 5V from the USB port to the battery terminals and added a 10 k&Omega; resistor between the middle and negative contacts so the device still thinks there's a battery present and does not shut down.

So far, both devices have tolerated the higher voltage without any apparent issue.

Another potential gotcha is that the device won't power on with the application of power, I haven't found a way to bypass the power button.