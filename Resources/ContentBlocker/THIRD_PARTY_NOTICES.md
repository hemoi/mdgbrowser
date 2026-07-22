# Content blocker third-party notices

`ads.json`, `trackers.json`, and `cosmetic-lite.json` are derived from the
[EasyList](https://easylist.to/) and [EasyPrivacy](https://easylist.to/) filter
lists, converted from Adblock Plus filter syntax into WebKit's
`WKContentRuleList` JSON schema by `tools/convert_filter_lists.rb`
(conversion log in `manifest.json`; the tool is not part of the shipped app —
it is run manually to refresh the bundled lists:
`ruby tools/convert_filter_lists.rb easylist.txt easyprivacy.txt .`).

- EasyList / EasyPrivacy © The EasyList authors (https://easylist.to/)
- License: dual-licensed under the GNU General Public License v3 (or any
  later version) **or**, at your option, Creative Commons
  Attribution-ShareAlike 3.0 Unported (or any later version).
  - Complete text: `licenses/GPL-3.0.txt`
  - Complete text: `licenses/CC-BY-SA-3.0.txt`
  - Canonical license page: https://easylist.to/pages/licence.html
- Source lists fetched from:
  - https://easylist.to/easylist/easylist.txt
  - https://easylist.to/easylist/easyprivacy.txt
  - Upstream version/commit captured per-fetch in `manifest.json`.

`manifest.json` records the upstream list version, last-modified timestamp,
and commit hash at conversion time, the rule counts per file, and a summary
of what the converter could not translate (unsupported Adblock Plus options,
scriptlet/snippet rules, `:has()`/`:contains()` cosmetic selectors, etc.) —
those lines are dropped rather than guessed at. Redistribution of this data,
modified or not, must retain this notice and the license terms above.

Attribution-ShareAlike requires crediting "The EasyList authors
(https://easylist.to/)" wherever this data (or a derivative of it) is
redistributed.
