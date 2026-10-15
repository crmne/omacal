// Place suggestions for the event form's "Where?" field, as HEY offers them
// while you type: Google Places when a Google Maps API key is set, else
// OpenStreetMap through Komoot's public Photon server, which needs none.
//
// This file builds the requests and reads the answers; PlaceSearch.qml
// sends them. Qt-free and self-contained, so it runs under plain node.
//
// Places near this machine's time zone come first, as HEY's come near you:
// the zone's city is in the system's zone1970.tab, and its coordinates are
// sent as a preference, never a limit ("lisbon" still finds Lisbon).
//
// A suggestion is { title, detail, value }: the place's name, the rest of
// its address, and the text the field takes when it is picked.

var minimumQuery = 3
var maximumQuery = 200
var maximumResults = 5
// Answers past this are cut off, not parsed.
var maximumResponse = 262144

var googleUrl = "https://places.googleapis.com/v1/places:autocomplete"
var photonUrl = "https://photon.komoot.io/api/"
// Photon names places in these languages; any other gets the local name.
var photonLanguages = ["en", "de", "fr"]

// Where the Google key is kept: a file of its own, mode 600, outside
// shell.json, which people share and commit.
function keyPath(configHome, home) {
  var base = trim(configHome) !== "" ? trim(configHome) : trim(home) + "/.config"
  return base + "/omacal/google-places-key"
}

function trim(value) {
  return String(value === undefined || value === null ? "" : value).replace(/\s+/g, " ").replace(/^ | $/g, "")
}

// What is worth asking about: "" while it is too short to mean anything.
function searchText(text) {
  var query = trim(text)
  if (query.length < minimumQuery) return ""
  return query.substr(0, maximumQuery)
}

// A Google Maps API key is letters, digits, _ and -; anything else was not
// pasted from the console and is refused rather than sent.
function isGoogleKey(key) {
  return /^[A-Za-z0-9_-]{20,100}$/.test(trim(key))
}

// The coordinates zone1970.tab gives a zone, as { latitude, longitude },
// or null. They are ISO 6709: +5230+01322 is 52°30'N 13°22'E.
function zoneCoordinates(table, zone) {
  var name = trim(zone)
  if (name === "") return null
  var lines = String(table || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var columns = lines[i].split("\t")
    if (columns[2] !== name) continue
    var match = /^([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?$/.exec(columns[1] || "")
    if (!match) return null
    function degrees(sign, d, m, sec) {
      var value = parseInt(d, 10) + parseInt(m, 10) / 60 + (sec ? parseInt(sec, 10) / 3600 : 0)
      return Math.round((sign === "-" ? -value : value) * 10000) / 10000
    }
    return { latitude: degrees(match[1], match[2], match[3], match[4]),
      longitude: degrees(match[5], match[6], match[7], match[8]) }
  }
  return null
}

// The request for a query, or null when there is nothing to ask:
// { provider, method, url, headers, body }. The key goes in a header, never
// the URL. `language` is a locale name like "en_GB"; `near`, when given,
// is zoneCoordinates'.
function request(text, googleKey, sessionToken, language, near) {
  var query = searchText(text)
  if (query === "") return null
  var lang = String(language || "").split(/[_-]/)[0].toLowerCase()
  var key = trim(googleKey)
  if (isGoogleKey(key)) {
    var body = { input: query }
    if (sessionToken) body.sessionToken = String(sessionToken)
    if (/^[a-z]{2,3}$/.test(lang)) body.languageCode = lang
    if (near) body.locationBias = { circle: { center: near, radius: 50000 } }
    return {
      provider: "google", method: "POST", url: googleUrl,
      headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key },
      body: JSON.stringify(body)
    }
  }
  var url = photonUrl + "?q=" + encodeURIComponent(query) + "&limit=" + maximumResults
  if (photonLanguages.indexOf(lang) !== -1) url += "&lang=" + lang
  if (near) url += "&lat=" + near.latitude + "&lon=" + near.longitude
  return { provider: "photon", method: "GET", url: url, headers: {}, body: "" }
}

function joined(parts) {
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var part = trim(parts[i])
    if (part !== "" && out.indexOf(part) === -1) out.push(part)
  }
  return out.join(", ")
}

// The detail never repeats the title: Lisbon is in Lisbon district.
function suggestion(title, detail) {
  title = trim(title).substr(0, 200)
  if (title === "") return null
  var parts = trim(detail).split(", ")
  var rest = []
  for (var i = 0; i < parts.length; i++) if (parts[i] !== title) rest.push(parts[i])
  detail = joined(rest).substr(0, 200)
  return { title: title, detail: detail, value: joined([title, detail]).substr(0, 256) }
}

function pushUnique(list, item) {
  if (!item || list.length >= maximumResults) return
  for (var i = 0; i < list.length; i++) if (list[i].value === item.value) return
  list.push(item)
}

function parseJson(text) {
  var body = String(text || "")
  if (body.length > maximumResponse) return null
  try {
    return JSON.parse(body)
  } catch (e) {
    return null
  }
}

// Google's answer: places only, not the query predictions it mixes in.
function parseGoogle(text) {
  var data = parseJson(text)
  var out = []
  var list = data && Array.isArray(data.suggestions) ? data.suggestions : []
  for (var i = 0; i < list.length; i++) {
    var place = list[i] && list[i].placePrediction
    if (!place) continue
    var format = place.structuredFormat || {}
    var main = format.mainText && format.mainText.text
    var rest = format.secondaryText && format.secondaryText.text
    if (main) pushUnique(out, suggestion(main, rest))
    else if (place.text && place.text.text) pushUnique(out, suggestion(place.text.text, ""))
  }
  return out
}

// Photon's answer, GeoJSON: a café is its name over its street and town; a
// street or a town is its own name over what contains it.
function parsePhoton(text) {
  var data = parseJson(text)
  var out = []
  var list = data && Array.isArray(data.features) ? data.features : []
  for (var i = 0; i < list.length; i++) {
    var p = list[i] && list[i].properties
    if (!p) continue
    var street = joined([p.street, p.housenumber]).replace(", ", " ")
    var town = joined([p.postcode, p.city || p.town || p.village]).replace(", ", " ")
    if (p.name) pushUnique(out, suggestion(p.name, joined([street, town, p.country])))
    else if (street) pushUnique(out, suggestion(street, joined([town, p.country])))
    else pushUnique(out, suggestion(p.city || p.state, joined([p.state, p.country])))
  }
  return out
}

function parse(provider, text) {
  return provider === "google" ? parseGoogle(text) : parsePhoton(text)
}

// Why a lookup failed, said for the form. Google explains itself; its own
// words are kept short.
function failure(provider, status, text) {
  if (provider !== "google") return status === 429 ? "OpenStreetMap is busy. Try again in a moment." : ""
  var data = parseJson(text)
  var message = data && data.error && data.error.message ? trim(data.error.message).substr(0, 140) : ""
  if (status === 400 || status === 403) return "Google refused the Places key" + (message ? ": " + message : ".")
  if (status === 429) return "Google Places is over its quota."
  return status ? "Google Places did not answer (" + status + ")." : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    minimumQuery: minimumQuery,
    keyPath: keyPath,
    zoneCoordinates: zoneCoordinates,
    searchText: searchText,
    isGoogleKey: isGoogleKey,
    request: request,
    parse: parse,
    parseGoogle: parseGoogle,
    parsePhoton: parsePhoton,
    failure: failure
  }
}
