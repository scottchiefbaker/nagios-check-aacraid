# nagios-plugin-aacraid

Nagios plugin to check Adaptec RAID cards. Requires `arcconf` and probably `sudo` to run. This plugin checks controller health, logical drive status, and optionally can report on physical drive errors.

## Installation

Copy `check_aacraid.pl` to `/home/nagios` or another place accessible by your Nagios user.

## Usage

`check_aacraid.pl [--physical]`

* `--physical` will check for errors on the individual disks

## Using this plugin with sudo

To use this plugin as a non-root user will require `sudo` access. To configure your system to allow the `nagios` user to run `arcconf` commands you will need to add the following to your `/etc/sudoers` file.

    nagios ALL=(root) NOPASSWD: /usr/Arcconf/arcconf GETCONFIG 1
