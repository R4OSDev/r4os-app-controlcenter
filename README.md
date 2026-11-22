# R4OS Control Center

Open Control Center from its desktop shortcut or press Ctrl+Alt+Delete. Auslastung displays the share of available CPU time spent working across all logical processors and per physical core. The RAM row shows managed, free and used physical memory and a colour-coded occupancy bar. Positive occupancy below one percent has a visible fill and the label <1%. The active view refreshes once per second. Tasks lists windows, running programs and compositor counters.

Build with `./Build.sh` on Linux or `Build.bat` on Windows.

Memory bandwidth
----------------

While the usage tab has focus, the optional R4DEV DRAM counter reports aggregate physical reads and writes. The app uses elapsed monotonic time between comparable readings. Missing readings display a dash. Switching tabs or losing focus returns the counters.
