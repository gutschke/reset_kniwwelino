#!/bin/bash -e

## Copyright (c) 2018, Markus Gutschke
## All rights reserved.
##
## Redistribution and use in source and binary forms, with or without
## modification, are permitted provided that the following conditions are met:
##
## 1. Redistributions of source code must retain the above copyright notice, this
##    list of conditions and the following disclaimer.
## 2. Redistributions in binary form must reproduce the above copyright notice,
##    this list of conditions and the following disclaimer in the documentation
##    and/or other materials provided with the distribution.
##
## THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
## ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
## WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
## DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
## ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
## (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
## LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
## ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
## (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
## SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# You can edit the default URL for the Kniwwelino firmware, or you can
# override it on the command line.
#
# The script understands two different types of JSON manifests: 1) the master
# manifest that will be used to locate the most recent firmware release, or
# 2) a JSON manifest that describes exactly one firmware release
URL="${1:-https://code.kniwwelino.lu/flasher/manifest.json}"
# URL="${1:-https://code.kniwwelino.lu/flasher/v1.10.0/manifest.json}"

# By default, the script looks for the first Kniwwelino device. Alternatively,
# the device file can be hard-coded here. It will still be validated later.
# If the PORT starts with "!", then validation is skipped.
#
# Multiple different locations for the PORT can be separated by colons.
#
# Uncomment to override default behavior:
# PORT=/dev/ttyUSB0
# PORT=!/dev/ttyUSB0
PORT="${PORT:-:!/dev/ttyUSB0:!/dev/cu.wchusbserial1410}"
#
# Specify the USB product and vendor identifiers for the Kniwwelino board.
PRODUCT=7523
VENDOR=1a86

# We need a couple of extra command line arguments to specify how our
# hardware looks like.
FLASH="-cd nodemcu -bf 80 -bz 4M -cb 460800"

# We expect to find these identifiers in the JSON manifest files. Manifests can
# contain information for more than one type of hardware, but we currently only
# support a very specific architecture.
NAME="Kniwwelino"
BOARD="ESP8266"
REVISION="ESP12"
ALTREVISION="ESP-12"

# Disable any I18N features that might interfere with the operation of this
# script
export LC_ALL=C

# Make sure all of the required Linux tools are actually installed
for i in curl find head jq mktemp seq unzip; do
  f="$(type -fpP "${i}" 2>/dev/null || :)"
  if ! [ -x "${f}" ]; then
    echo "Cannot find the \"${i}\" tool. You'll have to install it before running this script" >&2
    exit 1
  fi
done

# In case of error, exit the script and print a message to the user
trap 'trap "" ERR
      exec >&2
      type -fpP tput >&/dev/null && tput bel || :
      echo "Script terminated unexpectedly; Kniwwelino has not been reset"
      exit 1' ERR

# When the script finishes, clean up after us
tmp= ; trap '[ -n "${tmp}" -a -d "${tmp}" ] && rm -rf "${tmp}"' EXIT

# Clean up after unexpected termination.
trap 'trap "" INT HUP QUIT TERM
      exec >&2
      echo; echo Unexpected termination
      exit 1' INT HUP QUIT TERM

# Create some temporary storage for the downloaded firmware files
tmp="$(mktemp -d)"

# Locate the tool that is needed to flash the Kniwwelino. It is part of the
# Arduino and the PlatformIO IDE. If this script cannot locate the "esptool",
# reinstall the development environment and make sure that you have followed the
# instructions for how to enable the Kniwwelino board type.
find -maxdepth 0 -perm /1 >&/dev/null && perm="/0111" || perm="+0111"
esptool="$(find ~/.arduino15 ~/.platformio -type f -perm "${perm}" -name esptool 2>/dev/null |
           sort -nr | head -n1)"
if ! [ -x "${esptool}" ]; then
  echo "Cannot find \"esptool\" for flashing Kniwwelino; re-install Arduino or PlatformIO support" >&2
  exit
fi

# Check if we found the correct USB port
IFS=: ports=(${PORT})
for port in "${ports[@]}"; do
  if [[ "x${port}" =~ ^"x!" ]]; then
    if [ -r "${port#!}" -a -w "${port#!}" ]; then
      dev="${port#!}"
      break
    fi
  else
    dev=
    # Scan the USB subsystem for a device that matches 1a86:7523. You
    # can use "lsbusb" to verify that your Kniwwelino identifies itself
    # this way.
    for p in /sys/bus/usb/devices/*; do
      [ -r "${p}/idProduct" -a -r "${p}/idVendor" ] || continue
      [ "x${PRODUCT}" = "x$(<${p}/idProduct)" -a \
        "x${VENDOR}" = "x$(<${p}/idVendor)" ] || continue
      dev="$(find "${p}/" -maxdepth 2 -name ttyUSB\* -printf '/dev/%f\n')"
      [ -n "${dev}" -a -r "${dev}" -a -w "${dev}" ] || continue
      [ "x${dev}" = "x${port}" -o -z "${port}" ] && break 2
      dev=
    done
  fi
done
if [ -z "${dev}" ]; then
  echo "Cannot find a suitable serial port to talk to the Kniwwelino; did you plug it in?" >&2
  [[ "$(id -Gn)" =~ dialout ]] || echo "Maybe you need to be in the \"dialout\" user group?" >&2
  exit 1
fi

# Check if this is a master JSON manifest, and if we can use it to locate
# the most recent published firmware release. There should only be a single
# entry marked as having the latest firmware.
echo "Downloading firmware manifest"
manifest="$(curl -o- "${URL}")"
# Use the JSON parser to find the latest firmware version that matches our
# NAME, BOARD, and REVISION.
latest="$(jq -r '.options[] | select(.name == "'"${NAME}"'") | .versions[] |
                 select(.latest == true and .board == "'"${BOARD}"'" and
                 (.revision == "'"${REVISION}"'" or
                  .revision == "'"${ALTREVISION}"'"))' \
          <<<"${manifest}" 2>/dev/null || :)"
if [ -n "${latest}" ]; then
  # Now download the JSON manifest for the firmware referenced from the master
  # manifest.
  version="$(jq -r '.version' <<<"${latest}" 2>/dev/null || :)"
  url="$(jq -r '.manifest' <<<"${latest}" 2>/dev/null || :)"
  if [ -z "${url}" ]; then
    echo "Cannot find a URL for the latest firmware ${version}" >&2
    exit 1
  fi
  echo "Downloading firmware manifest for Kniwwelino ${version}"
  manifest="$(curl -o- "${url}")"
else
  # This was already a manifest for a specific firmware release.
  version="$(jq -r '.version' <<<"${manifest}" 2>/dev/null || :)"
fi

# Verify that what we downloaded was in fact a valid manifest file describing
# a Kniwwelino board. Make sure the NAME, BOARD, REVISION and version number
# have the expected values.
echo "Validating JSON manifest"
manifest="$(jq -r 'select(.name == "'"${NAME}"'" and .board == "'"${BOARD}"'" and
                          (.revision == "'"${REVISION}"'" or
                           .revision == "'"${ALTREVISION}"'") and
                          .version != "" and .version == "'"${version}"'")' \
            <<<"${manifest}" 2>/dev/null || :)"
# Retrieve the URL for the actual firmware image file.
url="$(jq -r '.download' <<<"${manifest}" 2>/dev/null || :)"
if  ! [[ "x${url}" =~ ^"xhttp" ]]; then
  echo "JSON data does not appear to match a known firmware description" >&2
  exit 1
fi

# Firmware typically contains more than one component. Extract the filenames and
# addresses for each payload.
echo "Parsing JSON data"
while :; do
  if ! read bracket || [ "x${bracket}" != "x{" ]; then break; fi
  while read line && [ "x${line}" != "x}" ]; do
    if [[ "${line}" =~ '"'([^\"]+)'": '*'"'([^\"]+)'"' ]] &&
         [ "x${BASH_REMATCH[1]}" = "xaddress" -o \
           "x${BASH_REMATCH[1]}" = "xpath" ]; then
      eval json_${BASH_REMATCH[1]}'=( '\${json_${BASH_REMATCH[1]}[@]}' '\'${BASH_REMATCH[2]}\'' )'
    fi
  done
done < <(jq -r '.flash[]' <<<"${manifest}")

# Firmware is packed into a ZIP file that contains all of the separate
# components.
echo "Downloading factory-default firmware for Kniwwelino ${version}"
curl -o "${tmp}/kniwwelino.zip" "${url}"

# Extract the firmware from the ZIP file and verify that it contains all of
# the required components.
echo "Extracting firmware ${version}"
(cd "${tmp}" && unzip "${tmp}/kniwwelino.zip")
for i in $(seq 0 $((${#json_path[@]}-1))); do
  if ! [ -r "${tmp}/${json_path[${i}]}" ]; then
    echo "Zip file is missing expected component: ${json_path[${i}]}" >&2
    exit 1
  fi
done

# Now, we can finally attempt to flash the Kniwwelino
echo "Flashing firmware ${version}"
for i in $(seq 0 $((${#json_path[@]}-1))); do
  p="${json_path[${i}]}"
  a="${json_address[${i}]}"
  "${esptool}" ${FLASH} -cp "${dev}" -ca "${a}" -cf "${tmp}/${p}"
done

# All done
echo "Your Kniwwelino has been reset${version:+ to firmware version }${version}"
