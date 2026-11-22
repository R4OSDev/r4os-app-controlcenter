# R4OS Control Center

Open Control Center from its desktop shortcut or press Ctrl+Alt+Delete. Auslastung displays the share of available CPU time spent working across all logical processors and per physical core. The RAM row shows managed, free and used physical memory and a colour-coded occupancy bar. Positive occupancy below one percent has a visible fill and the label <1%. The active view refreshes once per second. The CPU chart covers the last 60 seconds. A break in sampling leaves a gap in the chart. Each tab keeps its own scroll position. Tasks lists desktop windows and their focus, program instances, compositor counters and shell status.

Build with `./Build.sh` on Linux or `Build.bat` on Windows.

Memory bandwidth
----------------

While the usage tab has focus, the optional R4DEV DRAM counter reports aggregate physical reads and writes. The app uses elapsed monotonic time between comparable readings. An unavailable memory-bandwidth reading displays “k. A.”. Switching tabs or losing focus returns the counters.

Network and disk activity
-------------------------

Scroll the right side of Auslastung to reach each adapter and whole disk.
The navigation stays in place. The mouse wheel, scroll bar, arrow keys,
Page Up/Down, Home and End move through the readings.

Each adapter shows received and transmitted Ethernet bytes per second. A
known link speed also gives a percentage for each direction. Each disk shows
read and write bytes per second and the percentage of time with at least one
device request in flight. Concurrent requests share that time. Rates use
1024 bytes per KB. A valid idle sample shows zero, and a missing reading
or a new device shows a dash until a comparable interval is available.
These counters share the focused usage tab's existing one-second refresh.

The app embeds Inter for labels and IBM Plex Mono for measurements. Source
revisions and the corresponding Open Font Licenses accompany the font assets.
