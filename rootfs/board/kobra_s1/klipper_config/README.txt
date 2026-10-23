ShedNaja's Klipper configuration, shipped with the system image (read-only).

printer.cfg includes these files from /usr/share/shednaja/klipper, so a ShedNaja update
brings their fixes and new features. They cannot be edited here: to change something,
add the section or option to printer.cfg after the [include ...] lines; a later value
overrides the one from these files (for a [gcode_macro], redefine its gcode there).
