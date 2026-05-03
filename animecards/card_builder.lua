local anki = require 'anki'
local opts = require 'script_options'
local tools = require 'tools'

local card_builder = {}

local function generate_miscinfo(start_time)
  local miscinfo = opts.MISCINFO_PATTERN

  local replacements = {
    ["%%f"] = mp.get_property("filename/no-ext"),
    ["%%F"] = mp.get_property("filename"),
    ["%%t"] = tools.format_time(start_time),
    ["%%T"] = tools.format_time(start_time, true),
  }

  for placeholder, value in pairs(replacements) do
    miscinfo = miscinfo:gsub(placeholder, value)
  end

  return miscinfo
end

local function format_sentence(lines, noteid)
  local mpv_sentence = lines:gsub('\r', ''):gsub('^\n+', ''):gsub('\n+$', ''):gsub('\n+', '<br>')

  if opts.HIGHLIGHT_WORD ~= true then
    return mpv_sentence
  end

  local anki_sentence = anki.get_field_value(noteid, opts.SENTENCE_FIELD)

  if anki_sentence == nil or anki_sentence == '' then
    return mpv_sentence
  elseif mpv_sentence == nil or mpv_sentence == '' then
    return anki_sentence
  end

  -- Looking for content of tag <b>
  local highlighted_text = anki_sentence:match("^.-<b>(.-)</b>.-$")

  if not highlighted_text or highlighted_text == '' then
    return mpv_sentence
  end

  tools.dlog("Found highlighted text: " .. tostring(highlighted_text))

  local pattern = string.format("^(.-)%s(.-)$", highlighted_text)
  local prefix, suffix = mpv_sentence:match(pattern)

  if prefix and suffix then
    local new_sentence = string.format("%s<b>%s</b>%s",
      prefix, highlighted_text, suffix)

    tools.dlog("New sentence with highlight: " .. new_sentence)
    return new_sentence
  else
    return mpv_sentence
  end
end

function card_builder.construct(lines, noteid, start_time, media_name)
  local fields = {
    [opts.SENTENCE_FIELD] = format_sentence(lines, noteid),
    [opts.IMAGE_FIELD] = '<img src=' .. media_name .. '.' .. opts.IMAGE_FORMAT .. '>',
    [opts.SENTENCE_AUDIO_FIELD] = '[sound:' .. media_name .. '.' .. opts.AUDIO_FORMAT .. ']',
  }

  if opts.WRITE_MISCINFO == true then
    fields[opts.MISCINFO_FIELD] = generate_miscinfo(start_time)
  end

  return fields
end

return card_builder
