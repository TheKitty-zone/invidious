# "bn_BD"   => load_locale("bn_BD"),   # Bengali (Bangladesh)  [Incomplete]
# "eu"      => load_locale("eu"),      # Basque  [Incomplete]
# "sk"      => load_locale("sk"),      # Slovak  [Incomplete]
LOCALES_LIST = {
  "ar"      => "العربية",               # Arabic
  "cs"      => "Čeština",               # Czech
  "da"      => "Dansk",                 # Danish
  "de"      => "Deutsch",               # German
  "el"      => "Ελληνικά",              # Greek
  "en-US"   => "English",               # English
  "eo"      => "Esperanto",             # Esperanto
  "es"      => "Español",               # Spanish
  "fa"      => "فارسی",                 # Persian
  "fi"      => "Suomi",                 # Finnish
  "fr"      => "Français",              # French
  "he"      => "עברית",                 # Hebrew
  "hr"      => "Hrvatski",              # Croatian
  "hu-HU"   => "Magyar Nyelv",          # Hungarian
  "id"      => "Bahasa Indonesia",      # Indonesian
  "is"      => "Íslenska",              # Icelandic
  "it"      => "Italiano",              # Italian
  "ja"      => "日本語",                   # Japanese
  "ko"      => "한국어",                   # Korean
  "lt"      => "Lietuvių",              # Lithuanian
  "nb-NO"   => "Norsk bokmål",          # Norwegian Bokmål
  "nl"      => "Nederlands",            # Dutch
  "pl"      => "Polski",                # Polish
  "pt"      => "Português",             # Portuguese
  "pt-BR"   => "Português Brasileiro",  # Portuguese (Brazil)
  "pt-PT"   => "Português de Portugal", # Portuguese (Portugal)
  "ro"      => "Română",                # Romanian
  "ru"      => "русский",               # Russian
  "sq"      => "Shqip",                 # Albanian
  "sr"      => "srpski (latinica)",     # Serbian (Latin)
  "sr_Cyrl" => "српски (ћирилица)",     # Serbian (Cyrillic)
  "sv-SE"   => "Svenska",               # Swedish
  "tr"      => "Türkçe",                # Turkish
  "uk"      => "Українська",            # Ukrainian
  "vi"      => "Tiếng Việt",            # Vietnamese
  "zh-CN"   => "汉语",                    # Chinese (Simplified)
  "zh-TW"   => "漢語",                    # Chinese (Traditional)
}

LOCALES = load_all_locales()

CONTENT_REGIONS = {
  "AE", "AR", "AT", "AU", "AZ", "BA", "BD", "BE", "BG", "BH", "BO", "BR", "BY",
  "CA", "CH", "CL", "CO", "CR", "CY", "CZ", "DE", "DK", "DO", "DZ", "EC", "EE",
  "EG", "ES", "FI", "FR", "GB", "GE", "GH", "GR", "GT", "HK", "HN", "HR", "HU",
  "ID", "IE", "IL", "IN", "IQ", "IS", "IT", "JM", "JO", "JP", "KE", "KR", "KW",
  "KZ", "LB", "LI", "LK", "LT", "LU", "LV", "LY", "MA", "ME", "MK", "MT", "MX",
  "MY", "NG", "NI", "NL", "NO", "NP", "NZ", "OM", "PA", "PE", "PG", "PH", "PK",
  "PL", "PR", "PT", "PY", "QA", "RO", "RS", "RU", "SA", "SE", "SG", "SI", "SK",
  "SN", "SV", "TH", "TN", "TR", "TW", "TZ", "UA", "UG", "US", "UY", "VE", "VN",
  "YE", "ZA", "ZW",
}

# Enum for the different types of number formats
enum NumberFormatting
  None      # Print the number as-is
  Separator # Use a separator for thousands
  Short     # Use short notation (k/M/B)
  HtmlSpan  # Surround with <span id="count"></span>
end

def load_all_locales
  locales = {} of String => Hash(String, JSON::Any)

  LOCALES_LIST.each_key do |name|
    locales[name] = JSON.parse(File.read("locales/#{name}.json")).as_h
  end

  return locales
end

def translate(locale : String?, key : String, text : String | Nil = nil) : String
  # Log a warning if "key" doesn't exist in en-US locale and return
  # that key as the text, so this is more or less transparent to the user.
  if !LOCALES["en-US"].has_key?(key)
    LOGGER.warn("i18n: Missing translation key \"#{key}\"")
    return key
  end

  # Default to english, whenever the locale doesn't exist,
  # or the key requested has not been translated
  if locale && LOCALES.has_key?(locale) && LOCALES[locale].has_key?(key)
    raw_data = LOCALES[locale][key]
  else
    raw_data = LOCALES["en-US"][key]
  end

  case raw_data
  when .as_h?
    # Init
    translation = ""
    match_length = 0

    raw_data.as_h.each do |hash_key, value|
      if md = text.try &.match(/#{hash_key}/)
        if md[0].size >= match_length
          translation = value.as_s
          match_length = md[0].size
        end
      end
    end
  when .as_s?
    translation = raw_data.as_s
  else
    raise "Invalid translation \"#{raw_data}\""
  end

  if text
    translation = translation.gsub("`x`", text)
  end

  return translation
end

def translate_count(locale : String, key : String, count : Int, format = NumberFormatting::None) : String
  # Fallback on english if locale doesn't exist
  locale = "en-US" if !LOCALES.has_key?(locale)

  # Retrieve suffix
  suffix = I18next::Plurals::RESOLVER.get_suffix(locale, count)
  plural_key = key + suffix

  if LOCALES[locale].has_key?(plural_key)
    translation = LOCALES[locale][plural_key].as_s
  else
    # Try #1: Fallback to singular in the same locale
    singular_suffix = I18next::Plurals::RESOLVER.get_suffix(locale, 1)

    if LOCALES[locale].has_key?(key + singular_suffix)
      translation = LOCALES[locale][key + singular_suffix].as_s
    elsif locale != "en-US"
      # Try #2: Fallback to english
      translation = translate_count("en-US", key, count)
    else
      # Return key if we're already in english, as the translation is missing
      LOGGER.warn("i18n: Missing translation key \"#{key}\"")
      return key
    end
  end

  case format
  when .separator? then count_txt = number_with_separator(count)
  when .short?     then count_txt = number_to_short_text(count)
  when .html_span? then count_txt = "<span id=\"count\">" + count.to_s + "</span>"
  else                  count_txt = count.to_s
  end

  return translation.gsub("{{count}}", count_txt)
end

def translate_bool(locale : String?, translation : Bool)
  case translation
  when true
    return translate(locale, "Yes")
  when false
    return translate(locale, "No")
  end
end
