# Power-loss recovery: resume a print that a power cut (or a klippy crash) interrupted.
#
# The Kobra S1 has no power-fail input, so the state is saved ahead of time: at every layer
# change (SET_PRINT_STATS_INFO CURRENT_LAYER=..., from the slicer's layer-change G-code) the
# file and position of the next line, the G-code position and modes, temperatures, fans,
# pressure advance, the bed mesh and the object list go to a JSON file, written atomically
# (temp file, fsync, rename, fsync of the directory). A finished or cancelled print removes
# the file; after a power cut it stays and the next start offers to resume.
#
# _RESUME_INTERRUPTED (wrapped by RESUME_INTERRUPTED in kobra_macros.cfg) opens a
# confirmation dialog; with CONFIRM=1 it
#   1. heats the bed, takes the saved Z as the current one, lifts 5 mm, homes X and Y only
#      (Z cannot be homed: the print is in the way)
#   2. purges and wipes the nozzle (PURGE=mm, 0 = skip) and, with PROBE=1 (default),
#      probes the bed next to the print to measure the real Z, corrects it (a power cut
#      mid-layer leaves Z off by the bed mesh compensation or a z-hop)
#   3. heats the nozzle, restores offsets, modes, fans, pressure advance, mesh, excluded
#      objects, moves to the saved position and continues the file at the saved layer.
# _CLEAR_INTERRUPTED discards the saved state.
#
# [kobra_plr]
# path: ~/printer_data/power_loss_recovery.json
# probe_temp: 140      nozzle temperature for wiping and probing
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import json
import logging
import os
import time

LIFT = 5.            # mm above the saved Z for travel over the print
PROBE_CLEARANCE = 40.  # mm between the print's outline and the probe point (room for
                       # the hotend and its fan duct next to a tall print)
MAX_Z_CORRECTION = 3.  # mm; a bigger difference means something else is wrong

class KobraPLR:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.path = os.path.expanduser(
            config.get('path', '~/printer_data/power_loss_recovery.json'))
        self.probe_temp = config.getfloat('probe_temp', 140., minval=0.)
        self.gcode = self.printer.lookup_object('gcode')
        self.print_stats = self.printer.load_object(config, 'print_stats')
        self.sdcard = self.printer.load_object(config, 'virtual_sdcard')
        self.prev_set_info = None
        self.last_state = None
        self.saved_layer = None
        self.gcode.register_command('_RESUME_INTERRUPTED', self.cmd_RESUME_INTERRUPTED,
                                    desc=self.cmd_RESUME_INTERRUPTED_help)
        self.gcode.register_command('_CLEAR_INTERRUPTED', self.cmd_CLEAR_INTERRUPTED,
                                    desc=self.cmd_CLEAR_INTERRUPTED_help)
        self.printer.register_event_handler('klippy:connect', self._handle_connect)
        self.printer.register_event_handler('klippy:ready', self._handle_ready)

    # --- saving ---------------------------------------------------------------------
    def _handle_connect(self):
        self.toolhead = self.printer.lookup_object('toolhead')
        self.gcode_move = self.printer.lookup_object('gcode_move')
        # wrap SET_PRINT_STATS_INFO: the layer change is where the state is saved
        self.prev_set_info = self.gcode.register_command('SET_PRINT_STATS_INFO', None)
        self.gcode.register_command('SET_PRINT_STATS_INFO', self.cmd_SET_PRINT_STATS_INFO,
                                    desc="Pass slicer info like layer act and total to"
                                    " klipper (also saves the power-loss recovery state)")

    def _handle_ready(self):
        self.reactor.register_timer(self._watch_state, self.reactor.NOW)
        state = self._load()
        if state is not None:
            logging.info("kobra_plr: interrupted print found: %s layer %s",
                         state.get('filename'), state.get('layer'))
            self.reactor.register_callback(self._announce)

    def _announce(self, eventtime):
        state = self._load()
        if state is None:
            return
        try:
            self.gcode.run_script("M117 Interrupted print: RESUME_INTERRUPTED")
        except Exception:
            logging.exception("kobra_plr: M117")
        # frontends connect a little later than klippy gets ready
        self.reactor.register_timer(self._show_prompt_timer, eventtime + 30.)

    def _show_prompt_timer(self, eventtime):
        if self._load() is not None and not self._busy():
            self._prompt(self._load())
        return self.reactor.NEVER

    def cmd_SET_PRINT_STATS_INFO(self, gcmd):
        self.prev_set_info(gcmd)
        layer = gcmd.get_int('CURRENT_LAYER', None)
        if layer is None:
            return
        try:
            self._save(layer)
        except Exception:
            logging.exception("kobra_plr: saving the state failed")

    def _save(self, layer):
        eventtime = self.reactor.monotonic()
        ps = self.print_stats.get_status(eventtime)
        if ps['state'] != 'printing' or not self.sdcard.is_active():
            return
        gm = self.gcode_move.get_status(eventtime)
        th = self.toolhead.get_status(eventtime)
        extruder = self.printer.lookup_object('extruder').get_status(eventtime)
        bed = self.printer.lookup_object('heater_bed', None)
        fans = {}
        fan = self.printer.lookup_object('fan', None)
        if fan is not None:
            fans['fan'] = fan.get_status(eventtime)['speed']
        for name, obj in self.printer.lookup_objects('fan_generic'):
            fans[name] = obj.get_status(eventtime)['speed']
        mesh = None
        bed_mesh = self.printer.lookup_object('bed_mesh', None)
        if bed_mesh is not None and bed_mesh.get_mesh() is not None:
            z_mesh = bed_mesh.get_mesh()
            mesh = {'name': z_mesh.get_profile_name(),
                    'params': dict(z_mesh.get_mesh_params()),
                    'matrix': z_mesh.get_probed_matrix()}
        objects = {'objects': [], 'excluded': []}
        exclude = self.printer.lookup_object('exclude_object', None)
        if exclude is not None:
            es = exclude.get_status(eventtime)
            objects = {'objects': es['objects'], 'excluded': es['excluded_objects']}
        state = {
            'version': 1,
            'saved': time.time(),
            'filename': ps['filename'],
            'file_position': self.sdcard.get_file_position(),
            'layer': layer,
            'total_layer': (ps.get('info') or {}).get('total_layer'),
            'print_duration': ps['print_duration'],
            'gcode_position': list(gm['gcode_position']),
            'kinematic_z': self.toolhead.get_position()[2],
            'homing_origin': list(gm['homing_origin']),
            'absolute_coordinates': gm['absolute_coordinates'],
            'absolute_extrude': gm['absolute_extrude'],
            'speed': gm['speed'],
            'speed_factor': gm['speed_factor'],
            'extrude_factor': gm['extrude_factor'],
            'extruder_target': extruder['target'],
            'bed_target': bed.get_status(eventtime)['target'] if bed else 0.,
            'pressure_advance': extruder.get('pressure_advance'),
            'smooth_time': extruder.get('smooth_time'),
            'max_accel': th.get('max_accel'),
            'square_corner_velocity': th.get('square_corner_velocity'),
            'minimum_cruise_ratio': th.get('minimum_cruise_ratio'),
            'fans': fans,
            'mesh': mesh,
            'objects': objects,
        }
        self._write(state)
        self.saved_layer = layer

    def _write(self, state):
        d = os.path.dirname(self.path)
        os.makedirs(d, exist_ok=True)
        tmp = self.path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(state, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _load(self):
        try:
            with open(self.path) as f:
                state = json.load(f)
        except (OSError, ValueError):
            return None
        return state if isinstance(state, dict) and state.get('version') == 1 else None

    def _clear(self):
        try:
            os.remove(self.path)
        except OSError:
            pass

    def _watch_state(self, eventtime):
        # a print that ends normally or is cancelled leaves nothing to resume; an
        # error (e.g. an MCU shutdown) keeps the state, it may be worth resuming
        state = self.print_stats.get_status(eventtime)['state']
        if state != self.last_state:
            if state in ('complete', 'cancelled') and self.last_state is not None:
                self._clear()
            self.last_state = state
        return eventtime + 2.

    def _busy(self):
        state = self.print_stats.get_status(self.reactor.monotonic())['state']
        return state in ('printing', 'paused')

    # --- resuming -------------------------------------------------------------------
    def _prompt(self, state):
        total = state.get('total_layer')
        layer = "%s/%s" % (state['layer'], total) if total else str(state['layer'])
        saved = time.strftime('%Y-%m-%d %H:%M', time.localtime(state.get('saved', 0)))
        for line in (
                "action:prompt_begin Interrupted print",
                "action:prompt_text %s was interrupted at layer %s (Z %.2f, saved %s)."
                % (state['filename'], layer, state['gcode_position'][2], saved),
                "action:prompt_text Resume heats up, homes X/Y, cleans the nozzle, probes"
                " next to the print and continues from the start of that layer. The print"
                " must still be stuck to the bed.",
                "action:prompt_footer_button Discard|_CLEAR_INTERRUPTED|error",
                "action:prompt_footer_button Later|RESPOND TYPE=command MSG=action:prompt_end",
                "action:prompt_footer_button Resume|_RESUME_INTERRUPTED CONFIRM=1|primary",
                "action:prompt_show"):
            self.gcode.respond_raw("// " + line)

    cmd_CLEAR_INTERRUPTED_help = "Discard the saved state of an interrupted print"
    def cmd_CLEAR_INTERRUPTED(self, gcmd):
        self.gcode.respond_raw("// action:prompt_end")
        self._clear()
        self.gcode.run_script_from_command("M117")
        gcmd.respond_info("Interrupted print discarded")

    cmd_RESUME_INTERRUPTED_help = "Resume a print interrupted by a power cut"
    def cmd_RESUME_INTERRUPTED(self, gcmd):
        state = self._load()
        if state is None:
            raise gcmd.error("No interrupted print saved")
        if self._busy():
            raise gcmd.error("Refused while a print is running or paused")
        fname = os.path.join(self.sdcard.sdcard_dirname, state['filename'])
        if not os.path.isfile(fname):
            raise gcmd.error("File %s not found" % (state['filename'],))
        if not gcmd.get_int('CONFIRM', 0):
            self._prompt(state)
            return
        self.gcode.respond_raw("// action:prompt_end")
        do_probe = gcmd.get_int('PROBE', 1)
        purge = gcmd.get_float('PURGE', 15., minval=0.)
        run = self.gcode.run_script_from_command
        zmax = self.toolhead.get_status(self.reactor.monotonic())['axis_maximum'][2]
        ext_t, bed_t = state['extruder_target'], state['bed_target']
        x, y, z, e = state['gcode_position']
        lift_k = min(state['kinematic_z'] + LIFT, zmax)
        gcmd.respond_info("Resuming %s at layer %s" % (state['filename'], state['layer']))

        # 1. bed heating, Z taken over from the saved state, X/Y homing above the print
        run("M117 Resuming print\nBED_MESH_CLEAR\nSET_GCODE_OFFSET X=0 Y=0 Z=0\n"
            "M140 S%.1f\nM104 S%.1f" % (bed_t, self.probe_temp if do_probe else ext_t))
        run("SET_KINEMATIC_POSITION Z=%.4f SET_HOMED=Z\nG90\nG1 Z%.3f F600\nG28 X Y"
            % (state['kinematic_z'], lift_k))
        if bed_t > 0:
            run("TEMPERATURE_WAIT SENSOR=heater_bed MINIMUM=%.1f" % (bed_t - 1,))
        # 2. clean nozzle; the mesh is needed for the probe comparison and the print
        self._restore_mesh(state)
        if purge > 0:
            run("_PARK_BIN\n_NOZZLE_WAIT TEMP=%.1f\nM83\nG1 E%.2f F300\nG1 E-1 F1800\n"
                "_KNOCK_OFF" % (ext_t, purge))
        if do_probe:
            run("M106 S255\n_WIPE_NOZZLE\n_NOZZLE_WAIT TEMP=%.1f\n_WIPE_NOZZLE\nM107"
                % (self.probe_temp,))
            self._probe_z(gcmd, state)
        # 3. print temperature over the wiper, then the saved state
        run("_HEAT_POS\n_NOZZLE_WAIT TEMP=%.1f\n_WIPE_NOZZLE" % (ext_t,))
        self._restore_modes(state)
        run("G90\nG1 X%.3f Y%.3f F12000\nG1 Z%.3f F600" % (x, y, z))
        if state['absolute_extrude']:
            run("M83\nG1 E1 F1800\nM82\nG92 E%.5f" % (e,))
        else:
            run("M83\nG1 E1 F1800")
        if not state['absolute_coordinates']:
            run("G91")
        run("G1 F%.1f" % (state['speed'] * 60.,))
        run("M117\nM23 %s\nM26 S%d" % (state['filename'], state['file_position']))
        # M23 resets the slicer info; the total is set again (CURRENT_LAYER would save a
        # state before the file position is in effect, it comes with the next layer)
        if state.get('total_layer'):
            run("SET_PRINT_STATS_INFO TOTAL_LAYER=%d" % (state['total_layer'],))
        run("M24")

    def _restore_mesh(self, state):
        mesh = state.get('mesh')
        bed_mesh = self.printer.lookup_object('bed_mesh', None)
        if not mesh or bed_mesh is None:
            return
        from . import bed_mesh as bm
        z_mesh = bm.ZMesh(mesh['params'], mesh['name'])
        z_mesh.build_mesh(mesh['matrix'])
        bed_mesh.set_mesh(z_mesh)

    def _probe_point(self, state):
        # bounding box of the printed objects (or of the mesh), then a point
        # PROBE_CLEARANCE outside it, front side first
        pts = [p for o in state['objects']['objects'] for p in o.get('polygon', [])]
        if not pts and state.get('mesh'):
            p = state['mesh']['params']
            pts = [(p['min_x'], p['min_y']), (p['max_x'], p['max_y'])]
        if not pts:
            return None
        min_x = min(p[0] for p in pts); max_x = max(p[0] for p in pts)
        min_y = min(p[1] for p in pts); max_y = max(p[1] for p in pts)
        cx, cy = (min_x + max_x) / 2., (min_y + max_y) / 2.
        c = PROBE_CLEARANCE
        for px, py in ((cx, min_y - c), (min_x - c, cy), (max_x + c, cy),
                       (cx, max_y + c)):
            px = min(max(px, 10.), 240.)
            py = min(max(py, 10.), 240.)
            if min_x - c / 2 <= px <= max_x + c / 2 and min_y - c / 2 <= py <= max_y + c / 2:
                continue
            return px, py
        return None

    def _probe_z(self, gcmd, state):
        point = self._probe_point(state)
        if point is None:
            gcmd.respond_info("No free spot next to the print to probe: keeping the saved Z")
            return
        px, py = point
        run = self.gcode.run_script_from_command
        lift = self.toolhead.get_position()[2]
        run("G90\nG1 X%.2f Y%.2f F12000\nPROBE" % (px, py))
        # the bed Z of the contact, as BED_MESH_CALIBRATE stores it (no probe z_offset)
        result = self.printer.lookup_object('probe').get_status(
            self.reactor.monotonic())['last_probe_position'][2]
        bed_mesh = self.printer.lookup_object('bed_mesh', None)
        z_mesh = bed_mesh.get_mesh() if bed_mesh is not None else None
        expected = z_mesh.calc_z(px, py) if z_mesh is not None else 0.
        delta = result - expected
        logging.info("kobra_plr: probe at %.1f,%.1f: %.4f, mesh %.4f, Z correction %.4f",
                     px, py, result, expected, -delta)
        if abs(delta) > MAX_Z_CORRECTION:
            run("TURN_OFF_HEATERS")
            raise gcmd.error("Z differs by %.2f mm from the saved state: not resuming"
                             % (delta,))
        cur = self.toolhead.get_position()[2]
        run("SET_KINEMATIC_POSITION Z=%.4f SET_HOMED=Z\nG1 Z%.3f F600"
            % (cur - delta, lift))
        gcmd.respond_info("Z corrected by %.3f mm (probe next to the print)" % (-delta,))

    def _restore_modes(self, state):
        run = self.gcode.run_script_from_command
        ox, oy, oz = state['homing_origin'][:3]
        lines = ["SET_GCODE_OFFSET X=%.4f Y=%.4f Z=%.4f" % (ox, oy, oz),
                 "M220 S%.1f" % (state['speed_factor'] * 100.,),
                 "M221 S%.1f" % (state['extrude_factor'] * 100.,)]
        if state.get('pressure_advance') is not None:
            lines.append("SET_PRESSURE_ADVANCE ADVANCE=%.4f SMOOTH_TIME=%.4f"
                         % (state['pressure_advance'], state['smooth_time']))
        if state.get('max_accel'):
            lim = "SET_VELOCITY_LIMIT ACCEL=%.1f SQUARE_CORNER_VELOCITY=%.2f" % (
                state['max_accel'], state['square_corner_velocity'])
            if state.get('minimum_cruise_ratio') is not None:
                lim += " MINIMUM_CRUISE_RATIO=%.3f" % (state['minimum_cruise_ratio'],)
            lines.append(lim)
        for name, speed in state.get('fans', {}).items():
            if name == 'fan':
                lines.append("M106 S%d" % (round(speed * 255.),))
            else:
                lines.append("SET_FAN_SPEED FAN=%s SPEED=%.3f" % (name.split()[-1], speed))
        for o in state['objects']['objects']:
            d = "EXCLUDE_OBJECT_DEFINE NAME=%s" % (o['name'],)
            if 'center' in o:
                d += " CENTER=%s" % (",".join("%.3f" % v for v in o['center']),)
            if 'polygon' in o:
                d += " POLYGON=%s" % (json.dumps(o['polygon'], separators=(',', ':')),)
            lines.append(d)
        for name in state['objects']['excluded']:
            lines.append("EXCLUDE_OBJECT NAME=%s" % (name,))
        run("\n".join(lines))

def load_config(config):
    return KobraPLR(config)
