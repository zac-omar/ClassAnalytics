# Apparition Meter

A small window for **Azeroth Survivors** that counts your **Shadowy Apparitions** procs (the free Mind Blasts) and shows how many you get per second, live.

## Install

1. Download **ApparitionMeter-*version*.zip** from the [latest release](https://github.com/zac-omar/ApparitionMeter/releases/latest).
2. Unzip it into your game's `benilla-config\AddOns\` folder. It holds the `ApparitionMeter` folder, ready to go. You should end up with:
   ```
   <game folder>\benilla-config\AddOns\ApparitionMeter\ApparitionMeter.toc
   ```
3. Start a run. If the addon isn't loaded, enable it on the AddOns screen at character select.

To update, delete the old `ApparitionMeter` folder and unzip the new release in its place. Your settings are kept. Using **Code → Download ZIP** instead? That unpacks as `ApparitionMeter-main`: rename the folder to `ApparitionMeter`.

## What it shows

- **The big number:** procs per second over the last 10 seconds. The bar under it fills toward 2 a second, the most Shadowy Apparitions can give.
- **Last 60 s** and **this run:** the same rate over longer stretches, and how many procs you've had this run.
- **Shadow Word: Pain ticks per second:** every tick has the chance to set off an apparition, so this is what drives the rate.

Paused time (level-up choices, menus) doesn't count, so it doesn't drag the rate down. The window shows on priests, or once it sees a proc.

## Commands

| Command | What it does |
|---|---|
| `/apm show`, `/apm hide` | Show or hide the window |
| `/apm lock`, `/apm unlock` | Lock it in place, or let it be dragged |
| `/apm center` | Put it back in the middle of the screen |
| `/apm reset` | Start the count again |
| `/apm window 30` | Measure the big number over the last 30 seconds (2 to 60) |
| `/apm debug` | Show how your Mind Blast hits are credited, for bug reports |

## How it counts

- **A proc** is a hit credited to Shadowy Apparitions. If one free Mind Blast hits several enemies, it still counts once.
- **The 2-a-second limit:** after each proc, nothing more can come for half a second. That's why the rate can only get close to 2 a second, never past it.

If the count stays at 0 while apparitions are clearly firing, type `/apm debug` and include what it prints when you report it.
