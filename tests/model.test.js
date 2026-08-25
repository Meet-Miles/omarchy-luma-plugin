"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("fs")
const path = require("path")
const Model = require("../Model.js")

const fixtureIcs = fs.readFileSync(path.join(__dirname, "..", "demo", "fixtures", "feed.ics"), "utf8")

test("splitScriptOutput separates the status line from the payload", () => {
  const out = Model.splitScriptOutput("##luma-status:ok\nBEGIN:VCALENDAR\nEND:VCALENDAR")
  assert.equal(out.status, "ok")
  assert.equal(out.payload, "BEGIN:VCALENDAR\nEND:VCALENDAR")
})

test("splitScriptOutput reports error on malformed output", () => {
  assert.equal(Model.splitScriptOutput("garbage").status, "error")
  assert.equal(Model.splitScriptOutput("").status, "error")
})

test("splitScriptOutput passes bare status tokens", () => {
  assert.equal(Model.splitScriptOutput("##luma-status:missing\n").status, "missing")
  assert.equal(Model.splitScriptOutput("##luma-status:insecure").status, "insecure")
})

test("unfoldIcs joins folded lines", () => {
  const lines = Model.unfoldIcs("SUMMARY:Part one\r\n  and part two\r\nURL:https://lu.ma/x")
  assert.equal(lines[0], "SUMMARY:Part one and part two")
  assert.equal(lines[1], "URL:https://lu.ma/x")
})

test("parseIcsLine reads name, params, and value", () => {
  const parsed = Model.parseIcsLine("DTSTART;TZID=Europe/Amsterdam:20260901T180000")
  assert.equal(parsed.name, "DTSTART")
  assert.equal(parsed.params.TZID, "Europe/Amsterdam")
  assert.equal(parsed.value, "20260901T180000")
})

test("parseIcsDate reads UTC datetimes", () => {
  assert.equal(Model.parseIcsDate("20270914T170000Z", {}), Date.UTC(2027, 8, 14, 17, 0, 0))
})

test("parseIcsDate reads all-day dates as local midnight", () => {
  assert.equal(Model.parseIcsDate("20270914", { VALUE: "DATE" }), new Date(2027, 8, 14).getTime())
})

test("parseIcs reads the fixture feed and drops the cancelled event", () => {
  const events = Model.parseIcs(fixtureIcs)
  assert.equal(events.length, 4)
  assert.equal(events[0].name, "Omarchy Amsterdam Meetup")
  assert.equal(events[0].city, "Amsterdam")
  assert.equal(events[0].url, "https://lu.ma/omarchy-ams-demo")
  assert.equal(events[0].slug, "omarchy-ams-demo")
  assert.ok(events.every(e => e.name !== "Cancelled Workshop"))
})

test("parseIcs finds the event link in the description when URL is absent", () => {
  // Real Luma feeds carry no URL property: the event page link only
  // appears inside DESCRIPTION, often with a ?pk= token (verified against
  // a live feed on 2026-08-25).
  const events = Model.parseIcs(fixtureIcs)
  const lug = events.find(e => e.name === "Linux User Group Borrel")
  assert.equal(lug.url, "https://lu.ma/lug-borrel-demo?pk=g-DemoToken123")
  assert.equal(lug.slug, "lug-borrel-demo")
})

test("parseIcs keeps TENTATIVE events", () => {
  // Live Luma feeds mark every event STATUS:TENTATIVE; only CANCELLED
  // may be dropped.
  const events = Model.parseIcs(fixtureIcs)
  assert.ok(events.some(e => e.name === "Linux User Group Borrel"))
})

test("parseIcs handles a real-style Luma VEVENT", () => {
  const ics = [
    "BEGIN:VCALENDAR",
    "BEGIN:VEVENT",
    "SUMMARY:Omarchy Leiden\\, NL Meetup",
    "DTSTART:20261016T140000Z",
    "DTEND:20261016T170000Z",
    "LOCATION:Leiden\\, Netherlands",
    'ORGANIZER;CN="Matthew Wilson":MAILTO:calendar-invite@lu.ma',
    "DESCRIPTION:Details:\\nhttps://luma.com/fu43mtcv",
    "STATUS:TENTATIVE",
    "END:VEVENT",
    "END:VCALENDAR"
  ].join("\r\n")
  const events = Model.parseIcs(ics)
  assert.equal(events.length, 1)
  assert.equal(events[0].name, "Omarchy Leiden, NL Meetup")
  assert.equal(events[0].startMs, Date.UTC(2026, 9, 16, 14, 0, 0))
  assert.equal(events[0].url, "https://luma.com/fu43mtcv")
  assert.equal(events[0].slug, "fu43mtcv")
  assert.equal(events[0].city, "Leiden")
})

test("unescapeIcsText handles commas, semicolons, newlines, backslashes", () => {
  assert.equal(Model.unescapeIcsText("a\\, b\\; c\\nd\\\\e"), "a, b; c\nd\\e")
})

test("cityFromLocation picks the city segment", () => {
  assert.equal(Model.cityFromLocation("De Hal, Overtoom 3, Amsterdam, Netherlands"), "Amsterdam")
  assert.equal(Model.cityFromLocation("Utrecht"), "Utrecht")
  assert.equal(Model.cityFromLocation("Venue, 1012 AB Amsterdam, Netherlands"), "Amsterdam")
  assert.equal(Model.cityFromLocation(""), "")
})

test("cityFromLocation drops a venue-less event's URL location", () => {
  assert.equal(Model.cityFromLocation("https://luma.com/event/evt-YDyCEwwpiM"), "")
  assert.equal(Model.cityFromLocation("  https://lu.ma/abc123"), "")
})

test("eventSlug normalizes lu.ma and luma.com to one key", () => {
  assert.equal(Model.eventSlug("https://lu.ma/abc123"), "abc123")
  assert.equal(Model.eventSlug("https://luma.com/abc123?utm=x"), "abc123")
  assert.equal(Model.eventSlug("https://www.luma.com/ABC123"), "abc123")
  assert.equal(Model.eventSlug("https://example.com/abc"), "")
})

// The meta tag shape is copied from a live luma.com event page (2026-08-25):
// attribute order varies, og:image:width/height must not match, and the
// embedded JSON carries the raw cover as "cover_url".
const eventPageHtml = '<html><head>' +
  '<meta property="og:image:width" content="800"/>' +
  '<meta property="og:image:height" content="420"/>' +
  '<meta name="image" property="og:image" content="https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=1,width=800,height=420/event-social/oh/social.png" data-next-head=""/>' +
  '</head><body>{"cover_url":"https://images.lumacdn.com/uploads/79/cover.png"}</body></html>'

test("coverUrlFromHtml prefers the embedded cover_url as a CDN thumb", () => {
  assert.equal(
    Model.coverUrlFromHtml(eventPageHtml),
    "https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=2,quality=75,width=80,height=80/uploads/79/cover.png")
})

test("coverUrlFromHtml falls back to og:image and decodes entities", () => {
  const withoutJson = eventPageHtml.replace(/\{"cover_url".*\}/, "")
  assert.equal(
    Model.coverUrlFromHtml(withoutJson),
    "https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=2,quality=75,width=80,height=80/event-social/oh/social.png")
  const entities = '<meta property="og:image" content="https://example.com/a.png?x=1&amp;y=2"/>'
  assert.equal(Model.coverUrlFromHtml(entities), "https://example.com/a.png?x=1&y=2")
})

test("coverUrlFromHtml handles escaped JSON slashes and missing covers", () => {
  assert.equal(
    Model.coverUrlFromHtml('{"cover_url":"https:\\/\\/images.lumacdn.com\\/uploads\\/x.png"}'),
    "https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=2,quality=75,width=80,height=80/uploads/x.png")
  assert.equal(Model.coverUrlFromHtml("<html><body>nothing here</body></html>"), "")
  assert.equal(Model.coverUrlFromHtml(""), "")
})

test("coverThumbUrl only rewrites lumacdn URLs, never twice", () => {
  const thumb = Model.coverThumbUrl("https://images.lumacdn.com/uploads/79/cover.png")
  assert.equal(thumb, "https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=2,quality=75,width=80,height=80/uploads/79/cover.png")
  assert.equal(Model.coverThumbUrl(thumb), thumb)
  assert.equal(Model.coverThumbUrl("file:///tmp/luma-demo/cover-x.png"), "file:///tmp/luma-demo/cover-x.png")
  assert.equal(Model.coverThumbUrl(""), "")
})

test("futureEvents filters, sorts, and caps", () => {
  const now = Date.UTC(2027, 8, 1)
  const events = Model.parseIcs(fixtureIcs)
  const future = Model.futureEvents(events, now, 2)
  assert.equal(future.length, 2)
  assert.ok(future[0].startMs <= future[1].startMs)
})

test("futureEvents drops past events", () => {
  const afterAll = Date.UTC(2028, 0, 1)
  assert.equal(Model.futureEvents(Model.parseIcs(fixtureIcs), afterAll, 10).length, 0)
})

test("daysUntil counts calendar days", () => {
  const now = new Date(2027, 8, 1, 22, 0).getTime()
  const tomorrowMorning = new Date(2027, 8, 2, 8, 0).getTime()
  assert.equal(Model.daysUntil(tomorrowMorning, now), 1)
  assert.equal(Model.daysUntil(now, now), 0)
})

test("barLabel shows days until the event, or the time when it is today", () => {
  const now = new Date(2027, 8, 1, 9, 0).getTime()
  const in12Days = { startMs: new Date(2027, 8, 13, 19, 0).getTime() }
  assert.equal(Model.barLabel(in12Days, now), "12d")

  const today = { startMs: new Date(2027, 8, 1, 18, 0).getTime() }
  assert.equal(Model.barLabel(today, now), "18:00")

  assert.equal(Model.barLabel(null, now), "")
})

test("dateLabel says Today and Tomorrow", () => {
  const now = new Date(2027, 8, 1, 9, 0).getTime()
  assert.equal(Model.dateLabel(new Date(2027, 8, 1, 18, 0).getTime(), now), "Today")
  assert.equal(Model.dateLabel(new Date(2027, 8, 2, 8, 0).getTime(), now), "Tomorrow")
})

test("clampRefreshInterval enforces the 300s minimum", () => {
  assert.equal(Model.clampRefreshInterval(60), 300)
  assert.equal(Model.clampRefreshInterval(1800), 1800)
  assert.equal(Model.clampRefreshInterval("nonsense"), 1800)
})

test("clampMaxEvents guards the row cap", () => {
  assert.equal(Model.clampMaxEvents(10), 10)
  assert.equal(Model.clampMaxEvents(0), 10)
  assert.equal(Model.clampMaxEvents(999), 50)
})

test("lastPollLabel describes freshness", () => {
  const now = Date.UTC(2027, 8, 1, 12, 0)
  assert.equal(Model.lastPollLabel(0, now), "")
  assert.equal(Model.lastPollLabel(now - 30000, now), "updated just now")
  assert.equal(Model.lastPollLabel(now - 300000, now), "updated 5m ago")
  assert.equal(Model.lastPollLabel(now - 7200000, now), "updated 2h ago")
})
