# Unit tests for klippy/extras/kobra_plr.py with stand-ins for the Klipper objects, no
# printer and no Klipper checkout needed (CI):
#   python3 -m unittest discover -s rootfs/tests -p 'test_*.py'
import importlib.util
import os
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'board', 'kobra_s1', 'overlay', 'usr', 'lib', 'klipper',
                   'klippy', 'extras', 'kobra_plr.py')
_spec = importlib.util.spec_from_file_location('kobra_plr', SRC)
kobra_plr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kobra_plr)


class PrintStats:
    def __init__(self):
        self.state, self.duration = 'standby', 0.

    def get_status(self, eventtime):
        return {'state': self.state, 'total_duration': self.duration}


class Gcode:
    def __init__(self):
        self.scripts = []

    def run_script_from_command(self, script):
        self.scripts.extend(script.split('\n'))

    def respond_raw(self, msg):
        pass


class GCmd:
    def __init__(self, **params):
        self.params = params

    def get_int(self, name, default=None, **kw):
        return int(self.params.get(name, default))

    def get_float(self, name, default=None, **kw):
        return float(self.params.get(name, default))

    def respond_info(self, msg):
        pass

    def error(self, msg):
        return Exception(msg)


class Reactor:
    def monotonic(self):
        return 0.


class Toolhead:
    def get_status(self, eventtime):
        return {'axis_maximum': (250., 250., 250.)}


class Printer:
    def lookup_object(self, name, default=None):
        return default


def make_plr(tmp):
    p = kobra_plr.KobraPLR.__new__(kobra_plr.KobraPLR)
    p.path = os.path.join(tmp, 'power_loss_recovery.json')
    p.print_stats = PrintStats()
    p.last_state = None
    p.resuming = False
    p.gcode = Gcode()
    p.reactor = Reactor()
    p.toolhead = Toolhead()
    p.printer = Printer()
    p.probe_temp = 140.
    return p


class WatchState(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = make_plr(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def save(self, age):
        self.p._write({'version': 1, 'saved': time.time() - age})

    def step(self, state, duration=0.):
        self.p.print_stats.state, self.p.print_stats.duration = state, duration
        self.p._watch_state(0.)

    def saved(self):
        return os.path.exists(self.p.path)

    def test_new_print_drops_stale_state(self):
        self.save(3600)
        self.step('standby')
        self.step('printing', 5.)
        self.assertFalse(self.saved())

    def test_new_print_keeps_its_own_early_save(self):
        self.step('standby')
        self.save(1)    # saved 1 s ago by the print that started 5 s ago
        self.step('printing', 5.)
        self.assertTrue(self.saved())

    def test_pause_and_resume_keep_state(self):
        self.step('standby')
        self.save(1)
        self.step('printing', 5.)
        self.step('paused', 50.)
        self.step('printing', 60.)
        self.assertTrue(self.saved())

    def test_own_resume_keeps_state(self):
        self.save(3600)
        self.step('standby')
        self.p.resuming = True
        self.step('printing', 2.)
        self.assertTrue(self.saved())
        self.assertFalse(self.p.resuming)

    def test_cancel_and_complete_clear(self):
        for end in ('cancelled', 'complete'):
            self.step('standby')
            self.save(1)
            self.step('printing', 5.)
            self.step(end)
            self.assertFalse(self.saved(), end)

    def test_error_keeps_state(self):
        self.step('standby')
        self.save(1)
        self.step('printing', 5.)
        self.step('error')
        self.assertTrue(self.saved())


class Resume(unittest.TestCase):
    def test_speed_is_restored_as_given(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = make_plr(tmp)
            open(os.path.join(tmp, 'part.gcode'), 'w').close()
            p.sdcard = type('SD', (), {'sdcard_dirname': tmp})()
            p._write({
                'version': 1, 'saved': time.time(), 'filename': 'part.gcode',
                'file_position': 1234, 'layer': 7, 'total_layer': 20,
                'gcode_position': [10., 20., 1.4, 100.], 'kinematic_z': 1.4,
                'homing_origin': [0., 0., 0.], 'absolute_coordinates': True,
                'absolute_extrude': True, 'speed': 6000., 'speed_factor': 1.,
                'extrude_factor': 1., 'extruder_target': 220., 'bed_target': 60.,
                'pressure_advance': 0.04, 'smooth_time': 0.04, 'max_accel': 10000.,
                'square_corner_velocity': 5., 'minimum_cruise_ratio': 0.5,
                'fans': {}, 'mesh': None, 'objects': {'objects': [], 'excluded': []}})
            p.cmd_RESUME_INTERRUPTED(GCmd(CONFIRM=1, PROBE=0, PURGE=0))
            # gcode_move's 'speed' is already the G-code F value (mm/min)
            self.assertIn('G1 F6000.0', p.gcode.scripts)
            self.assertIn('M26 S1234', p.gcode.scripts)
            self.assertEqual(p.gcode.scripts[-1], 'M24')
            self.assertTrue(p.resuming)


if __name__ == '__main__':
    unittest.main()
