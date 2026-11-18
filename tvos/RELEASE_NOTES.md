# Ant Streams TV 1.0 (10)

- TV show search covers every visible series category, not only the category on screen. Movie and live search do the same when a provider's unscoped catalog is only one category. Results stay in memory for the session. Hidden categories, U.S.-only, and hide-non-English still apply.

# Ant Streams TV 1.0 (8)

- Improved player focus, play/pause, touch timeline scrubbing and timeline shuttle controls.
- Reduced guide browsing stalls and repeated scrolling.
- Grouped duplicate TV-show search results with a country/version picker.
- Improved English/US matching and enabled a setting to hide non-English categories by default.
- Preserved the selected provider across relaunches, including local/profile/account selection.
- Preserved live TV, multiview and saved playback progress.

Validation: 23 simulator regression tests passed, covering provider persistence, catalog filtering and series grouping. Additional guide, player, search and cold-relaunch checks passed during development. Latest local Apple TV build was confirmed working by the owner. TestFlight testers should check their own provider, remote navigation, seeking, multiview and provider retention after relaunch.
