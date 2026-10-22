# Filament presence switch read through an ADC pin.
#
# The Kobra S1 toolhead runout sensor (nozzle_mcu:PB0) is analog: a spring-loaded swing
# piece below the extruder gears, about 2.66 V with filament fed through and 2.93 V without,
# both above the MCU's logic-high level, so a plain [filament_switch_sensor] always reports
# "detected". Stock GoKlipper reads it as ADC.
# This module compares the voltage with a threshold (with hysteresis) and drives the
# standard RunoutHelper, so runout_gcode / insert_gcode / pause_on_runout and
# QUERY_FILAMENT_SENSOR / SET_FILAMENT_SENSOR behave like [filament_switch_sensor].
# The object is also registered as "filament_switch_sensor <name>", so macros, Mainsail,
# HelixScreen and the ACE driver find it under the usual name.
#
# [adc_filament_switch filament_runout_nozzle]
# switch_pin: nozzle_mcu:PB0
# threshold: 2.78            # volts
# #hysteresis: 0.04          # volts, each side of the threshold
# #debounce_time: 0.5        # seconds a new state must last before it counts
# present_above: False      # Kobra S1: filament present when the voltage is BELOW it
# #adc_voltage: 3.3
# (+ all RunoutHelper options: pause_on_runout, runout_gcode, insert_gcode, ...)
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
from . import filament_switch_sensor

REPORT_TIME = 0.050
SAMPLE_TIME = 0.001
SAMPLE_COUNT = 8

class ADCFilamentSwitch:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.name = config.get_name().split()[-1]
        adc_voltage = config.getfloat('adc_voltage', 3.3, above=0.)
        threshold = config.getfloat('threshold', above=0., below=adc_voltage)
        hysteresis = config.getfloat('hysteresis', 0.04, minval=0.)
        # the voltage moves by up to ~0.15 V for a moment during fast moves (seen during
        # G28), so a new state has to last this long before it counts
        self.debounce_time = config.getfloat('debounce_time', 0.5, minval=0.)
        self.present_above = config.getboolean('present_above', True)
        self.adc_voltage = adc_voltage
        # thresholds as ADC fractions (0..1)
        self.upper = (threshold + hysteresis) / adc_voltage
        self.lower = (threshold - hysteresis) / adc_voltage
        self.runout_helper = filament_switch_sensor.RunoutHelper(config)
        self.present = None
        self.candidate = None
        self.candidate_since = 0.
        self.last_value = 0.
        self.min_value = 1.
        self.max_value = 0.
        ppins = self.printer.lookup_object('pins')
        self.mcu_adc = ppins.setup_pin('adc', config.get('switch_pin'))
        self.mcu_adc.setup_adc_sample(REPORT_TIME, SAMPLE_TIME, SAMPLE_COUNT)
        self.mcu_adc.setup_adc_callback(self._adc_callback)
        self.printer.add_object('filament_switch_sensor ' + self.name, self)

    def _adc_callback(self, samples):
        # runs in the MCU response thread: hand state changes to the reactor
        read_time, value = samples[-1]
        self.last_value = value
        self.min_value = min(self.min_value, value)
        self.max_value = max(self.max_value, value)
        if value >= self.upper:
            above = True
        elif value <= self.lower:
            above = False
        else:
            # inside the hysteresis band: a pending change has not held
            self.candidate = None
            return
        present = above == self.present_above
        if present == self.present:
            self.candidate = None
            return
        if present != self.candidate:
            self.candidate = present
            self.candidate_since = read_time
        # the first reading after start-up counts at once
        if (self.present is not None
                and read_time - self.candidate_since < self.debounce_time):
            return
        self.present = present
        self.candidate = None
        logging.info("adc_filament_switch %s: %s (%.3f V)", self.name,
                     "present" if present else "absent",
                     value * self.adc_voltage)
        self.reactor.register_async_callback(
            lambda et, p=present: self.runout_helper.note_filament_present(
                et, p))

    def get_status(self, eventtime):
        status = self.runout_helper.get_status(eventtime)
        status['voltage'] = round(self.last_value * self.adc_voltage, 3)
        status['voltage_min'] = round(self.min_value * self.adc_voltage, 3)
        status['voltage_max'] = round(self.max_value * self.adc_voltage, 3)
        return status

def load_config_prefix(config):
    return ADCFilamentSwitch(config)
