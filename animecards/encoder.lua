local msg = require 'mp.msg'
local utils = require 'mp.utils'

local anki = require 'anki'
local opts = require 'script_options'
local tools = require 'tools'

local encoder = {}

-- Local functions
---------------------------------------

-- Determines the source audio file and audio track ID.
-- If there is no external audio track, the video file itself is used as the source.
local function define_audio_source()
  local source = mp.get_property("path")
  local audio_id = mp.get_property("aid")
  local tracks_count = mp.get_property_number("track-list/count")

  -- Iterates through all tracks to check for an external audio file
  for index = 0, tracks_count - 1 do
    local track_type = mp.get_property(string.format('track-list/%d/type', index))
    local is_selected = mp.get_property(string.format('track-list/%d/selected', index))

    if track_type == 'audio' and is_selected == 'yes' then
      local external_audio = mp.get_property(string.format('track-list/%d/external-filename', index))

      if external_audio ~= nil then
        tools.dlog('Using an external audio: ' .. external_audio)
        source = external_audio
        audio_id = 'auto' -- since the audio is external, overwrite audio_id
        return source, audio_id
      end

      break
    end
  end

  return source, audio_id
end

local function gen_fade_arg(fade_type, curve, time_pos)
  return string.format("--af-append=afade=t=%s:curve=%s:st=%.3f:d=%.3f", fade_type, curve, time_pos, opts
    .AUDIO_CLIP_FADE)
end

local function gen_jpg_quality_arg(quality)
  quality = math.max(0, math.min(quality, 100)) -- Clamps the value [0; 100]
  local worseness = 100 - quality               -- Inverts quality

  -- Converting to qscale: 2 (best) to 31 (worst)
  local qscale = (worseness * 29 / 100) + 2
  -- The expression "global_quality=N*QP2LAMBDA" replicates `--ovcopts=qscale=N`
  -- behavior, which was removed from mpv (see mpv commit bfc33da)
  return string.format('--ovcopts=global_quality=%.1f*QP2LAMBDA,flags=+qscale', qscale)
end

---------------------------------------

function encoder.verify_libmp3lame()
  local encoderlist = mp.get_property("encoder-list")
  if not encoderlist or not string.find(encoderlist, "libmp3lame") then
    mp.osd_message(
      "Error: libmp3lame encoder not found. Audio export will not work.\nPlease use a build of mpv with libmp3lame support.",
      10)
    msg.error("Error: libmp3lame encoder not found. MP3 audio export will not work.")
  else
    tools.dlog("libmp3lame encoder found.")
  end
end

function encoder.verify_aac()
  local encoderlist = mp.get_property("encoder-list")
  if not encoderlist or not string.find(encoderlist, "aac") then
    mp.osd_message(
      "Error: aac encoder not found. AAC audio export will not work.\nPlease use a build of mpv with aac support.",
      10)
    msg.error("Error: aac encoder not found. AAC audio export will not work.")
  else
    tools.dlog("aac encoder found.")
  end
end

-- Generates a filename (without extension) for both audio and image.
-- Removes non-word characters using gsub and appends timings.
function encoder.gen_name(start_time, end_time)
  start_time = string.format('%.3f', start_time):gsub("%.", "s") .. 'ms'
  end_time = string.format('%.3f', end_time):gsub("%.", "s") .. 'ms'
  local stem = mp.get_property("filename/no-ext"):gsub('[%p%s%c]', '')
  return string.format('%s_%s_%s', stem, start_time, end_time)
end

function encoder.create_audio(name, start_time, end_time)
  local source, audio_id = define_audio_source()
  start_time = start_time - opts.AUDIO_CLIP_PADDING
  local audio_length = end_time - start_time + opts.AUDIO_CLIP_PADDING

  -- Start time may become negative due to padding subtraction
  if start_time < 0 then
    start_time = 0
  end

  local volume = opts.USE_MPV_VOLUME and mp.get_property('volume') or '100'
  local channels = opts.AUDIO_MONO and '1' or 'auto'
  local output = utils.join_path(anki.get_media_dir(), name .. '.' .. opts.AUDIO_FORMAT)

  local cmd = {
    'run', 'mpv', source, '--loop-file=no',
    '--video=no', '--no-ocopy-metadata', '--no-sub',
    string.format('--audio-channels=%s', channels),
    string.format('--start=%.3f', start_time),
    string.format('--length=%.3f', audio_length),
    string.format('--aid=%s', audio_id),
    string.format('--volume=%s', volume),
  }

  if opts.AUDIO_CLIP_FADE > 0 then
    local fadein_arg = gen_fade_arg('in', 'ipar', start_time)
    local fadeout_arg = gen_fade_arg('out', 'ipar', start_time + audio_length - opts.AUDIO_CLIP_FADE)
    table.insert(cmd, fadein_arg)
    table.insert(cmd, fadeout_arg)
  end

  table.insert(cmd, string.format('-o=%s', output))

  mp.commandv(table.unpack(cmd))
  tools.dlog(utils.to_string(cmd))
end

function encoder.create_image(name, timing)
  local source = mp.get_property("path")
  local output = utils.join_path(anki.get_media_dir(), name .. '.' .. opts.IMAGE_FORMAT)

  local cmd = {
    'run', 'mpv', source, '--loop-file=no',
    '--audio=no', '--no-ocopy-metadata',
    '--no-sub', '--frames=1',
  }

  -- Determining format
  if opts.IMAGE_FORMAT == 'webp' then
    table.insert(cmd, '--ovc=libwebp')
    table.insert(cmd, '--ovcopts-add=lossless=0')
    table.insert(cmd, '--ovcopts-add=compression_level=6')
    table.insert(cmd, '--ovcopts-add=preset=drawing')
  elseif opts.IMAGE_FORMAT == 'png' then
    table.insert(cmd, '--vf-add=format=rgb24')
    table.insert(cmd, '--ovc=png')
  elseif opts.IMAGE_FORMAT == 'jpg' then
    table.insert(cmd, '--ovc=mjpeg')
    table.insert(cmd, '--vf-add=scale=out_range=full')
    table.insert(cmd, gen_jpg_quality_arg(opts.JPG_QUALITY))
  end

  -- Determining resolution
  if opts.IMAGE_HEIGHT > 0 then
    table.insert(cmd, string.format('--vf-add=scale=%d*iw*sar/ih:%d',
      opts.IMAGE_HEIGHT, opts.IMAGE_HEIGHT))
  end

  table.insert(cmd, string.format('--start=%.3f', timing))
  table.insert(cmd, '--ofopts-add=update=1')
  table.insert(cmd, string.format('-o=%s', output))

  mp.commandv(table.unpack(cmd))
  tools.dlog(utils.to_string(cmd))
end

function encoder.autoplay(name)
  if opts.AUTOPLAY_AUDIO == true then
    local audio = utils.join_path(anki.get_media_dir(), name .. '.' .. opts.AUDIO_FORMAT)
    local cmd = { 'run', 'mpv', audio, '--loop-file=no', '--load-scripts=no' }
    mp.commandv(table.unpack(cmd))
  end
end

return encoder
