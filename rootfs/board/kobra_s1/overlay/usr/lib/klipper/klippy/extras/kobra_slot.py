# Restart from ShedNaja into the stock Anycubic firmware in the other A/B slot.
#
# _REBOOT_TO_STOCK opens a confirmation dialog (Mainsail / HelixScreen action:prompt);
# _REBOOT_TO_STOCK CONFIRM=1 marks the other slot as the boot slot (kobra-abctl other, the same
# misc change as stock rk_ota), resets the MCUs like FIRMWARE_RESTART and reboots. Refused
# while a print is running or paused. The frontends list only [gcode_macro] objects, so
# the config wraps it in a REBOOT_TO_STOCK macro.
# The MCU reset matters: a warm reboot keeps the MCUs running in the state Klipper left
# them in, and stock then fails with error 11407 (printhead board does not start) until
# the printer is power-cycled.
# Back from stock: SSH (kobra-abctl / rk_ota) or the ShedNaja installer on a USB stick.
#
# _ROLLBACK_SYSTEM (Armbian variant, two system copies on useremain): same dialog and print
# check, then "kobra-ab rollback" makes the other, previous root the active one and reboots
# into it (with its own kernel). On a system without kobra-ab it only says so.
#
# _SHEDNAJA_UPDATE: install an update bundle uploaded in Mainsail into the "updates" folder
# of the config files (printer_data/config/updates; Moonraker takes uploads up to 1 GB
# there, the gcodes root only G-code). The newest upload for this variant (Lite:
# shednaja-update*.tar, Armbian: shednaja-armbian-update*.tar) is shown with its build id;
# its Install button (CONFIRM=1 FILE=<that bundle>) starts "kobra-update --yes
# --remove-bundle" for exactly that file as its own process. Refused while a
# print is running or paused; kobra-update checks that again and reboots when done.
#
# [kobra_slot]
#
# [gcode_macro REBOOT_TO_STOCK]
# description: Restart into the stock Anycubic firmware (other slot)
# gcode:
#   _REBOOT_TO_STOCK {rawparams}
#
# [gcode_macro ROLLBACK_SYSTEM]
# description: Go back to the previous system version (Armbian variant)
# gcode:
#   _ROLLBACK_SYSTEM {rawparams}
#
# [gcode_macro SHEDNAJA_UPDATE]
# description: Install the update uploaded to config/updates
# gcode:
#   _SHEDNAJA_UPDATE {rawparams}
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import fnmatch
import glob
import logging
import os
import subprocess

ABCTL = '/usr/sbin/kobra-abctl'
KOBRA_AB = '/usr/local/sbin/kobra-ab'
KOBRA_UPDATE = '/usr/sbin/kobra-update'

def current_slot():
    try:
        with open('/proc/cmdline') as f:
            cmdline = f.read()
    except OSError:
        return '?'
    for root, slot in (('root=/dev/mmcblk0p8', 'A'), ('root=/dev/mmcblk0p9', 'B')):
        if root in cmdline.split():
            return slot
    return '?'

class KobraSlot:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.slot = current_slot()
        self.gcode = self.printer.lookup_object('gcode')
        self.gcode.register_command('_REBOOT_TO_STOCK', self.cmd_REBOOT_TO_STOCK,
                                    desc=self.cmd_REBOOT_TO_STOCK_help)
        self.gcode.register_command('_ROLLBACK_SYSTEM', self.cmd_ROLLBACK_SYSTEM,
                                    desc=self.cmd_ROLLBACK_SYSTEM_help)
        self.gcode.register_command('_SHEDNAJA_UPDATE', self.cmd_SHEDNAJA_UPDATE,
                                    desc=self.cmd_SHEDNAJA_UPDATE_help)
        config_file = self.printer.get_start_args().get('config_file', '')
        self.update_dir = os.path.join(os.path.dirname(config_file), 'updates')

    def get_status(self, eventtime):
        return {'slot': self.slot}

    def check_idle(self, gcmd, name):
        print_stats = self.printer.lookup_object('print_stats', None)
        if print_stats is not None:
            state = print_stats.get_status(self.reactor.monotonic())['state']
            if state in ('printing', 'paused'):
                raise gcmd.error("%s: refused while a print is %s" % (name, state))

    cmd_SHEDNAJA_UPDATE_help = "Install the update uploaded to config/updates"
    def cmd_SHEDNAJA_UPDATE(self, gcmd):
        self.check_idle(gcmd, '_SHEDNAJA_UPDATE')
        pattern = ('shednaja-armbian-update*.tar' if os.access(KOBRA_AB, os.X_OK)
                   else 'shednaja-update*.tar')
        name = gcmd.get('FILE', None)
        if name is not None:
            # from the dialog: exactly the bundle it showed, not whatever is newest by now
            if os.path.basename(name) != name or not fnmatch.fnmatch(name, pattern):
                raise gcmd.error("_SHEDNAJA_UPDATE: FILE must be a %s in 'updates'" % (pattern,))
            bundle = os.path.join(self.update_dir, name)
            if not os.path.isfile(bundle):
                raise gcmd.error("_SHEDNAJA_UPDATE: %s is not in 'updates' any more" % (name,))
        else:
            bundles = glob.glob(os.path.join(self.update_dir, pattern))
            if not bundles:
                raise gcmd.error("_SHEDNAJA_UPDATE: no %s in the config folder 'updates'"
                                 " (upload it there in Mainsail)" % (pattern,))
            # the last upload: names carry a commit hash, their order says nothing
            bundle = max(bundles, key=os.path.getmtime)
            name = os.path.basename(bundle)
        try:
            manifest = subprocess.check_output(['tar', '-xOf', bundle, 'manifest'],
                                               stderr=subprocess.STDOUT, timeout=60)
        except (OSError, subprocess.SubprocessError) as e:
            raise gcmd.error("_SHEDNAJA_UPDATE: %s is not a readable bundle: %s" % (name, e))
        build_id = '?'
        for line in manifest.decode(errors='replace').splitlines():
            if line.startswith('build_id='):
                build_id = line[len('build_id='):]
        if not gcmd.get_int('CONFIRM', 0):
            for line in (
                    "action:prompt_begin Install update",
                    "action:prompt_text %s (build %s): the update is checked and installed,"
                    " then the printer restarts by itself (about 5 minutes). Configuration"
                    " and data stay." % (name, build_id),
                    "action:prompt_footer_button Cancel|RESPOND TYPE=command"
                    " MSG=action:prompt_end",
                    "action:prompt_footer_button Install"
                    "|_SHEDNAJA_UPDATE CONFIRM=1 FILE=%s|primary" % (name,),
                    "action:prompt_show"):
                self.gcode.respond_raw("// " + line)
            return
        self.gcode.respond_raw("// action:prompt_end")
        logging.info("kobra_slot: installing update %s (build %s)", name, build_id)
        gcmd.respond_info("Installing %s (build %s); the printer restarts when it is done."
                          " Log: update/last-update.log in the data folder." % (name, build_id))
        # own process (session): on Lite it ends with the PID 1 handover, which stops klippy.
        # Under systemd its own unit, out of klipper.service (a klipper restart would kill it,
        # and it would inherit klippy's OOM protection)
        cmd = [KOBRA_UPDATE, '--yes', '--remove-bundle', bundle]
        if os.access('/usr/bin/systemd-run', os.X_OK):
            cmd = ['/usr/bin/systemd-run', '--unit=kobra-update', '--collect', '--quiet'] + cmd
        with open(os.devnull, 'wb') as null:
            subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=null, stderr=null,
                             start_new_session=True, close_fds=True)

    cmd_ROLLBACK_SYSTEM_help = "Go back to the previous system version (Armbian variant)"
    def cmd_ROLLBACK_SYSTEM(self, gcmd):
        if not os.access(KOBRA_AB, os.X_OK):
            raise gcmd.error("_ROLLBACK_SYSTEM: this system has no second copy to go back to")
        self.check_idle(gcmd, '_ROLLBACK_SYSTEM')
        try:
            status = subprocess.check_output([KOBRA_AB, 'status'], stderr=subprocess.STDOUT,
                                             timeout=10).decode(errors='replace')
        except (OSError, subprocess.SubprocessError) as e:
            raise gcmd.error("_ROLLBACK_SYSTEM: kobra-ab status failed: %s" % (e,))
        roots = dict(l.split(':', 1) for l in status.splitlines()
                     if l.startswith(('root_a:', 'root_b:', 'booted:')))
        booted = roots.get('booted', '').split()
        cur = booted[0] if booted else ''
        other = {'root_a': 'root_b', 'root_b': 'root_a'}.get(cur)
        if other is None or roots.get(other, '').strip() in ('', '(empty)'):
            raise gcmd.error("_ROLLBACK_SYSTEM: no previous system to go back to")
        if not gcmd.get_int('CONFIRM', 0):
            for line in (
                    "action:prompt_begin Go back to the previous system",
                    "action:prompt_text The printer restarts into %s (%s), the system"
                    " that ran before the last update. Configuration and data stay."
                    % (other, roots[other].strip()),
                    "action:prompt_footer_button Cancel|RESPOND TYPE=command"
                    " MSG=action:prompt_end",
                    "action:prompt_footer_button Go back"
                    "|_ROLLBACK_SYSTEM CONFIRM=1|error",
                    "action:prompt_show"):
                self.gcode.respond_raw("// " + line)
            return
        self.gcode.respond_raw("// action:prompt_end")
        gcmd.respond_info("Going back to %s, restarting" % (other,))
        # kobra-ab rollback switches the active root and reboots; its own process (as above)
        subprocess.Popen(['/bin/sh', '-c', 'sleep 2; exec %s rollback' % (KOBRA_AB,)],
                         start_new_session=True, close_fds=True)

    cmd_REBOOT_TO_STOCK_help = "Restart into the stock Anycubic firmware (other slot)"
    def cmd_REBOOT_TO_STOCK(self, gcmd):
        if self.slot not in ('A', 'B'):
            raise gcmd.error("_REBOOT_TO_STOCK: cannot tell the running slot")
        stock = 'A' if self.slot == 'B' else 'B'
        self.check_idle(gcmd, '_REBOOT_TO_STOCK')
        if not gcmd.get_int('CONFIRM', 0):
            for line in (
                    "action:prompt_begin Restart into stock firmware",
                    "action:prompt_text The printer restarts into the stock Anycubic"
                    " firmware (slot %s). ShedNaja stays installed in slot %s;"
                    " switching back needs SSH or the ShedNaja installer on a USB stick."
                    % (stock, self.slot),
                    "action:prompt_footer_button Cancel|RESPOND TYPE=command"
                    " MSG=action:prompt_end",
                    "action:prompt_footer_button Restart into stock"
                    "|_REBOOT_TO_STOCK CONFIRM=1|error",
                    "action:prompt_show"):
                self.gcode.respond_raw("// " + line)
            return
        self.gcode.respond_raw("// action:prompt_end")
        try:
            out = subprocess.check_output([ABCTL, 'other', '--slot=' + self.slot.lower()],
                                          stderr=subprocess.STDOUT)
        except (OSError, subprocess.CalledProcessError) as e:
            raise gcmd.error("_REBOOT_TO_STOCK: kobra-abctl failed: %s" % (e,))
        logging.info("kobra_slot: %s", out.decode(errors='replace').strip())
        gcmd.respond_info("Slot %s selected, restarting into the stock firmware" % (stock,))
        # the reboot runs as its own process: the MCU reset below disconnects the MCUs
        # and klippy's reactor does not survive that (seen: TypeError on serialqueue)
        subprocess.Popen(['/bin/sh', '-c', 'sleep 2; exec /sbin/reboot'],
                         start_new_session=True, close_fds=True)
        # fresh MCUs for stock (see above): each MCU resets itself via its reset command
        try:
            self.printer.send_event("klippy:firmware_restart")
        except Exception:
            logging.exception("kobra_slot: MCU reset failed")

def load_config(config):
    return KobraSlot(config)
