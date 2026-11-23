# Class Analytics

A small window for **Azeroth Survivors** that shows your **procs per second**, live. Every talent, armor set, amulet, item and jewel that strikes on its own gets a line: how many times a second it goes off, how many hits it lands, and its share of your damage.

For priests there's more: **Shadowy Apparitions** gets a bar that fills toward its limit of 2 a second, with your Shadow Word: Pain ticks per second beside it.

*Class Analytics was called Apparition Meter until 0.2.0.*

## Install

1. Download **ClassAnalytics-*version*.zip** from the [latest release](https://github.com/zac-omar/ClassAnalytics/releases/latest).
2. Unzip it into your game's `benilla-config\AddOns\` folder. It holds the `ClassAnalytics` folder, ready to go. You should end up with:
   ```
   <game folder>\benilla-config\AddOns\ClassAnalytics\ClassAnalytics.toc
   ```
3. Start a run. If the addon isn't loaded, enable it on the AddOns screen at character select.

To update, delete the old `ClassAnalytics` folder and unzip the new release in its place. Your settings are kept. Using **Code → Download ZIP** instead? That unpacks as `ClassAnalytics-main`: rename the folder to `ClassAnalytics`.

Coming from Apparition Meter? Delete the old `ApparitionMeter` folder.

## What it shows

| Column | What it means |
|---|---|
| **Source** | The talent, set, amulet or item, as the damage meter names it |
| **procs/s** | How many times a second it went off, over the last 10 seconds |
| **hits/s** | How many hits it landed a second. A proc that strikes several enemies is one proc and several hits |
| **dmg** | Its share of your damage, from the damage meter |

- **The most active sources come first.** A source that only does damage over time (a burn or a bleed) shows its ticks a second instead.
- **Your own spells aren't listed;** a setting adds them.
- **The bottom line** counts your procs this run.
- **Paused time** (level-up choices, menus) doesn't count, so it doesn't drag the rates down.

**Your class's block** sits on top:

| Class | What it shows |
|---|---|
| Priest | Shadowy Apparitions, with a bar toward 2 a second |
| Warlock | Nightfall, with a bar toward 2 a second |
| Paladin | The Art of War, with a bar toward 1 a second |
| Hunter | Rapid Fire, with a bar toward 2 a second |
| Mage | Hot Streak, with a bar toward 2 a second |

- **Without that talent** (or as another class), the block shows your busiest proc instead.
- **Under it:** your main damage-over-time spell's ticks a second, such as Shadow Word: Pain, Corruption or Serpent Sting.

## Settings and the minimap button

Open the settings with the **minimap button**, `/ca`, or a **right-click on the window**. You can:
- show the window or lock it in place;
- show or hide your class's block;
- list your own spells too;
- show the minimap button;
- set how many seconds the rates cover and how many sources are listed;
- set how see-through the background is;
- start the count again, or put the window back in the middle.

The minimap button:
- **left-click** opens the settings;
- **right-click** shows or hides the window;
- **drag** moves it anywhere round the minimap's edge, and it stays where you drop it.

Until you drag it, it finds itself a free spot each time, clear of the damage meter's button, the clock and other addons' buttons.

## Commands

| Command | What it does |
|---|---|
| `/ca` | Open or close the settings |
| `/ca minimap` | Show or hide the minimap button |
| `/ca show`, `/ca hide` | Show or hide the window |
| `/ca lock`, `/ca unlock` | Lock it in place, or let it be dragged |
| `/ca center` | Put it back in the middle of the screen |
| `/ca reset` | Start the count again |
| `/ca window 30` | Measure the rates over the last 30 seconds (2 to 60) |
| `/ca rows 12` | Show up to 12 sources (1 to 20) |
| `/ca own` | Also list your own spells |
| `/ca debug` | Show how your recent hits were credited, for bug reports |

## How it counts

- **A proc:** a source's hits that land together count as one proc. If two procs from the same source go off at the very same moment (two enemies exploding at once), they count as one.
- **Shadowy Apparitions** can go off at most once every half second, so the rate can get close to 2 a second but never past it.

If a line you expect never shows up, type `/ca debug` and include what it prints when you report it.
