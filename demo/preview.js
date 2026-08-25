#!/usr/bin/env node
// Textual preview of the widget against fixture data: prints the bar label
// and the panel rows that the fixtures produce. Used by demo/run as a
// smoke check, and useful on machines without the Omarchy shell.
"use strict"

const fs = require("fs")
const path = require("path")
const Model = require("../Model.js")

const dir = process.argv[2] || path.join(__dirname, "fixtures")
const nowMs = Date.now()

const feed = fs.readFileSync(path.join(dir, "feed.ics"), "utf8")
const feedEvents = Model.parseIcs(feed)

const events = Model.futureEvents(feedEvents, nowMs, 10)

console.log("bar:   ✦  (Luma mark only · tooltip: " + (Model.barLabel(events[0] || null, nowMs) || "Luma") + ")")
console.log("panel:")
for (const event of events) {
  console.log(
    "  " + Model.dateLabel(event.startMs, nowMs).padEnd(12) +
    Model.timeLabel(event.startMs) + "  " +
    event.name.padEnd(28) +
    event.city
  )
}
if (events.length === 0) console.log("  No events")
