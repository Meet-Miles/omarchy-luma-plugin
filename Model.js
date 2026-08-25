// Data layer for the Luma widget: iCal feed parsing, cover-art extraction,
// and every label the bar and panel print.
//
// Pure functions over plain data, shared by Panel.qml and the node test
// suite (see the module.exports block at the bottom, same pattern as the
// built-in weather plugin).

// ---- Fetch-script status protocol. The lib/ scripts read the secrets file
//      themselves so no URL or key ever crosses into the QML process; the
//      first stdout line carries the outcome, the rest is payload.
var STATUS_PREFIX = "##luma-status:"

function splitScriptOutput(raw) {
  var text = String(raw == null ? "" : raw)
  var newline = text.indexOf("\n")
  var first = newline === -1 ? text : text.slice(0, newline)
  if (first.indexOf(STATUS_PREFIX) !== 0)
    return { status: "error", payload: "" }
  return {
    status: first.slice(STATUS_PREFIX.length).replace(/\s+$/, ""),
    payload: newline === -1 ? "" : text.slice(newline + 1)
  }
}

// ---- iCal parsing.

// Folded lines continue with a space or tab (RFC 5545 3.1); CRLF and bare
// LF both appear in the wild.
function unfoldIcs(text) {
  var lines = String(text || "").split(/\r\n|\n|\r/)
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if ((line.charAt(0) === " " || line.charAt(0) === "\t") && out.length > 0)
      out[out.length - 1] += line.slice(1)
    else
      out.push(line)
  }
  return out
}

function unescapeIcsText(value) {
  return String(value || "")
    .replace(/\\n/gi, "\n")
    .replace(/\\,/g, ",")
    .replace(/\\;/g, ";")
    .replace(/\\\\/g, "\\")
}

// "DTSTART;TZID=Europe/Amsterdam:20260901T180000" → name, params, value.
function parseIcsLine(line) {
  var colon = String(line).indexOf(":")
  if (colon === -1) return null
  var head = line.slice(0, colon).split(";")
  var params = {}
  for (var i = 1; i < head.length; i++) {
    var eq = head[i].indexOf("=")
    if (eq !== -1) params[head[i].slice(0, eq).toUpperCase()] = head[i].slice(eq + 1)
  }
  return { name: head[0].toUpperCase(), params: params, value: line.slice(colon + 1) }
}

// Epoch ms for a DTSTART/DTEND value. A trailing Z is UTC; a bare date is
// local midnight; a naive datetime (with or without TZID) is read as local
// time — Luma feeds emit UTC, so the naive case is a fallback, not the norm.
function parseIcsDate(value, params) {
  var v = String(value || "").trim()
  var isDate = (params && params.VALUE === "DATE") || /^\d{8}$/.test(v)
  if (isDate) {
    var dm = /^(\d{4})(\d{2})(\d{2})$/.exec(v)
    if (!dm) return NaN
    return new Date(Number(dm[1]), Number(dm[2]) - 1, Number(dm[3])).getTime()
  }
  var m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/.exec(v)
  if (!m) return NaN
  if (m[7] === "Z")
    return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]))
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])).getTime()
}

// First https link in a text blob — the fallback when a VEVENT carries no
// URL property, since Luma descriptions lead with the event page link.
function firstLink(text) {
  var m = /https:\/\/[^\s"<>\\]+/.exec(String(text || ""))
  return m ? m[0].replace(/[.,;)\]]+$/, "") : ""
}

function parseIcs(text) {
  var lines = unfoldIcs(text)
  var events = []
  var current = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "BEGIN:VEVENT") { current = {}; continue }
    if (line === "END:VEVENT") {
      if (current) {
        var event = finishIcsEvent(current)
        if (event) events.push(event)
      }
      current = null
      continue
    }
    if (!current) continue
    var parsed = parseIcsLine(line)
    if (!parsed) continue
    if (parsed.name === "SUMMARY") current.summary = unescapeIcsText(parsed.value)
    else if (parsed.name === "LOCATION") current.location = unescapeIcsText(parsed.value)
    else if (parsed.name === "URL") current.url = parsed.value.replace(/\s+$/, "")
    else if (parsed.name === "DESCRIPTION") current.description = unescapeIcsText(parsed.value)
    else if (parsed.name === "STATUS") current.status = parsed.value.toUpperCase()
    else if (parsed.name === "DTSTART") current.startMs = parseIcsDate(parsed.value, parsed.params)
    else if (parsed.name === "DTEND") current.endMs = parseIcsDate(parsed.value, parsed.params)
    else if (parsed.name === "UID") current.uid = parsed.value
  }
  return events
}

function finishIcsEvent(raw) {
  if (raw.status === "CANCELLED") return null
  if (raw.startMs === undefined || isNaN(raw.startMs)) return null
  var url = raw.url || firstLink(raw.description)
  return {
    name: raw.summary || "(untitled)",
    location: raw.location || "",
    city: cityFromLocation(raw.location),
    url: url,
    slug: eventSlug(url),
    startMs: raw.startMs,
    endMs: (raw.endMs !== undefined && !isNaN(raw.endMs)) ? raw.endMs : raw.startMs
  }
}

// Luma locations read "Venue, Street 1, City, Country" or just "City".
// The city is the second segment from the end once a country is present;
// with one or two segments the first is the best guess. Leading postal
// codes ("1012 AB Amsterdam") are stripped. An event without a venue
// carries its own page URL as the location — no city to show there.
function cityFromLocation(location) {
  if (/^https?:\/\//i.test(String(location || "").trim())) return ""
  var parts = String(location || "").split(",")
    .map(function(part) { return part.replace(/^\s+|\s+$/g, "") })
    .filter(function(part) { return part !== "" })
  if (parts.length === 0) return ""
  var candidate = parts.length >= 3 ? parts[parts.length - 2] : parts[0]
  return candidate.replace(/^[0-9][0-9A-Z ]*\s+(?=[A-Za-z])/, "")
}

// ---- Event identity. Luma serves the same event as lu.ma/<slug> and
//      luma.com/<slug>; the slug keys the cover cache.
function eventSlug(url) {
  var m = /^https:\/\/(?:www\.)?(?:lu\.ma|luma\.com)\/([^\s/?#]+)/i.exec(String(url || ""))
  return m ? m[1].toLowerCase() : ""
}

// ---- Cover art. The event page embeds the raw square cover as
//      "cover_url" in its JSON payload; the og:image social card (800×420,
//      with text baked in) is the fallback. lib/luma-cover only moves the
//      HTML; the extraction lives here so the tests cover it.

function coverUrlFromHtml(html) {
  var text = String(html || "")
  var m = /"cover_url":"(https:[^"]+)"/.exec(text)
  var url = m ? m[1].replace(/\\\//g, "/") : ""
  if (!url) {
    var tag = /<meta[^>]*property="og:image"[^>]*>/.exec(text)
    var content = tag ? /content="([^"]+)"/.exec(tag[0]) : null
    if (content) url = content[1].replace(/&amp;/g, "&")
  }
  return coverThumbUrl(url)
}

// Luma serves covers from images.lumacdn.com, whose cdn-cgi prefix resizes
// on the fly. The panel thumb is ~40px, so ask the CDN for an 80px square
// (2× for hidpi) instead of pulling the full upload. Other hosts (and the
// demo's file:// covers) pass through unchanged.
function coverThumbUrl(url) {
  var m = /^https:\/\/images\.lumacdn\.com\/(?:cdn-cgi\/image\/[^/]+\/)?(.+)$/.exec(String(url || ""))
  if (!m) return String(url || "")
  return "https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=2,quality=75,width=80,height=80/" + m[1]
}

// ---- The event list.

function futureEvents(events, nowMs, maxEvents) {
  var cap = clampMaxEvents(maxEvents)
  return (events || [])
    .filter(function(e) { return e.endMs >= nowMs || e.startMs >= nowMs })
    .sort(function(a, b) { return a.startMs - b.startMs })
    .slice(0, cap)
}

// ---- Labels.

function startOfDay(ms) {
  var d = new Date(ms)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

// Calendar days, not 24-hour buckets: an event tomorrow morning is "1d"
// even when it is fewer than 24 hours away.
function daysUntil(startMs, nowMs) {
  return Math.round((startOfDay(startMs) - startOfDay(nowMs)) / 86400000)
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

function timeLabel(ms) {
  var d = new Date(ms)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

function dateLabel(ms, nowMs) {
  var days = daysUntil(ms, nowMs)
  if (days === 0) return "Today"
  if (days === 1) return "Tomorrow"
  var d = new Date(ms)
  return WEEKDAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]
}

// The next-event summary: days until it ("12d"), or its start time when it
// is today ("18:00"). The bar itself shows only the glyph; this feeds the
// tooltip and the demo preview.
function barLabel(nextEvent, nowMs) {
  if (!nextEvent) return ""
  var days = daysUntil(nextEvent.startMs, nowMs)
  return days <= 0 ? timeLabel(nextEvent.startMs) : days + "d"
}

function lastPollLabel(lastGoodMs, nowMs) {
  if (!lastGoodMs) return ""
  var minutes = Math.max(0, Math.floor((nowMs - lastGoodMs) / 60000))
  if (minutes < 1) return "updated just now"
  if (minutes < 60) return "updated " + minutes + "m ago"
  return "updated " + Math.round(minutes / 60) + "h ago"
}

// ---- Settings guards (manifest defaults, spec section 9).

function clampRefreshInterval(value) {
  var n = parseInt(String(value), 10)
  if (isNaN(n)) n = 1800
  return Math.max(300, n)
}

function clampMaxEvents(value) {
  var n = parseInt(String(value), 10)
  if (isNaN(n) || n < 1) n = 10
  return Math.min(50, n)
}

if (typeof module !== "undefined") {
  module.exports = {
    splitScriptOutput: splitScriptOutput,
    unfoldIcs: unfoldIcs,
    unescapeIcsText: unescapeIcsText,
    parseIcsLine: parseIcsLine,
    parseIcsDate: parseIcsDate,
    firstLink: firstLink,
    parseIcs: parseIcs,
    cityFromLocation: cityFromLocation,
    eventSlug: eventSlug,
    coverUrlFromHtml: coverUrlFromHtml,
    coverThumbUrl: coverThumbUrl,
    futureEvents: futureEvents,
    daysUntil: daysUntil,
    timeLabel: timeLabel,
    dateLabel: dateLabel,
    barLabel: barLabel,
    lastPollLabel: lastPollLabel,
    clampRefreshInterval: clampRefreshInterval,
    clampMaxEvents: clampMaxEvents
  }
}
