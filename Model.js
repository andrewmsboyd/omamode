// Pure helpers for the light/dark plugin: gsettings text parsing and
// schedule math. Kept dependency-free so they're easy to reason about
// (and hand-test) apart from the QML/process plumbing in Service.qml.

function modeFromColorSchemeValue(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  return text.indexOf("dark") !== -1 ? "dark" : "light"
}

// `gsettings monitor` prints one line per change, e.g.
//   org.gnome.desktop.interface color-scheme: 'prefer-dark'
// Returns the raw scheme token ("prefer-dark" / "prefer-light" / "default"),
// or null if the line doesn't look like a color-scheme change.
function parseMonitorLine(line) {
  var text = String(line === undefined || line === null ? "" : line)
  var match = text.match(/color-scheme:\s*'?([\w-]+)'?\s*$/)
  return match ? match[1] : null
}

function parseThemeList(output) {
  var text = String(output === undefined || output === null ? "" : output)
  return text.split("\n")
    .map(function(line) { return line.trim() })
    .filter(function(line) { return line.length > 0 })
}

// "H:MM" / "HH:MM" -> minutes since midnight, or null if unparseable.
function parseTimeToMinutes(hhmm) {
  var text = String(hhmm === undefined || hhmm === null ? "" : hhmm).trim()
  var match = text.match(/^(\d{1,2}):(\d{2})$/)
  if (!match) return null
  var hours = Number(match[1])
  var minutes = Number(match[2])
  if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return null
  return hours * 60 + minutes
}

function formatMinutes(totalMinutes) {
  var wrapped = ((Math.round(totalMinutes) % 1440) + 1440) % 1440
  var hours = Math.floor(wrapped / 60)
  var minutes = wrapped % 60
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return pad(hours) + ":" + pad(minutes)
}

function mod(value, modulus) {
  return ((value % modulus) + modulus) % modulus
}

// Relative-luminance based icon selection, matching the convention used by
// the built-in agents plugin (see assets/<id>-light.svg there): the base
// asset is drawn light-on-transparent for a dark surface; the "-light" twin
// is drawn dark-on-transparent for a light surface. `iconCandidates` returns
// URLs in preference order so the caller can fall back if a twin is missing.
function colorChannelLuminance(value) {
  var channel = Number(value)
  if (!isFinite(channel)) return 0
  return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
}

function colorLuminance(color) {
  if (!color) return 0
  return 0.2126 * colorChannelLuminance(color.r)
    + 0.7152 * colorChannelLuminance(color.g)
    + 0.0722 * colorChannelLuminance(color.b)
}

function iconCandidates(baseUrl, surfaceColor) {
  // Qt.resolvedUrl() returns a QUrl-backed value, not a plain JS string, so
  // it has no .replace() of its own — stringify before touching it as text.
  var base = String(baseUrl)
  var candidates = []
  if (colorLuminance(surfaceColor) >= 0.5) candidates.push(base.replace(/\.svg$/, "-light.svg"))
  candidates.push(base)
  return candidates
}

// Which mode should be active right now, given the two daily boundaries.
// Picks whichever boundary happened most recently (walking backward from
// `nowMinutes`), which correctly handles boundaries that wrap past midnight.
function expectedModeForMinutes(nowMinutes, lightMinutes, darkMinutes) {
  if (lightMinutes === darkMinutes) return "light"
  var sinceLight = mod(nowMinutes - lightMinutes, 1440)
  var sinceDark = mod(nowMinutes - darkMinutes, 1440)
  return sinceLight < sinceDark ? "light" : "dark"
}

// Minutes from `nowMinutes` until the soonest of the two boundaries.
function minutesUntilNextBoundary(nowMinutes, lightMinutes, darkMinutes) {
  var untilLight = mod(lightMinutes - nowMinutes, 1440)
  var untilDark = mod(darkMinutes - nowMinutes, 1440)
  return Math.min(untilLight, untilDark)
}

// Epoch-ms timestamp of the next schedule boundary strictly after `sinceMs`.
function nextBoundaryTimestampAfter(sinceMs, lightMinutes, darkMinutes) {
  var since = new Date(sinceMs)
  var sinceMinutes = since.getHours() * 60 + since.getMinutes()
  var untilNext = minutesUntilNextBoundary(sinceMinutes, lightMinutes, darkMinutes)
  if (untilNext === 0) untilNext = 1440
  return sinceMs + untilNext * 60000
}

function formatTimestampHHMM(ms) {
  var d = new Date(ms)
  var pad = function(n) { return n < 10 ? "0" + n : String(n) }
  return pad(d.getHours()) + ":" + pad(d.getMinutes())
}

if (typeof module !== "undefined") {
  module.exports = {
    modeFromColorSchemeValue: modeFromColorSchemeValue,
    parseMonitorLine: parseMonitorLine,
    parseThemeList: parseThemeList,
    parseTimeToMinutes: parseTimeToMinutes,
    formatMinutes: formatMinutes,
    colorLuminance: colorLuminance,
    iconCandidates: iconCandidates,
    expectedModeForMinutes: expectedModeForMinutes,
    minutesUntilNextBoundary: minutesUntilNextBoundary,
    nextBoundaryTimestampAfter: nextBoundaryTimestampAfter,
    formatTimestampHHMM: formatTimestampHHMM
  }
}
