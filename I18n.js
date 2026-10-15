.pragma library
.import "lang/en.js" as Lang_en
.import "lang/de.js" as Lang_de
.import "lang/fr.js" as Lang_fr
.import "lang/es.js" as Lang_es
.import "lang/it.js" as Lang_it
.import "lang/pt.js" as Lang_pt
.import "lang/nl.js" as Lang_nl
.import "lang/pl.js" as Lang_pl

// Interface translations. All built in: nothing is
// downloaded or generated. The language follows the Hyprland keyboard layout,
// then the system locale (LC_ALL, LC_MESSAGES, LANG), unless one is picked in
// the settings; anything without a translation falls back to English.

var LANGUAGES = [
  { code: "en", name: "English" },
  { code: "de", name: "Deutsch" },
  { code: "fr", name: "Français" },
  { code: "es", name: "Español" },
  { code: "it", name: "Italiano" },
  { code: "pt", name: "Português" },
  { code: "nl", name: "Nederlands" },
  { code: "pl", name: "Polski" }
]

// "xx_YY.UTF-8" / "xx-YY" / "xx" -> "xx" when we have it, else "en".
function systemLanguage(lcAll, lcMessages, lang) {
  var values = [lcAll, lcMessages, lang]
  for (var i = 0; i < values.length; i++) {
    var code = String(values[i] || "").toLowerCase().split(/[_.@-]/)[0]
    if (code === "c" || code === "posix" || code === "") continue
    return supported(code) ? code : "en"
  }
  return "en"
}

// Omarchy has no interface-language setting of its own; the keyboard layout
// picked for Hyprland is its strongest hint. xkb layout -> language code.
var KEYBOARD_LANGUAGES = {
  us: "en", gb: "en", uk: "en", ie: "en", au: "en", ca: "en",
  es: "es", latam: "es",
  de: "de", at: "de",
  fr: "fr", be: "fr",
  it: "it",
  pt: "pt", br: "pt",
  nl: "nl",
  pl: "pl"
}

// The language of a Hyprland keyboard layout ("es", "latam", ...), or "" when
// it has no translation here.
function keyboardLanguage(layout) {
  var code = KEYBOARD_LANGUAGES[String(layout || "").toLowerCase().trim()]
  return code && supported(code) ? code : ""
}

// Automatic language: the keyboard layout when it names a translated language
// other than English, else the system locale (which falls back to English).
function autoLanguage(keyboardCode, localeCode) {
  return keyboardCode && keyboardCode !== "en" ? keyboardCode : localeCode
}

function supported(code) {
  for (var i = 0; i < LANGUAGES.length; i++) if (LANGUAGES[i].code === code) return true
  return false
}

function languageName(code) {
  for (var i = 0; i < LANGUAGES.length; i++) if (LANGUAGES[i].code === code) return LANGUAGES[i].name
  return code
}

// The setting is "auto" (system) or a language code.
function resolve(setting, systemCode) {
  return setting && setting !== "auto" && supported(setting) ? setting : systemCode
}

function format(text, args) {
  return String(text).replace(/\{(\d+)\}/g, function(match, index) {
    var value = args && args[Number(index)]
    return value === undefined || value === null ? match : String(value)
  })
}

function tr(lang, key, args) {
  var table = STRINGS[lang] || STRINGS.en
  var text = table[key]
  if (text === undefined) text = STRINGS.en[key]
  if (text === undefined) return key
  if (Array.isArray(text)) text = text[text.length - 1]
  return format(text, args)
}

// Plural: entries are [one, other], or [one, few, many] for Polish.
function trn(lang, key, n, args) {
  var table = STRINGS[lang] || STRINGS.en
  var forms = table[key] !== undefined ? table[key] : STRINGS.en[key]
  if (forms === undefined) return key
  if (!Array.isArray(forms)) return format(forms, [n].concat(args || []))
  var index
  if (lang === "pl" && forms.length === 3) {
    var mod10 = n % 10, mod100 = n % 100
    index = n === 1 ? 0 : (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) ? 1 : 2
  } else if (lang === "fr" || lang === "pt") {
    index = n <= 1 ? 0 : forms.length - 1
  } else {
    index = n === 1 ? 0 : forms.length - 1
  }
  return format(forms[index], [n].concat(args || []))
}

var STRINGS = {
  en: Lang_en.STRINGS,
  de: Lang_de.STRINGS,
  fr: Lang_fr.STRINGS,
  es: Lang_es.STRINGS,
  it: Lang_it.STRINGS,
  pt: Lang_pt.STRINGS,
  nl: Lang_nl.STRINGS,
  pl: Lang_pl.STRINGS
}
