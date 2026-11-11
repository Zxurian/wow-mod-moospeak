# MooSpeak

A World of Warcraft addon that turns your chat into Tauren mooing.

- **Minimap button** (the Polymorph: Cow icon, greyed out while off):
  left-click turns mooing on/off, right-click opens the options, drag to
  move it. On Retail/Forever it's also in the addon compartment menu.
- **Options** (`/moospeak options`): turn mooing on/off, show/hide the
  minimap button, honorary Tauren status, and a live preview box.
- **`/moospeak`** toggles it (also `/mspeak`). Saved per character, off by default.
- **Not a Tauren?** Nobody is stopped, but turning MooSpeak on as another
  race gets you "You're not a Tauren!" from the Earth Mother. Choose
  *Moo anyway* to become an honorary Tauren (remembered per character,
  revocable in options), or *I'm no cow* to get only a confused bleat.
- While on, what you type in Say, Yell, Party, Raid, Raid Warning, Instance,
  Guild, Officer, Whisper and numbered channels is sent as moos:
  `Hey, anyone want to run Deadmines? I'll tank!` →
  `mMOoo mMMOoO moooO moo, MMOoo mooOo … mmmoo? MoOoO mOOoo Mooo moO mmoo!`
- Everyone who has MooSpeak installed (on or off) sees
  `MooSpeak: Hey, anyone want to run Deadmines? I'll tank!`
- `/moospeak preview <text>` shows the moos without sending anything.

(`/moo` is left alone because it is the built-in cow emote.)

## Supported clients

One addon folder works in all of these; they share the same chat code.

| Client | Interface |
|---|---|
| WoW Forever (1.60.1) | 16001 |
| Retail / Midnight (12.1.5) | 120105 |
| Mists of Pandaria Classic (5.5.4) | 50504 |
| TBC Anniversary (2.5.6) | 20506 |
| Classic Era (1.15.9) | 11509 |

Install by copying the `MooSpeak` folder into that client's
`Interface/AddOns` directory. After a game patch, if the addon shows as
out of date, add the new number from `/dump select(4, GetBuildInfo())`
to the `## Interface:` line in `MooSpeak.toc`.

## How it works

Moos only have four letters, so instead of translating word-for-word the
text is compressed and the bits are stored in the moos themselves. No
hidden channel or syncing between players is needed.

- Every moo word is 1–4 M's followed by 2–6 O's. How many of each, and which
  letters are capitalized, carry the data. Lowercase and short runs are
  most likely, so it still reads like mooing.
- Punctuation, item/spell links and raid markers (`{skull}`) are copied
  through exactly where you typed them. Apostrophes and hyphens inside a
  word (`I'll`, `re-run`) are hidden in the moos.
- Each line carries a 12-bit checksum, and a line only translates if it
  re-encodes exactly. Players typing "moo moo" by hand are never
  "translated".
- Moos are about 2.5–4× longer than the text. Anything over the 255-byte
  chat limit is split over several lines, and each line translates on its own.

## Limitations

- **Combat lockdown (Forever and Retail):** during combat in instances,
  addons can't read chat or send extra lines. Incoming moos show untranslated,
  and a message that needs more than one line is sent as typed (you get a
  notice). One-line messages are still mooed.
- **Cross-faction /say** is scrambled by the server, so those moos cannot be
  translated.
- Chat bubbles show the moos; only the chat window shows translations.
- Messages sent directly by a slash command in one go (for example
  `/r text` or `/channel 1 text`) bypass the edit box hook and are sent as typed.
  Press R, or use `/1 text`, and they are mooed.
- Battle.net whispers and emotes are never mooed.
- Changing any table in `Codec.lua` changes the encoding. Bump
  `VERSION_SEED` so mismatched versions reject each other's lines.

## Tests

The codec and the chat hooks are tested outside the game with Lua 5.1
(the version WoW uses):

    lua5.1 tests/run.lua
