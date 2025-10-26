```markdown
# ProximityAlert

ProximityAlert is a Classic/TurtleWoW addon that reads pfQuest/pfDB rare mob data and silently scans for rares in your zone. When a rare with stored coordinates is nearby (within the configured approach distance) the addon actively targets and alerts you. It also announces alive finds to party chat.

Usage:
- Place the folder `ProximityAlert` under your World of Warcraft `Interface/AddOns/` directory.
- Start the game and make sure pfQuest / pfDB / pfQuest-turtle addons are loaded.
- Control settings in-game using the slash command:

  /proxalert help
  /proxalert debug on|off
  /proxalert enabled on|off
  /proxalert sounds on|off
  /proxalert distance <0.01..0.5>
  /proxalert status
  /proxalert reset

Defaults:
- debug: off
- enabled: on
- sounds: on
- approachDistance: 0.06

Notes:
- This addon does not ship with sound files; it expects a sound at Interface\\AddOns\\ProximityAlert\\Sounds\\foundrare.wav if you want a custom sound. If the file is missing the addon falls back to a default PlaySound call.
- The addon relies on pfDB/pfQuest data being available at runtime (pfDB.units and pfDB.zones.loc).
```