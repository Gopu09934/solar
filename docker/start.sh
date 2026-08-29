#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi
if [ -z "${AUDIO_URL:-}" ]; then
    echo "ERROR: AUDIO_URL is not set"
    echo "The video sources have no audio track, so AUDIO_URL (one or more"
    echo "background music/ambience files) is required. Same format as"
    echo "VIDEO_URL — comma-separated for multiple tracks: url1,url2,url3"
    exit 1
fi

# Subscriber count + live viewer count are optional — if the API creds
# aren't provided, those panel elements just stay blank instead of
# failing the whole stream.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

# Live space-weather panel (solar wind speed, density, IMF Bz, Kp index,
# X-ray flare class) — pulled from NOAA SWPC's public JSON feeds, which
# need no API key/auth, so this is on by default. Can still be disabled
# explicitly if a runner has no network access to swpc.noaa.gov.
SHOW_SPACE_WEATHER=true
if [ "${DISABLE_SPACE_WEATHER:-false}" = "true" ]; then
    echo "NOTICE: DISABLE_SPACE_WEATHER=true — space weather panel will be hidden."
    SHOW_SPACE_WEATHER=false
fi
NOAA="https://services.swpc.noaa.gov"

echo "========================================"
echo "Starting 24/7 YouTube Stream (Sun / SDO Overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="solar_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll
CHANNEL_NAME="Solar Watch Live"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))
FACT_FONTSIZE=16
FACT_LINE_SPACING=7
FACT_LINE_H=$((FACT_FONTSIZE + FACT_LINE_SPACING))

# ---------------------------------------------------------------
# Layout: the Sun stays centered and full-height. A dedicated
# panel sits on EACH side (left = story/headlines, right = live
# stats + instrument info + fun facts), instead of the single
# left-hand panel drawn over the video in the original design.
# Because nothing now overlaps the video, panels can use a solid
# background instead of a semi-transparent one over footage.
# ---------------------------------------------------------------
PANEL_W=333          # width of each side panel
CENTER_X0=$PANEL_W                     # left edge of the video strip
CENTER_W=$((1280 - PANEL_W * 2))       # width of the video strip (614)
RIGHT_X0=$((1280 - PANEL_W))           # left edge of the right panel (947)
TEXT_INSET=33                          # left panel text left-inset
RTEXT_INSET=$((RIGHT_X0 + 33))         # right panel text left-inset
PANEL_TEXT_W=$((PANEL_W - 66))         # usable text width inside a panel

# ---------------------------------------------------------------
# Center strip: 3 stacked bands, video kept large on top —
#   Row 1 - the live SDO video (still running continuously, larger
#           now than the old 4-row split)
#   Row 2 - a compact mission-status info block (text)
#   Row 3 - an animated "geomagnetic activity" visualization
# ---------------------------------------------------------------
VIDEO_ROW_H=340                  # video band height
INFO_ROW_H=190                   # mission-status band height
GRAPH_ROW_H=$((720 - VIDEO_ROW_H - INFO_ROW_H))  # 190 - remaining space
ROW1_Y=0                         # video
ROW2_Y=$((VIDEO_ROW_H))          # 340 - info
ROW3_Y=$((VIDEO_ROW_H + INFO_ROW_H))  # 530 - visualization
MTEXT_INSET=$((CENTER_X0 + 30))  # center-strip text left-inset
MVALUE_X=$((MTEXT_INSET + 150))  # x for the value half of a label:value row

# Don't show "N watching now" until the live viewer count reaches this
# many — a very low number (e.g. "5 watching") reads worse to a new
# visitor than showing nothing at all. Raise/lower to taste.
VIEWER_MIN_TO_SHOW=10


#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries
IMAGE_SLIDE_SECONDS="${IMAGE_SLIDE_SECONDS:-25}"  # how long a static image slide stays up

mkdir -p "$ASSET_DIR"

#############################################
# Background audio (one or more tracks, looped)
#
# The source video has no audio, so shared
# music/ambience tracks are downloaded ONCE here
# (same comma-separated format as VIDEO_URL) and
# rotated across videos — each video picks the
# next track in the list and loops it locally
# (via -stream_loop -1) for its own duration.
# Because each video is streamed by its own
# separate ffmpeg process (see run_video), a
# track always restarts from its beginning at
# the start of whichever video it's assigned to,
# rather than playing as one continuous playhead
# across the whole 24 hours.
#
# Downloaded once (not re-fetched per video) so
# a flaky/slow AUDIO_URL host can't stall video
# transitions, and so -stream_loop is looping
# local files instead of repeatedly re-requesting
# a remote URL every time it repeats.
#############################################
IFS=',' read -ra RAW_AUDIO_URLS <<< "$AUDIO_URL"
AUDIO_LOCAL_FILES=()
audio_i=0
for au in "${RAW_AUDIO_URLS[@]}"; do
    au="${au#"${au%%[![:space:]]*}"}"
    au="${au%"${au##*[![:space:]]}"}"
    [ -z "$au" ] && continue
    audio_i=$((audio_i + 1))
    dest="bg_audio_track_${audio_i}"
    echo "Downloading background audio track ${audio_i}..."
    if curl -sL --fail -o "$dest" "$au" && [ -s "$dest" ]; then
        AUDIO_LOCAL_FILES+=("$dest")
        echo "  OK ($(du -h "$dest" | cut -f1))"
    else
        echo "  WARNING: failed to download track ${audio_i} — skipping it."
    fi
done

NUM_AUDIO=${#AUDIO_LOCAL_FILES[@]}
AUDIO_AVAILABLE=false
if [ "$NUM_AUDIO" -gt 0 ]; then
    AUDIO_AVAILABLE=true
    echo "Loaded $NUM_AUDIO background audio track(s); rotating across videos."
else
    echo "WARNING: no background audio tracks downloaded — stream will run with silent audio instead."
fi
AUDIO_COUNTER=0   # persists across the whole run; advances one track per video

#############################################
# Panel decoration images (Earth / Sun stills)
#
# NOT part of the video rotation — this is a
# single small static thumbnail placed into the
# otherwise-empty horizontal gap to the right of
# the text in the center strip's "MISSION
# STATUS" card, rotating through all 4 images
# across videos. URLs are hardcoded per request
# rather than env-configurable.
#
# Downloaded once here (same reasoning as the
# background-audio downloads above) and fed to
# ffmpeg with -loop 1 -framerate 30 further
# down, so — like the image-slide feature —
# they're always composited at a clean, steady
# 30fps rather than whatever a default would be.
#############################################
PANEL_IMAGE_URLS=(
    "https://github.com/Gopu09934/solar/releases/download/as/sun1.jpg"
    "https://github.com/Gopu09934/solar/releases/download/as/earth1.jpg"
    "https://github.com/Gopu09934/solar/releases/download/as/sun2.jpg"
    "https://github.com/Gopu09934/solar/releases/download/as/earth2.jpg"
)
PANEL_IMAGE_LOCAL_FILES=()
pimg_i=0
for piu in "${PANEL_IMAGE_URLS[@]}"; do
    pimg_i=$((pimg_i + 1))
    dest="panel_img_${pimg_i}.jpg"
    echo "Downloading panel image ${pimg_i} ($(basename "$piu"))..."
    if curl -sL --fail -o "$dest" "$piu" && [ -s "$dest" ]; then
        PANEL_IMAGE_LOCAL_FILES+=("$dest")
        echo "  OK ($(du -h "$dest" | cut -f1))"
    else
        echo "  WARNING: failed to download panel image ${pimg_i} — panel thumbnails will be skipped."
    fi
done
NUM_PANEL_IMAGES=${#PANEL_IMAGE_LOCAL_FILES[@]}
PANEL_IMAGES_AVAILABLE=false
if [ "$NUM_PANEL_IMAGES" -gt 0 ]; then
    PANEL_IMAGES_AVAILABLE=true
    echo "Loaded $NUM_PANEL_IMAGES panel thumbnail(s); rotating across left/right/center slots."
else
    echo "WARNING: no panel thumbnails downloaded — left/right/center panel image slots will stay empty."
fi
PANEL_IMAGE_COUNTER=0   # persists across the whole run; rotates which image lands in which slot

#############################################
# Generate the coordinate-label marker dot once
# at startup: a small transparent PNG with a
# gold-filled center and white ring, matching
# the panel's gold accent color. Used by
# build_labels_chain() as ffmpeg input index 2.
# Always generated (cheap, one frame, 20x20) —
# harmless/unused by ffmpeg on videos that don't
# have a matching .labels.txt file.
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=232; GOLD_G=163; GOLD_B=61
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
    # Guarantee the file always exists and is a valid PNG, even in the
    # unlikely case the geq-based generation above fails — this is what
    # gets passed to ffmpeg as a real input on every stream start, so it
    # must never be missing. Falls back to an invisible 1x1 transparent
    # pixel (labels would render without a visible dot, but the stream
    # itself keeps running instead of crashing on a missing input file).
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer (avoids fragile
# drawtext %{gmtime} expansion syntax)
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Background subscriber-count writer
# (polls YouTube Data API every 60s — subs
# don't change second to second, and this
# respects API quota)
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+')
            if [ -n "$COUNT" ]; then
                # Manual comma insertion — locale-independent, so it works
                # the same regardless of the container's default locale
                # (printf "%'d" silently fails to group digits under the
                # bare "C" locale that Ubuntu containers ship with).
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
# Strategy: find the channel's currently-live
# video once (search.list — costs more quota,
# so only called when we don't already have an
# id), then poll videos.list (cheap, 1 unit)
# every 30s for concurrentViewers. If the
# broadcast ends/restarts, re-search.
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/')
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*')
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                elif [ -n "$VIEWERS" ]; then
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

#############################################
# Background space-weather writer
#
# Polls NOAA SWPC's public real-time JSON feeds
# (no API key required) every 60s and writes
# individually-formatted lines for the right
# panel's LIVE READINGS block:
#   - solar wind bulk speed + proton density  (rtsw_wind_1m.json)
#   - IMF Bz (GSM)                            (rtsw_mag_1m.json)
#   - planetary Kp index                      (planetary_k_index_1m.json)
#   - current X-ray flare class (A/B/C/M/X)   (xrays-1-day.json, long/0.1-0.8nm channel)
#
# All parsing is done with a single python3
# process per cycle (these feeds are JSON
# arrays of objects, which is painful to parse
# reliably with grep/sed the way the simpler
# YouTube counters above do). Each field is
# fetched independently and wrapped in its own
# try/except so one feed being down/slow/rate-
# limited doesn't blank out the others — same
# "degrade one field, not the whole panel"
# approach as SHOW_STATS above.
#############################################
printf ' ' > "$ASSET_DIR/wind_speed.txt"
printf ' ' > "$ASSET_DIR/wind_density.txt"
printf ' ' > "$ASSET_DIR/bz.txt"
printf ' ' > "$ASSET_DIR/kp.txt"
printf ' ' > "$ASSET_DIR/xray_class.txt"
SPACEWEATHER_PID=""
if [ "$SHOW_SPACE_WEATHER" = true ]; then
    cat > space_weather_poll.py << 'PYEOF'
import json
import urllib.request
import sys

NOAA = sys.argv[1]
ASSET_DIR = sys.argv[2]

def fetch(path):
    with urllib.request.urlopen(f"{NOAA}{path}", timeout=15) as r:
        return json.loads(r.read())

def latest_numeric(records, key, active_only=False):
    # Walk backwards for the most recent record that actually has a
    # usable numeric value for `key` — the newest record or two is
    # often still null/pending on these real-time feeds.
    #
    # active_only=True restricts the search to records the feed marks
    # "active": true. As of NOAA's March 2026 RTSW schema change
    # (services.swpc.noaa.gov/json/rtsw/*), each minute has one row per
    # candidate spacecraft (e.g. SOLAR1, ACE, IMAP) but only one is the
    # officially designated real-time source at a time; mixing rows
    # from different spacecraft gives an inconsistent-looking readout.
    for rec in reversed(records):
        if active_only and rec.get("active") is not True:
            continue
        v = rec.get(key)
        if v is None:
            continue
        try:
            return float(v)
        except (TypeError, ValueError):
            continue
    return None

def latest_numeric_any_key(records, keys, active_only=False):
    # Same as latest_numeric, but tries several possible field names in
    # order and returns the first that resolves. Used where NOAA's exact
    # key name for a feed couldn't be confirmed ahead of time, so the
    # poller stays working even if the schema differs slightly from what
    # was assumed.
    for key in keys:
        v = latest_numeric(records, key, active_only=active_only)
        if v is not None:
            return v
    return None

def write(name, text):
    tmp = f"{ASSET_DIR}/{name}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    import os
    os.replace(tmp, f"{ASSET_DIR}/{name}.txt")

def xray_flare_class(flux):
    # Standard GOES X-ray flare classification: letter by decade,
    # number is the mantissa within that decade.
    if flux is None or flux <= 0:
        return None
    import math
    if flux < 1e-7:
        letter, base = "A", 1e-8
    elif flux < 1e-6:
        letter, base = "B", 1e-7
    elif flux < 1e-5:
        letter, base = "C", 1e-6
    elif flux < 1e-4:
        letter, base = "M", 1e-5
    else:
        letter, base = "X", 1e-4
    mag = flux / base
    return f"{letter}{mag:.1f}"

# --- Solar wind speed + density ---
# NOTE: NOAA restructured this feed in a March 2026 schema change
# (services.swpc.noaa.gov/json/rtsw/*): each row now carries a "source"
# (e.g. "SOLAR1", "ACE", "IMAP") and an "active" flag, and the value
# fields were renamed from "speed"/"density" to "proton_speed"/
# "proton_density". active_only=True keeps this reading consistent by
# only reading the row from whichever spacecraft is currently
# designated as the real-time source.
try:
    wind = fetch("/json/rtsw/rtsw_wind_1m.json")
    speed = latest_numeric_any_key(
        wind, ["proton_speed", "speed"], active_only=True
    )
    density = latest_numeric_any_key(
        wind, ["proton_density", "density"], active_only=True
    )
    # Fall back to any source (not just the active one) if the active
    # row itself doesn't have a usable value yet.
    if speed is None:
        speed = latest_numeric_any_key(wind, ["proton_speed", "speed"])
    if density is None:
        density = latest_numeric_any_key(wind, ["proton_density", "density"])
    write("wind_speed", f"{speed:,.0f} km/s" if speed is not None else " ")
    write("wind_density", f"{density:.1f} p/cc" if density is not None else " ")
except Exception:
    pass

# --- IMF Bz (GSM) ---
try:
    mag = fetch("/json/rtsw/rtsw_mag_1m.json")
    bz = latest_numeric(mag, "bz_gsm", active_only=True)
    if bz is None:
        bz = latest_numeric(mag, "bz_gsm")
    write("bz", f"{bz:+.1f} nT" if bz is not None else " ")
except Exception:
    pass

# --- Planetary Kp index ---
# Field name for this feed couldn't be independently confirmed while
# writing this poller, so several plausible names are tried in order;
# whichever one actually exists in the live feed will be picked up.
try:
    kp_records = fetch("/json/planetary_k_index_1m.json")
    kp = latest_numeric_any_key(
        kp_records, ["kp_index", "estimated_kp", "kp", "k_index", "Kp"]
    )
    write("kp", f"{kp:.1f}" if kp is not None else " ")
except Exception:
    pass

# --- X-ray flare class (long/0.1-0.8nm channel) ---
try:
    xrays = fetch("/json/goes/primary/xrays-1-day.json")
    long_records = [r for r in xrays if r.get("energy") == "0.1-0.8nm"]
    flux = latest_numeric(long_records or xrays, "flux")
    cls = xray_flare_class(flux)
    write("xray_class", cls if cls else " ")
except Exception:
    pass
PYEOF
    (
        while true; do
            python3 space_weather_poll.py "$NOAA" "$ASSET_DIR" 2>/tmp/space_weather_err.log || \
                echo "WARNING: space weather poll cycle failed — $(tail -1 /tmp/space_weather_err.log 2>/dev/null)"
            sleep 60
        done
    ) &
    SPACEWEATHER_PID=$!
    echo "Space weather panel enabled — polling NOAA SWPC every 60s (wind speed, density, Bz, Kp, X-ray class)."
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true; [ -n "$SPACEWEATHER_PID" ] && kill "$SPACEWEATHER_PID" 2>/dev/null || true' EXIT

#############################################
# Static panel text (unchanged across videos)
#############################################
printf 'S O L A R   D Y N A M I C S'        > "$ASSET_DIR/title1.txt"
printf 'O B S E R V A T O R Y'              > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   S O L A R   S T O R Y" > "$ASSET_DIR/header.txt"
printf 'LIVE FROM SDO'                      > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for the Sun, live 24/7'   > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW'                       > "$ASSET_DIR/fact_label.txt"
printf 'INSTRUMENT'                         > "$ASSET_DIR/instr_label.txt"
printf 'SDO · AIA'                          > "$ASSET_DIR/instr_title.txt"

#############################################
# Default headline / fact pools (used as a
# last resort if solar_info.txt / facts.txt
# are missing or empty)
#############################################
DEFAULT_HEADLINES=(
    "NASA's Solar Dynamics Observatory watches the Sun around the clock from Earth orbit."
    "SDO captures the Sun in many wavelengths, each revealing a different layer of its atmosphere."
    "This live view tracks the Sun through solar maximum, the most active point of its eleven-year cycle."
    "Bright active regions glow in extreme ultraviolet light where the Sun's magnetic field is strongest."
    "Powerful X-class flares appear as sudden bright flashes with vertical streaks from camera saturation."
    "Looping plasma structures called prominences and filaments trace the Sun's magnetic field lines."
    "Twice a year Earth passes between SDO and the Sun, producing brief on-screen eclipses."
    "Each SDO frame captures just twelve seconds of real time, the observatory's finest resolution."
    "The 304-angstrom wavelength highlights prominences and filaments arcing above the solar surface."
    "The 171-angstrom wavelength reveals the Sun's outer atmosphere and eruptions along its edge."
    "Occasional blocky dark patches in the footage mark brief gaps in the data stream."
    "Solar maximum brings far more sunspots, flares, and eruptions than the quieter years of the cycle."
    "SDO has been watching the Sun continuously since its launch in 2010."
    "The corona, the Sun's faint outer atmosphere, is far hotter than the surface beneath it."
)

DEFAULT_FACTS=(
    "SDO orbits Earth so it can keep an almost unbroken watch on the Sun."
    "The Sun's visible surface sits around 5,500 degrees Celsius."
    "The Sun's corona can reach temperatures above a million degrees Celsius."
    "A single solar flare can release as much energy as billions of hydrogen bombs."
    "The Sun's magnetic field flips polarity roughly every eleven years."
    "Sunspots are cooler, darker patches caused by intense magnetic activity."
    "A coronal mass ejection can hurl billions of tons of solar plasma into space."
    "Sunlight takes about eight minutes to travel from the Sun to Earth."
    "The Sun holds more than 99 percent of the mass in our solar system."
    "Solar wind streams outward from the Sun and shapes the magnetic fields of nearby planets."
    "X-class flares are the most powerful category and can disrupt radio signals on Earth."
    "Auroras form when solar particles collide with gases in Earth's upper atmosphere."
    "The Sun is a middle-aged star, roughly 4.6 billion years old."
    "Prominences are loops of relatively cool plasma suspended by the Sun's magnetic field."
    "The Sun rotates faster at its equator than near its poles."
    "It takes light from the Sun's core about 100,000 years to reach its surface."
    "The Sun converts about four million tons of mass into energy every second."
    "Solar maximum and solar minimum mark the peaks and lulls of the roughly eleven-year solar cycle."
    "Extreme ultraviolet light lets telescopes like SDO see structures invisible in ordinary light."
    "The Sun is close enough that its light and heat make life on Earth possible."
)

#############################################
# build_labels_chain: optional feature — draws
# pointer/callout labels onto specific
# coordinates in the video (e.g. pointing out
# an active region or a flare), similar to
# hand-annotated documentary footage. Fully
# optional per video: only activates if a file
# named <basename>.labels.txt exists.
#
# File format — one label per line, comma
# separated:
#   x,y,Label text here
# where x,y is the pixel position on the
# 1280x720 output frame that the label should
# point at.
#
# Notes/limits:
#  - Keep label text under ~28 characters — the
#    box is a fixed width and does not
#    reflow/resize to fit longer text.
#  - Coordinates should fall roughly within the
#    center video strip (x between ~350 and
#    ~930) so labels point at the Sun itself
#    rather than overlapping the side panels.
#  - The connector is a right-angle line
#    (vertical then horizontal).
#  - Requires dot_marker.png (generated once at
#    startup) to be wired in as ffmpeg input
#    index 2 — see run_video()'s -i list.
#
# Sets globals: LABELS_CHAIN (filter string to
# append), LABELS_OUT (bracketed output label
# to continue the chain from).
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # `local` on every loop variable here is required — without it these
    # would be global bash variables and would silently clobber the
    # outer stream loop's `i` counter (see prepare_video_content for the
    # full explanation of this bug class).
    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    local xs=() ys=() texts=()
    while IFS=',' read -r x y text; do
        x="$(echo "$x" | tr -d '[:space:]')"
        y="$(echo "$y" | tr -d '[:space:]')"
        text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$x" =~ ^[0-9]+$ ]] || continue
        [[ "$y" =~ ^[0-9]+$ ]] || continue
        [ -z "$text" ] && continue
        xs+=("$x"); ys+=("$y"); texts+=("$text")
    done < "$labels_file"

    local n=${#xs[@]}
    if [ "$n" -eq 0 ]; then
        echo "NOTICE: $labels_file had no valid lines — skipping labels for this video."
        return 0
    fi
    echo "Using coordinate labels: $labels_file ($n label(s))"

    local BOX_H=42
    local V_OFFSET=70
    local H_OFFSET=40
    local ACCENT_W=4
    local BOX_GAP=10
    local LABEL_FONTSIZE=18
    local LABEL_PAD_L=14
    local LABEL_PAD_R=16
    local AVG_CHAR_W=10
    local BOX_W_MIN=110
    local BOX_W_MAX=260
    local placed_x=() placed_y=() placed_w=()
    local k collision tries

    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[1:v]fps=30,split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        local box_w=$(( ${#text} * AVG_CHAR_W + ACCENT_W + LABEL_PAD_L + LABEL_PAD_R ))
        [ "$box_w" -lt "$BOX_W_MIN" ] && box_w=$BOX_W_MIN
        [ "$box_w" -gt "$BOX_W_MAX" ] && box_w=$BOX_W_MAX

        local box_y=$((y - V_OFFSET))
        if [ "$box_y" -lt 20 ]; then
            box_y=$((y + V_OFFSET - BOX_H))
        fi
        local box_x=$((x + H_OFFSET))
        # Keep the label box from drifting into the side panels.
        if [ $((box_x + box_w)) -gt $((RIGHT_X0 - 10)) ]; then
            box_x=$((x - H_OFFSET - box_w))
        fi
        [ "$box_x" -lt $((CENTER_X0 + 10)) ] && box_x=$((CENTER_X0 + 10))

        tries=0
        while :; do
            collision=false
            for ((k = 0; k < ${#placed_x[@]}; k++)); do
                local px="${placed_x[$k]}" py="${placed_y[$k]}" pw="${placed_w[$k]}"
                if [ $((box_x)) -lt $((px + pw + BOX_GAP)) ] && \
                   [ $((box_x + box_w + BOX_GAP)) -gt $((px)) ] && \
                   [ $((box_y)) -lt $((py + BOX_H + BOX_GAP)) ] && \
                   [ $((box_y + BOX_H + BOX_GAP)) -gt $((py)) ]; then
                    collision=true
                    break
                fi
            done
            [ "$collision" = false ] && break
            box_y=$((box_y + BOX_H + BOX_GAP))
            if [ $((box_y + BOX_H)) -gt 700 ]; then
                box_y=20
            fi
            tries=$((tries + 1))
            [ "$tries" -gt 12 ] && break
        done
        placed_x+=("$box_x")
        placed_y+=("$box_y")
        placed_w+=("$box_w")

        local seg_y_top seg_y_bot
        if [ "$box_y" -gt "$y" ]; then
            seg_y_top=$y; seg_y_bot=$box_y
        else
            seg_y_top=$box_y; seg_y_bot=$y
        fi
        local seg_h=$((seg_y_bot - seg_y_top))
        [ "$seg_h" -lt 2 ] && seg_h=2

        local h_left h_w
        if [ "$box_x" -gt "$x" ]; then
            h_left=$x; h_w=$((box_x - x))
        else
            h_left=$box_x; h_w=$((x - box_x))
        fi
        [ "$h_w" -lt 2 ] && h_w=2

        local n1="lbl${idx}_dot" n2="lbl${idx}_v" n3="lbl${idx}_h" n4="lbl${idx}_bg" n5="lbl${idx}_bar" n6="lbl${idx}_outline" n7="lbl${idx}_txt"

        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${GOLD}@0.85:t=fill[${n3}];"
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=1[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8)):shortest=1[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content: (re)loads headlines +
# facts for the video about to stream, and
# rebuilds BASE_CHAIN / FACT_END to match.
#
# Per-video override: if files named
#   <basename>.headlines.txt
#   <basename>.facts.txt
#   <basename>.wavelength.txt   (single line, e.g. "304 Å — Prominences")
# exist (basename = video filename without
# extension), they're used verbatim. The
# wavelength line shows in the right panel's
# INSTRUMENT block — handy since different SDO
# clips use different AIA channels.
#
# Otherwise falls back to the shared pool
# (solar_info.txt / facts.txt / built-in
# defaults), shuffled fresh each video.
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # See build_labels_chain() for why every loop var here must be `local`.
    local i idx

    #########################################
    # Rotate which of the 4 downloaded images appears in the Mission
    # Status card this video (the only panel-thumbnail slot now — left
    # and right panel thumbnails were removed). Sets a global (not
    # local) because run_video() needs this path after this function
    # returns, to build the matching ffmpeg -i arg.
    #########################################
    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        MID_PANEL_IMG="${PANEL_IMAGE_LOCAL_FILES[$((PANEL_IMAGE_COUNTER % NUM_PANEL_IMAGES))]}"
        PANEL_IMAGE_COUNTER=$((PANEL_IMAGE_COUNTER + 1))
        echo "Mission Status panel thumbnail this video: $MID_PANEL_IMG"
    fi

    RAW_LINES=()
    if [ -f "${base}.headlines.txt" ]; then
        echo "Using curated headlines: ${base}.headlines.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
        done < "${base}.headlines.txt"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        local pool=()
        if [ -f "$INFO_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && pool+=("$line")
            done < "$INFO_FILE"
        fi
        [ "${#pool[@]}" -eq 0 ] && pool=("${DEFAULT_HEADLINES[@]}")
        while IFS= read -r line; do
            RAW_LINES+=("$line")
        done < <(printf '%s\n' "${pool[@]}" | shuf)
    fi

    FACTS=()
    if [ -f "${base}.facts.txt" ]; then
        echo "Using curated facts: ${base}.facts.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
        done < "${base}.facts.txt"
    fi
    if [ "${#FACTS[@]}" -eq 0 ]; then
        local fpool=()
        if [ -f "facts.txt" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && fpool+=("$line")
            done < "facts.txt"
        fi
        [ "${#fpool[@]}" -eq 0 ] && fpool=("${DEFAULT_FACTS[@]}")
        while IFS= read -r line; do
            FACTS+=("$line")
        done < <(printf '%s\n' "${fpool[@]}" | shuf)
    fi

    if [ -f "${base}.wavelength.txt" ]; then
        head -n 1 "${base}.wavelength.txt" > "$ASSET_DIR/instr_sub.txt"
    else
        printf 'Extreme ultraviolet imaging of the solar atmosphere' > "$ASSET_DIR/instr_sub.txt"
    fi
    fold -s -w 26 "$ASSET_DIR/instr_sub.txt" > "$ASSET_DIR/instr_sub.wrapped.txt"

    N=${#RAW_LINES[@]}
    CYCLE=$((N * SLOT))
    echo "This video: $N headline(s), rotation cycle ${CYCLE}s"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
    done

    MAX_HEADLINE_LINES=1
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
        [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
    done
    echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

    # ---- Left panel vertical rhythm (headlines + progress + dots) ----
    HEADLINE_Y=230
    PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 40))
    DOTS_Y=$((PROGRESS_Y + 20))

    TICKER_STRING=""
    for i in "${!RAW_LINES[@]}"; do
        TICKER_STRING+="${RAW_LINES[$i]}     •     "
    done
    printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

    FACT_N=${#FACTS[@]}
    FACT_CYCLE=$((FACT_N * FACT_SLOT))
    local max_fact_lines=1
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        echo "${FACTS[$i]}" | fold -s -w 24 > "$ASSET_DIR/fact${idx}.txt"
        lines=$(grep -c '' "$ASSET_DIR/fact${idx}.txt")
        [ "$lines" -gt "$max_fact_lines" ] && max_fact_lines=$lines
    done
    MAX_FACT_LINES=$max_fact_lines

    # ---- Right panel vertical rhythm (stats + instrument + facts) ----
    RSTAT_Y=19            # credits / clock / subs / viewers block start
    RDIV1_Y=$((RSTAT_Y + 4 * 20 + 6))
    RINSTR_LABEL_Y=$((RDIV1_Y + 20))
    RINSTR_TITLE_Y=$((RINSTR_LABEL_Y + 22))
    RINSTR_SUB_Y=$((RINSTR_TITLE_Y + 30))
    RDIV2_Y=$((RINSTR_SUB_Y + 44 + 16))
    RFACT_LABEL_Y=$((RDIV2_Y + 14))
    RFACT_TEXT_Y=$((RFACT_LABEL_Y + 24))

    #########################################
    # Rebuild BASE_CHAIN for this video's content
    #########################################
    # Fit the (typically square) SDO frame into row 1 — now a larger
    # top band (VIDEO_ROW_H tall) instead of a quarter-height strip:
    # scale up so it fully covers CENTER_W x VIDEO_ROW_H, then crop the
    # small excess off the sides. The video keeps running continuously;
    # below it are 2 bands now instead of 3 (the separate "live solar
    # wind" chart was dropped — mission status + one activity graph).
    #
    # fps=30 here (and on every other input that reaches this graph —
    # the dot marker and the panel thumbnail) locks EVERY source to an
    # identical 30fps timeline before anything is composited. Without
    # this, a source video at some other native rate (25fps, 29.97fps,
    # variable framerate, etc.) only gets resampled to 30fps at the
    # very final output stage — by then, small PTS drift accumulated
    # across a long real-time-paced (-re) stream can desync the
    # overlay's internal frame accounting right as it's deciding
    # exactly when the shortest input (this video) has ended, which can
    # stall the whole ffmpeg process at 0:00 instead of exiting cleanly
    # into the next video. Normalizing every input to 30fps at first
    # entry removes that drift entirely.
    CHAIN="color=c=black:s=1280x720[canvas];"
    CHAIN+="[0:v]fps=30,scale=${CENTER_W}:${VIDEO_ROW_H}:force_original_aspect_ratio=increase,crop=${CENTER_W}:${VIDEO_ROW_H}[vidfit];"
    CHAIN+="[canvas][vidfit]overlay=${CENTER_X0}:${ROW1_Y}:shortest=1[base];"

    # Optional coordinate-based callout labels for this video, drawn
    # onto the Sun before the panels so the panels stay on top. Since
    # the video occupies row 1 (y 0-${VIDEO_ROW_H}), a <basename>.labels.txt
    # file's y coordinates should fall within that range to land on the
    # video — see build_labels_chain()'s own doc comment.
    build_labels_chain "$url"
    CHAIN+="$LABELS_CHAIN"

    # ---------------- Broadcast-style corner brackets on the video ----------------
    # Small L-shaped accents at each corner of the video frame — the
    # viewfinder/camera-framing motif used in documentary and news
    # broadcast graphics — instead of a plain rectangle border.
    local BR_L=26 BR_T=3 BR_M=10
    local VX0=$CENTER_X0
    local VX1=$((CENTER_X0 + CENTER_W))
    local VY0=0
    local VY1=$VIDEO_ROW_H
    CHAIN+="${LABELS_OUT}drawbox=x=$((VX0 + BR_M)):y=$((VY0 + BR_M)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br1];"
    CHAIN+="[br1]drawbox=x=$((VX0 + BR_M)):y=$((VY0 + BR_M)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br2];"
    CHAIN+="[br2]drawbox=x=$((VX1 - BR_M - BR_L)):y=$((VY0 + BR_M)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br3];"
    CHAIN+="[br3]drawbox=x=$((VX1 - BR_M - BR_T)):y=$((VY0 + BR_M)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br4];"
    CHAIN+="[br4]drawbox=x=$((VX0 + BR_M)):y=$((VY1 - BR_M - BR_T)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br5];"
    CHAIN+="[br5]drawbox=x=$((VX0 + BR_M)):y=$((VY1 - BR_M - BR_L)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br6];"
    CHAIN+="[br6]drawbox=x=$((VX1 - BR_M - BR_L)):y=$((VY1 - BR_M - BR_T)):w=${BR_L}:h=${BR_T}:color=${GOLD}@0.9:t=fill[br7];"
    CHAIN+="[br7]drawbox=x=$((VX1 - BR_M - BR_T)):y=$((VY1 - BR_M - BR_L)):w=${BR_T}:h=${BR_L}:color=${GOLD}@0.9:t=fill[br8];"
    # Small "SDO LIVE FEED" caption in the bottom-left corner of the
    # video, over a slim gradient-style scrim — a lower-third caption
    # like a documentary/news broadcast uses, instead of bare footage.
    CHAIN+="[br8]drawbox=x=${VX0}:y=$((VY1 - 34)):w=220:h=34:color=black@0.55:t=fill[brcap1];"
    CHAIN+="[brcap1]drawtext=fontfile=${FONT}:text='SDO LIVE FEED':fontcolor=white@0.9:fontsize=13:x=$((VX0 + 14)):y=$((VY1 - 22)):${SHADOW}[brcap2];"
    local prev="brcap2"

    local CARD_PAD=10
    local CARD_X0=$((CENTER_X0 + CARD_PAD))
    local CARD_W=$((CENTER_W - CARD_PAD * 2))

    # ---------------- Row 2: mission-status info block ----------------
    # Bordered "card" background (matches the side panels' framed look),
    # with a two-column label:value layout mirroring the side panels'
    # style instead of loose text.
    local CM3_Y0=$((ROW2_Y + CARD_PAD))
    local CM3_Y1=$((ROW3_Y - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=black@0.22:t=fill[cm3card];"
    CHAIN+="[cm3card]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=${GOLD}@0.3:t=1[cm3border];"

    local CM3_LABEL_Y=$((CM3_Y0 + 20))
    local CM3_LINE1_Y=$((CM3_LABEL_Y + 30))
    local CM3_LINE2_Y=$((CM3_LINE1_Y + 26))
    local CM3_LINE3_Y=$((CM3_LINE2_Y + 26))
    local CM3_LINE4_Y=$((CM3_LINE3_Y + 26))
    local CM3_LINE5_Y=$((CM3_LINE4_Y + 26))

    CHAIN+="[cm3border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM3_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill[cm3z];"
    CHAIN+="[cm3z]drawtext=fontfile=${FONT}:text='MISSION STATUS':fontcolor=${GOLD}@0.85:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM3_LABEL_Y - 6))[cm3z2];"
    CHAIN+="[cm3z2]drawbox=x=${MTEXT_INSET}:y=$((CM3_LABEL_Y + 14)):w=$((CARD_W - 40)):h=1:color=white@0.15:t=fill[cm3a];"
    CHAIN+="[cm3a]drawtext=fontfile=${FONT}:text='INSTRUMENT':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE1_Y}[cm3b];"
    CHAIN+="[cm3b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_title.txt:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE1_Y}[cm3c];"
    CHAIN+="[cm3c]drawtext=fontfile=${FONT}:text='UTC TIME':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE2_Y}[cm3d];"
    CHAIN+="[cm3d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE2_Y}[cm3e];"
    CHAIN+="[cm3e]drawtext=fontfile=${FONT}:text='SOLAR WIND':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE3_Y}[cm3f];"
    CHAIN+="[cm3f]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/wind_speed.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE3_Y}[cm3g];"
    CHAIN+="[cm3g]drawtext=fontfile=${FONT}:text='BZ / KP':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE4_Y}[cm3h];"
    CHAIN+="[cm3h]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bz.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE4_Y}[cm3i];"
    CHAIN+="[cm3i]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/kp.txt:reload=1:fontcolor=white:fontsize=14:x=$((MVALUE_X + 90)):y=${CM3_LINE4_Y}[cm3j];"
    CHAIN+="[cm3j]drawtext=fontfile=${FONT}:text='X-RAY FLARE':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE5_Y}[cm3k];"
    CHAIN+="[cm3k]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/xray_class.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE5_Y}[cm3final];"
    prev="cm3final"

    # ---------------- Center strip: framed Earth/Sun thumbnail ----------------
    # The Mission Status card's label:value text only uses the left
    # ~400px of the card's width — this fills the vacant space to the
    # right of it with a small framed thumbnail instead of leaving it
    # empty.
    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        local MID_X0=$((MTEXT_INSET + 400))
        local MID_AVAIL_W=$(((CARD_X0 + CARD_W - 14) - MID_X0))
        local MID_TOP=$((CM3_LABEL_Y + 14 + 14))
        local MID_BOTTOM=$((CM3_Y1 - 16))
        local MID_AVAIL_H=$((MID_BOTTOM - MID_TOP))
        if [ "$MID_AVAIL_W" -ge 90 ] && [ "$MID_AVAIL_H" -ge 90 ]; then
            local MTHUMB=$MID_AVAIL_W
            [ "$MID_AVAIL_H" -lt "$MTHUMB" ] && MTHUMB=$MID_AVAIL_H
            [ "$MTHUMB" -gt 130 ] && MTHUMB=130
            local MTX=$((MID_X0 + (MID_AVAIL_W - MTHUMB) / 2))
            local MTY=$((MID_TOP + (MID_AVAIL_H - MTHUMB) / 2))
            CHAIN+="[${prev}]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=black@0.6:t=fill[mthumbbg];"
            CHAIN+="[mthumbbg]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=${GOLD}@0.5:t=1[mthumbborder];"
            CHAIN+="[3:v]fps=30,scale=${MTHUMB}:${MTHUMB}:force_original_aspect_ratio=increase,crop=${MTHUMB}:${MTHUMB}[mimg];"
            CHAIN+="[mthumbborder][mimg]overlay=x=${MTX}:y=${MTY}:shortest=1[mthumbfinal];"
            prev="mthumbfinal"
        fi
    fi

    # ---------------- Row 3: "GEOMAGNETIC ACTIVITY" visualization ----------------
    # Line chart (was a bar chart) on a red-bordered card. Drawn as many
    # thin, contiguous segments sampled densely along a smoothly-varying
    # curve (small phase step between adjacent samples, unlike the old
    # per-bar phase jumps) — with no gaps between segments this reads as
    # a continuous traced line rather than individual bars. Colored in
    # gold/red blocks (aurora tones), matching the rest of the section's
    # style. Bounded to end at y=680 (CARD_PAD above the bottom ticker)
    # so it never visually collides with it.
    local CM4_Y0=$((ROW3_Y + CARD_PAD))
    local CM4_Y1=$((680 - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=black@0.22:t=fill[cm4card];"
    CHAIN+="[cm4card]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=${RED}@0.3:t=1[cm4border];"

    local CM4_LABEL_Y=$((CM4_Y0 + 20))
    local CM4_BASE_Y=$((CM4_Y1 - 14))
    local CM4_LINE_MINH=8
    local CM4_LINE_MAXH=$((CM4_BASE_Y - CM4_LABEL_Y - 20))
    local CM4_LINE_START_X=$((MTEXT_INSET - 4))
    local CM4_LINE_WIDTH=$((CARD_W - 40))
    local CM4_STEP=6
    local CM4_LINE_COUNT=$((CM4_LINE_WIDTH / CM4_STEP))
    local CM4_STROKE_H=4
    local CM4_BLOCK_SIZE=12

    CHAIN+="[cm4border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM4_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[cm4a];"
    CHAIN+="[cm4a]drawtext=fontfile=${FONT}:text='GEOMAGNETIC ACTIVITY':fontcolor=white@0.75:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM4_LABEL_Y - 6))[cm4b];"
    prev="cm4b"
    local di dbx dh_expr dy_expr dnxt dcolor dblock
    for ((di = 0; di < CM4_LINE_COUNT; di++)); do
        dbx=$((CM4_LINE_START_X + di * CM4_STEP))
        dh_expr="clip(58+34*sin(2*PI*t/2.6+${di}*0.12)+18*sin(2*PI*t/1.35+${di}*0.19)\,${CM4_LINE_MINH}\,${CM4_LINE_MAXH})"
        dy_expr="${CM4_BASE_Y}-(${dh_expr})"
        dnxt="cm4ln${di}"
        dblock=$((di / CM4_BLOCK_SIZE))
        if (( dblock % 2 == 0 )); then dcolor="${GOLD}@0.9"; else dcolor="${RED}@0.85"; fi
        CHAIN+="[${prev}]drawbox=x=${dbx}:y='${dy_expr}':w=${CM4_STEP}:h=${CM4_STROKE_H}:color=${dcolor}:t=fill[${dnxt}];"
        prev="$dnxt"
    done
    CHAIN+="[${prev}]drawbox=x=$((MTEXT_INSET - 4)):y=${CM4_BASE_Y}:w=$((CARD_W - 40)):h=1:color=white@0.2:t=fill[cm4base];"

    # ---------------- Left panel: story / headlines ----------------
    CHAIN+="[cm4base]drawbox=x=0:y=0:w=${PANEL_W}:h=720:color=black@0.92:t=fill[p1];"
    CHAIN+="[p1]drawbox=x=${PANEL_W}:y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[p2];"
    CHAIN+="[p2]drawbox=x=0:y=0:w=${PANEL_W}:h=4:color=${GOLD}@0.9:t=fill[p3];"

    CHAIN+="[p3]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p4];"
    CHAIN+="[p4]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p5];"
    CHAIN+="[p5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.9:fontsize=13:x=${TEXT_INSET}-text_w+280:y=39[p6];"

    CHAIN+="[p6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=22:x=${TEXT_INSET}:y=95:${SHADOW}[p7];"
    CHAIN+="[p7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=16:x=${TEXT_INSET}:y=123:${SHADOW}[p8];"
    CHAIN+="[p8]drawbox=x=${TEXT_INSET}:y=153:w=${PANEL_TEXT_W}:h=2:color=white@0.3:t=fill[p9];"

    CHAIN+="[p9]drawbox=x=${TEXT_INSET}:y=171:w=8:h=8:color=${GOLD}:t=fill[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=14:x=$((TEXT_INSET + 16)):y=168[p11];"

    local prev="p11"
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local nxt="h${idx}"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=${TEXT_INSET}:y=${HEADLINE_Y}:alpha='${ALPHA}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='STORY PROGRESS':fontcolor=white@0.35:fontsize=9:x=${TEXT_INSET}:y=$((PROGRESS_Y - 15))[pgcap];"
    CHAIN+="[pgcap]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[pg1];"
    CHAIN+="[pg1]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w='${PANEL_TEXT_W}*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill[pg2];"
    prev="pg2"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local nxt="db${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
        prev="$nxt"
    done

    local last=$((N - 1))
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
        if [ "$i" -eq "$last" ]; then
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
            prev="pdotend"
        else
            local nxt="da${idx}"
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
            prev="$nxt"
        fi
    done

    # ---------------- Left panel: live "solar activity" graph ----------------
    # Fills the blank space under the progress dots with an animated
    # equalizer-style bar graph plus a live-looking percentage readout.
    # Every bar is a pure ffmpeg expression (two out-of-phase sine waves
    # per bar, clipped to a min/max height) — no extra background writer
    # needed, and drawbox re-evaluates x/y/w/h every frame so it never
    # looks frozen the way a static overlay would.
    local GRAPH_LABEL_Y=$((DOTS_Y + 40))
    local GRAPH_BASE_Y=$((GRAPH_LABEL_Y + 160))
    local BAR_COUNT=14
    local BAR_W=13
    local BAR_GAP=6
    local BAR_MINH=8
    local BAR_MAXH=100

    CHAIN+="[${prev}]drawbox=x=$((TEXT_INSET - 2)):y=$((GRAPH_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill:enable='lt(mod(t\,1.4)\,0.9)'[sa1];"
    CHAIN+="[sa1]drawtext=fontfile=${FONT}:text='SOLAR ACTIVITY':fontcolor=white@0.55:fontsize=11:x=$((TEXT_INSET + 14)):y=$((GRAPH_LABEL_Y - 8))[sa2];"
    CHAIN+="[sa2]drawtext=fontfile=${FONT}:text='%{eif\:64+24*sin(2*PI*t/11)\:d} PCT':fontcolor=${GOLD}:fontsize=16:x=${TEXT_INSET}:y=$((GRAPH_LABEL_Y + 10)):${SHADOW}[sa3];"
    prev="sa3"

    local bi bx h_expr y_expr bnxt
    for ((bi = 0; bi < BAR_COUNT; bi++)); do
        bx=$((TEXT_INSET + bi * (BAR_W + BAR_GAP)))
        h_expr="clip(60+38*sin(2*PI*t/3.1+${bi}*0.55)+18*sin(2*PI*t/1.6+${bi}*0.9)\,${BAR_MINH}\,${BAR_MAXH})"
        y_expr="${GRAPH_BASE_Y}-(${h_expr})"
        bnxt="sabar${bi}"
        CHAIN+="[${prev}]drawbox=x=${bx}:y='${y_expr}':w=${BAR_W}:h='${h_expr}':color=${GOLD}@0.8:t=fill[${bnxt}];"
        prev="$bnxt"
    done
    CHAIN+="[${prev}]drawbox=x=${TEXT_INSET}:y=${GRAPH_BASE_Y}:w=${PANEL_TEXT_W}:h=1:color=white@0.2:t=fill[sabase];"
    prev="sabase"

    # ---------------- Right panel: stats + instrument + facts ----------------
    CHAIN+="[${prev}]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=720:color=black@0.92:t=fill[r1];"
    CHAIN+="[r1]drawbox=x=$((RIGHT_X0 - 3)):y=0:w=3:h=720:color=${GOLD}@0.75:t=fill[r2];"
    CHAIN+="[r2]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=4:color=${GOLD}@0.9:t=fill[r3];"

    CHAIN+="[r3]drawtext=fontfile=${FONT}:text='Credits\: NASA / SDO':fontcolor=white@0.85:fontsize=14:x=${RTEXT_INSET}:y=${RSTAT_Y}[r4];"
    CHAIN+="[r4]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=${RTEXT_INSET}:y=$((RSTAT_Y + 20))[r5];"
    CHAIN+="[r5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 40))[r6];"
    CHAIN+="[r6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=white@0.75:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 60))[r7];"

    CHAIN+="[r7]drawbox=x=${RTEXT_INSET}:y=${RDIV1_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[r8];"

    CHAIN+="[r8]drawbox=x=${RTEXT_INSET}:y=${RINSTR_LABEL_Y}:w=8:h=8:color=${GOLD}:t=fill[r9];"
    CHAIN+="[r9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_label.txt:fontcolor=${GOLD}:fontsize=14:x=$((RTEXT_INSET + 16)):y=$((RINSTR_LABEL_Y - 3))[r10];"
    CHAIN+="[r10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_title.txt:fontcolor=white:fontsize=20:x=${RTEXT_INSET}:y=${RINSTR_TITLE_Y}:${SHADOW}[r11];"
    CHAIN+="[r11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_sub.wrapped.txt:fontcolor=white@0.75:fontsize=14:line_spacing=6:x=${RTEXT_INSET}:y=${RINSTR_SUB_Y}[r12];"

    CHAIN+="[r12]drawbox=x=${RTEXT_INSET}:y=${RDIV2_Y}:w=${PANEL_TEXT_W}:h=2:color=${GOLD}@0.4:t=fill[r13];"
    CHAIN+="[r13]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=${RTEXT_INSET}:y=${RFACT_LABEL_Y}[r14];"
    prev="r14"
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        local start=$((i * FACT_SLOT))
        local end=$((start + FACT_SLOT))
        local nxt="f${idx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.9:fontsize=${FACT_FONTSIZE}:line_spacing=${FACT_LINE_SPACING}:x=${RTEXT_INSET}:y=${RFACT_TEXT_Y}:alpha='${FALPHA}'[${nxt}];"
        prev="$nxt"
    done

    # ---------------- Right panel: live space-weather readings + EUV graph ----------------
    # Real NOAA SWPC numbers (solar wind speed/density, IMF Bz, planetary
    # Kp index, current X-ray flare class) fed by the background
    # space-weather poller above, refreshed via reload=1 the same way
    # the clock/subs/viewers lines are. Falls back to blank lines
    # automatically if SHOW_SPACE_WEATHER=false (files stay as a single
    # space, so drawtext just renders nothing).
    local RREAD_DIV_Y=$((RFACT_TEXT_Y + MAX_FACT_LINES * FACT_LINE_H + 16))
    local RREAD_LABEL_Y=$((RREAD_DIV_Y + 14))
    local RREAD_LINE1_Y=$((RREAD_LABEL_Y + 22))
    local RREAD_LINE2_Y=$((RREAD_LINE1_Y + 20))
    local RREAD_LINE3_Y=$((RREAD_LINE2_Y + 20))
    local RREAD_LINE4_Y=$((RREAD_LINE3_Y + 20))
    local RGRAPH_LABEL_Y=$((RREAD_LINE4_Y + 30))

    CHAIN+="[${prev}]drawbox=x=${RTEXT_INSET}:y=${RREAD_DIV_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[rr0];"
    CHAIN+="[rr0]drawtext=fontfile=${FONT}:text='SPACE WEATHER (NOAA)':fontcolor=${GOLD}@0.85:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LABEL_Y}[rr0b];"
    CHAIN+="[rr0b]drawtext=fontfile=${FONT}:text='SOLAR WIND':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE1_Y}[rr0c];"
    CHAIN+="[rr0c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/wind_speed.txt:reload=1:fontcolor=white:fontsize=14:x=$((RTEXT_INSET + 110)):y=${RREAD_LINE1_Y}[rr1];"
    CHAIN+="[rr1]drawtext=fontfile=${FONT}:text='DENSITY':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE2_Y}[rr1b];"
    CHAIN+="[rr1b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/wind_density.txt:reload=1:fontcolor=white:fontsize=14:x=$((RTEXT_INSET + 110)):y=${RREAD_LINE2_Y}[rr2];"
    CHAIN+="[rr2]drawtext=fontfile=${FONT}:text='BZ (GSM)':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE3_Y}[rr2b];"
    CHAIN+="[rr2b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bz.txt:reload=1:fontcolor=white:fontsize=14:x=$((RTEXT_INSET + 110)):y=${RREAD_LINE3_Y}[rr2c];"
    CHAIN+="[rr2c]drawtext=fontfile=${FONT}:text='KP INDEX':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE4_Y}[rr2d];"
    CHAIN+="[rr2d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/kp.txt:reload=1:fontcolor=white:fontsize=14:x=$((RTEXT_INSET + 110)):y=${RREAD_LINE4_Y}[rr3];"
    prev="rr3"

    CHAIN+="[${prev}]drawbox=x=$((RTEXT_INSET - 2)):y=$((RGRAPH_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[rg1];"
    CHAIN+="[rg1]drawtext=fontfile=${FONT}:text='X-RAY FLARE CLASS':fontcolor=white@0.55:fontsize=11:x=$((RTEXT_INSET + 14)):y=$((RGRAPH_LABEL_Y - 8))[rg1b];"
    CHAIN+="[rg1b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/xray_class.txt:reload=1:fontcolor=${GOLD}:fontsize=16:x=${RTEXT_INSET}:y=$((RGRAPH_LABEL_Y + 10)):${SHADOW}[rg2];"
    prev="rg2"

    # ---------------- Right panel: activity-level pie chart ----------------
    # Animated pie chart (was a bar-equalizer graph) drawn procedurally
    # with geq: a filled wedge whose angle tracks a smooth, live-looking
    # percentage — same sine-driven "fake live" approach as the other
    # gauges in this script (e.g. SOLAR ACTIVITY). geq needs its own
    # independent color-source input (like "canvas" at the very top of
    # this whole chain) since it isn't derived from the video, and per
    # the shortest=1 fix used elsewhere in this script, that overlay
    # MUST use shortest=1 or the whole stream can hang forever once the
    # video ends (this exact bug class was fixed for the panel
    # thumbnail and the coordinate-label dot marker earlier).
    local PIE_LABEL_Y=$((RGRAPH_LABEL_Y + 40))
    local PIE_TOP=$((PIE_LABEL_Y + 18))
    local PIE_AVAIL_H=$((700 - PIE_TOP))
    local PIE_SIZE=$PIE_AVAIL_H
    [ "$PIE_SIZE" -gt "$PANEL_TEXT_W" ] && PIE_SIZE=$PANEL_TEXT_W
    [ "$PIE_SIZE" -gt 140 ] && PIE_SIZE=140
    local PIE_CX=$((PIE_SIZE / 2))
    local PIE_CY=$((PIE_SIZE / 2))
    local PIE_R=$((PIE_SIZE / 2 - 4))
    local PIE_X=$((RTEXT_INSET + (PANEL_TEXT_W - PIE_SIZE) / 2))
    local PIE_Y=$PIE_TOP

    local PIE_DIST="hypot(X-${PIE_CX}\,Y-${PIE_CY})"
    local PIE_THETA="mod(atan2(Y-${PIE_CY}\,X-${PIE_CX})+PI/2+2*PI\,2*PI)"
    local PIE_FILL_ANGLE="(2*PI*(50+35*sin(2*PI*T/12))/100)"
    local PIE_R_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${GOLD_R}\,45)\,0)"
    local PIE_G_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${GOLD_G}\,45)\,0)"
    local PIE_B_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${GOLD_B}\,45)\,0)"
    local PIE_A_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,255\,0)"

    CHAIN+="[${prev}]drawbox=x=$((RTEXT_INSET - 2)):y=$((PIE_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill[rgp1];"
    CHAIN+="[rgp1]drawtext=fontfile=${FONT}:text='ACTIVITY LEVEL':fontcolor=white@0.55:fontsize=11:x=$((RTEXT_INSET + 14)):y=$((PIE_LABEL_Y - 8))[rgp2];"
    CHAIN+="color=c=black@0:s=${PIE_SIZE}x${PIE_SIZE}[pie_src];"
    CHAIN+="[pie_src]format=rgba,geq=r='${PIE_R_EXPR}':g='${PIE_G_EXPR}':b='${PIE_B_EXPR}':a='${PIE_A_EXPR}'[pie_img];"
    CHAIN+="[rgp2][pie_img]overlay=x=${PIE_X}:y=${PIE_Y}:shortest=1[rgp3];"
    CHAIN+="[rgp3]drawtext=fontfile=${FONT}:text='%{eif\:50+35*sin(2*PI*t/12)\:d} PCT':fontcolor=white:fontsize=18:x=$((PIE_X + PIE_SIZE / 2 - 34)):y=$((PIE_Y + PIE_SIZE / 2 - 9)):${SHADOW}[rgp4];"
    CHAIN+="[rgp4]drawbox=x=${RTEXT_INSET}:y=$((PIE_Y + PIE_SIZE + 15)):w=${PANEL_TEXT_W}:h=1:color=white@0.2:t=fill[rgbase];"
    prev="rgbase"

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter: appends the CTA / next-
# video countdown / ticker / watermark section
# onto BASE_CHAIN. Called fresh for each video
# since the countdown depends on that video's
# probed duration.
#############################################
build_final_filter() {
    local total_duration="$1"
    local tail="$BASE_CHAIN"

    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local COUNTDOWN_ENABLE="not(${CTA_ENABLE})"

    # CTA / countdown box sits centered under the Sun, inside the video
    # strip, so it doesn't have to compete for space with either panel.
    local CTA_W=460
    local CTA_X=$((CENTER_X0 + (CENTER_W - CTA_W) / 2))
    local CTA_Y=640

    tail+="[${FACT_END}]drawbox=x=${CTA_X}:y=${CTA_Y}:w=${CTA_W}:h=43:color=black@0.75:t=fill[cta_bg];"
    tail+="[cta_bg]drawbox=x=${CTA_X}:y=${CTA_Y}:w=4:h=43:color=${GOLD}:t=fill[cta_bar];"
    tail+="[cta_bar]drawbox=x=$((CTA_X + 22)):y=$((CTA_Y + 16)):w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):alpha='${CTA_ALPHA}'[cta_sub];"

    if [[ "$total_duration" =~ ^[0-9]+$ ]] && [ "$total_duration" -gt 0 ]; then
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Next view in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    else
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Coming up next...':fontcolor=white@0.85:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    fi

    # Bottom ticker spans the full width, under both panels and the Sun.
    tail+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=black@0.85:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.9:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
    tail+="[tk5]drawtext=fontfile=${FONT}:text='LIVE NOW':fontcolor=black:fontsize=15:x=13:y=695[tk6];"

    tail+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=white@0.45:fontsize=14:borderw=1.5:bordercolor=black@0.7:x=(w-text_w)/2:y=657[final]"

    echo "$tail"
}

#############################################
# is_image_url: true if the URL's file
# extension marks it as a static image (jpg,
# jpeg, png, gif, bmp, webp) rather than a
# video file. Case-insensitive, ignores any
# query string on the URL.
#############################################
is_image_url() {
    local u="${1%%\?*}"
    local ext="${u##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        jpg|jpeg|png|gif|bmp|webp) return 0 ;;
        *) return 1 ;;
    esac
}

#############################################
# get_image_local_path: downloads a static
# image URL once into a local cache file named
# after its basename, then prints that local
# path on stdout. Repeats of the same image
# later in the 24/7 rotation reuse the cached
# file instead of re-fetching it every cycle —
# same reasoning as the background-audio
# downloads at startup. Returns non-zero (and
# prints nothing) if the download fails.
#############################################
get_image_local_path() {
    local url="$1"
    local base="${url##*/}"
    base="${base%%\?*}"
    local dest="img_cache_${base}"
    if [ ! -s "$dest" ]; then
        echo "Downloading image slide: $base" >&2
        if ! curl -sL --fail -o "$dest" "$url"; then
            rm -f "$dest"
            return 1
        fi
    fi
    echo "$dest"
    return 0
}

#############################################
#############################################
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    # Static images (earth1.jpg, sun1.jpg, etc.) are handled completely
    # differently from real video files: no natural duration to probe,
    # no network reconnect logic needed, and they must be explicitly
    # pinned to 30fps + a fixed on-screen duration rather than relying
    # on the source's own framerate/length like a real video clip does.
    local is_image=false
    local stream_source="$url"
    if is_image_url "$url"; then
        is_image=true
        local local_img
        if ! local_img=$(get_image_local_path "$url"); then
            echo "WARNING: failed to download image slide '$url' — skipping it."
            return 1
        fi
        stream_source="$local_img"
        echo "Image slide: $url -> $stream_source"
    fi

    prepare_video_content "$url"

    local duration
    if [ "$is_image" = true ]; then
        # No ffprobe here — a still image has no intrinsic duration.
        # IMAGE_SLIDE_SECONDS both drives the "Next view in Ns" countdown
        # (build_final_filter already accepts any positive integer) and
        # is used below as a hard -t cutoff, since a looped image input
        # never reaches EOF on its own the way a real video does.
        duration="$IMAGE_SLIDE_SECONDS"
        echo "Static image slide — showing for ${duration}s, locked to 30fps."
    else
        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
        duration=${duration%.*}
        [[ "$duration" =~ ^[0-9]+$ ]] || duration=""
        if [ -n "$duration" ]; then
            echo "Probed duration: ${duration}s"
        else
            echo "Could not probe duration — countdown will show generic filler text."
        fi
    fi

    local filter
    filter=$(build_final_filter "$duration")

    # Audio input for this segment: the next track in rotation, looped
    # locally, or a silent fallback if no tracks downloaded at startup.
    local AUDIO_INPUT_ARGS=()
    local AUDIO_MAP="2:a"
    if [ "$AUDIO_AVAILABLE" = true ]; then
        local this_audio="${AUDIO_LOCAL_FILES[$((AUDIO_COUNTER % NUM_AUDIO))]}"
        AUDIO_COUNTER=$((AUDIO_COUNTER + 1))
        echo "Background audio for this video: $this_audio"
        AUDIO_INPUT_ARGS=(-stream_loop -1 -i "$this_audio")
    else
        AUDIO_INPUT_ARGS=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
    fi

    # Panel-thumbnail input (index 3 — right after 0:main, 1:dot-marker,
    # 2:audio). Fixed -framerate 30, same reason as the main image-slide
    # input above: a steady, explicit 30fps instead of a decoder
    # default. Only added at all when downloads succeeded at startup;
    # the filter graph itself was built with the matching
    # PANEL_IMAGES_AVAILABLE check, so the two always agree on whether
    # input 3 exists.
    local PANEL_IMG_INPUT_ARGS=()
    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        PANEL_IMG_INPUT_ARGS=(-loop 1 -framerate 30 -i "$MID_PANEL_IMG")
    fi

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        # Main input: a real video is read live with -re (paced at its
        # own native framerate) plus reconnect flags for network drops.
        # A static image is instead looped locally at an explicit,
        # fixed -framerate 30 — this is the actual fix for "images must
        # run at 30fps" — and since a looped image never reaches EOF on
        # its own, EXTRA_OUTPUT_ARGS adds a hard -t cutoff so the ffmpeg
        # process still exits normally after IMAGE_SLIDE_SECONDS, the
        # same way a real video's natural end normally exits it.
        local MAIN_INPUT_ARGS=()
        local EXTRA_OUTPUT_ARGS=()
        if [ "$is_image" = true ]; then
            MAIN_INPUT_ARGS=(-loop 1 -framerate 30 -i "$stream_source")
            EXTRA_OUTPUT_ARGS=(-t "$duration")
        else
            MAIN_INPUT_ARGS=(-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -re -i "$stream_source")
        fi

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        "${MAIN_INPUT_ARGS[@]}" \
        -loop 1 -framerate 30 -i "$DOT_MARKER" \
        "${AUDIO_INPUT_ARGS[@]}" \
        "${PANEL_IMG_INPUT_ARGS[@]}" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map "$AUDIO_MAP" \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        "${EXTRA_OUTPUT_ARGS[@]}" \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

# Shuffle playback order fresh for every workflow run, so the sequence
# of videos isn't identical every time the container restarts.
if [ "$NUM_URLS" -gt 1 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"

        run_video "$url"

        echo "Loading next video..."
        echo ""
    done
done
