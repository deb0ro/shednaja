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
# [kobra_slot]
#
# [gcode_macro REBOOT_TO_STOCK]
# description: Restart into the stock Anycubic firmware (other slot)
# gcode:
#   _REBOOT_TO_STOCK {rawparams}
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
import subprocess

ABCTL = '/usr/sbin/kobra-abctl'

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

    def get_status(self, eventtime):
        return {'slot': self.slot}

    cmd_REBOOT_TO_STOCK_help = "Restart into the stock Anycubic firmware (other slot)"
    def cmd_REBOOT_TO_STOCK(self, gcmd):
        if self.slot not in ('A', 'B'):
            raise gcmd.error("_REBOOT_TO_STOCK: cannot tell the running slot")
        stock = 'A' if self.slot == 'B' else 'B'
        print_stats = self.printer.lookup_object('print_stats', None)
        if print_stats is not None:
            state = print_stats.get_status(self.reactor.monotonic())['state']
            if state in ('printing', 'paused'):
                raise gcmd.error("_REBOOT_TO_STOCK: refused while a print is %s" % (state,))
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
            out = subprocess.check_output([ABCTL, 'other'], stderr=subprocess.STDOUT)
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
