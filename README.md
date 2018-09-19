# reset_kniwwelino.sh
Linux script to reset a Kniwwelino to factory settings

When working with the Arduino IDE, it is possible to overwrite the factory
programming of the [Kniwwelino](http://kniwwelino.lu) micro-controller.

If you want to go back to factory settings, the project publishes stand-alone
firmware flashing software. But sometimes that's just too complicated, and on
Linux the built-in tools often work better.

You need to have access to the "esptool" binary that got installed when you
[enabled support](https://doku.kniwwelino.lu/en/installationarduino) for the
Kniwwelino board type in your Arduino IDE. You also need to install the
["jq"](https://stedolan.github.io/jq/) JSON parser. Other than that, the script
only uses standard Linux tools.

At the very top of the script, you can optionally change the default URL for
the factory firmware, or you can pass this value as an argument on the command
line.

The other editable parameter is the default USB port. Chances are, most users
only have a single Kniwwelino attached at a time and won't need to edit this
value. Make sure that your user has access to the /dev/ttyUSB0 device node
though. In most cases, that requires you to be a member of the "dialout" group.
