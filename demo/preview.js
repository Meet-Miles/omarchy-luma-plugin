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

const list = Model.splitScriptOutput("##luma-status:ok\n" + fs.readFileSync(path.join(dir, "api-list.json"), "utf8"))
const hosted = Model.parseApiEntries(list.payload)

const counts = {}
for (const host of hosted) {
  const detailPath = path.join(dir, "api-detail-" + host.id + ".json")
  if (!fs.existsSync(detailPath)) continue
  const count = Model.guestCountFromDetail(fs.readFileSync(detailPath, "utf8"))
  if (count !== null) counts[host.id] = count
}

const events = Model.futureEvents(Model.mergeHostData(feedEvents, hosted, counts), nowMs, 10)

console.log("bar:   󰃭 " + (Model.barLabel(events[0] || null, nowMs) || "(empty)"))
console.log("panel:")
for (const event of events) {
  const guests = Model.guestLabel(event)
  console.log(
    "  " + Model.dateLabel(event.startMs, nowMs).padEnd(12) +
    Model.timeLabel(event.startMs) + "  " +
    event.name.padEnd(28) +
    event.city.padEnd(12) +
    (event.hosted ? "HOST " + guests : "")
  )
}
if (events.length === 0) console.log("  No events")
