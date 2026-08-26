from pathlib import Path
import zipfile, textwrap, os

outdir = Path("/mnt/data/premium_solar_stream")
outdir.mkdir(exist_ok=True)

script = r'''#!/bin/bash
set -euo pipefail

#############################################
# PREMIUM SOLAR / SDO DOCUMENTARY STREAM
# Drop-in visual refresh for the existing
# VIDEO_URL + AUDIO_URL + YouTube RTMP setup.
#############################################

: "${VIDEO_URL:?ERROR: VIDEO_URL is not set}"
: "${YOUTUBE_STREAM_KEY:?ERROR: YOUTUBE_STREAM_KEY is not set}"

# Audio is optional now; silent fallback is used when absent.
AUDIO_URL="${AUDIO_URL:-}"

WIDTH="${STREAM_WIDTH:-1280}"
HEIGHT="${STREAM_HEIGHT:-720}"
FPS="${STREAM_FPS:-30}"

FONT="${FONT:-font.ttf}"
ASSET_DIR="${ASSET_DIR:-panel_assets}"

# Premium documentary palette
GOLD="0xD6B36A"
CHAMPAGNE="0xE2C98B"
RED="0xFF5A52"
PANEL_BG="0x0C1118"
PANEL_BG_2="0x131B24"
PANEL_BG_3="0x18232E"
WHITE="0xF3F5F7"
MUTED="0x9AA7B5"
LINE="0x526171"

PANEL_W=333
CENTER_X0=$PANEL_W
CENTER_W=$((WIDTH - PANEL_W * 2))
RIGHT_X0=$((WIDTH - PANEL_W))
TEXT_INSET=30
RTEXT_INSET=$((RIGHT_X0 + 30))
PANEL_TEXT_W=$((PANEL_W - 60))

SLOT=7
FACT_SLOT=9
TICKER_SPEED=95
MAX_RETRIES=5
RETRY_DELAY=5

mkdir -p "$ASSET_DIR"

# ---------- Assets ----------
printf 'SOLAR DYNAMICS' > "$ASSET_DIR/title1.txt"
printf 'OBSERVATORY' > "$ASSET_DIR/title2.txt"
printf "TODAY'S SOLAR STORY" > "$ASSET_DIR/header.txt"
printf 'SCIENCE NOTE' > "$ASSET_DIR/fact_label.txt"
printf 'MISSION INSTRUMENT' > "$ASSET_DIR/instr_label.txt"
printf 'AIA / SOLAR DYNAMICS OBSERVATORY' > "$ASSET_DIR/instr_title.txt"
printf 'LIVE FROM EARTH ORBIT' > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE FOR 24/7 SOLAR COVERAGE' > "$ASSET_DIR/cta.txt"

# ---------- Clock ----------
printf ' ' > "$ASSET_DIR/clock.txt"
(
  while true; do
    date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.tmp"
    mv -f "$ASSET_DIR/clock.tmp" "$ASSET_DIR/clock.txt"
    sleep 1
  done
) &
CLOCK_PID=$!

# ---------- Optional YouTube stats ----------
SHOW_STATS=false
if [ -n "${YOUTUBE_API_KEY:-}" ] && [ -n "${YOUTUBE_CHANNEL_ID:-}" ]; then
  SHOW_STATS=true
fi

printf ' ' > "$ASSET_DIR/subs.txt"
printf ' ' > "$ASSET_DIR/viewers.txt"
SUBS_PID=""
VIEWERS_PID=""

if [ "$SHOW_STATS" = true ]; then
  (
    while true; do
      RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
      COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+' | head -1 || true)
      if [ -n "$COUNT" ]; then
        FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
        printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.tmp"
        mv -f "$ASSET_DIR/subs.tmp" "$ASSET_DIR/subs.txt"
      fi
      sleep 60
    done
  ) &
  SUBS_PID=$!

  (
    LIVE_VIDEO_ID=""
    while true; do
      if [ -z "$LIVE_VIDEO_ID" ]; then
        SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
        LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/' || true)
      fi
      if [ -n "$LIVE_VIDEO_ID" ]; then
        VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
        VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*' | head -1 || true)
        if [ -n "$VIEWERS" ]; then
          printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.tmp"
          mv -f "$ASSET_DIR/viewers.tmp" "$ASSET_DIR/viewers.txt"
        fi
      fi
      sleep 30
    done
  ) &
  VIEWERS_PID=$!
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true' EXIT

DEFAULT_HEADLINES=(
 "NASA's Solar Dynamics Observatory watches the Sun around the clock."
 "SDO observes the Sun in multiple wavelengths to reveal its changing atmosphere."
 "Active regions trace intense magnetic fields across the solar surface."
 "Solar flares are sudden bursts of energy from the Sun's magnetic atmosphere."
 "Prominences and filaments trace magnetic structures above the solar limb."
 "Extreme ultraviolet observations reveal structures invisible to the human eye."
 "Solar maximum brings more sunspots, flares and eruptions than quieter years."
 "SDO has continuously monitored the Sun since its launch in 2010."
)

DEFAULT_FACTS=(
 "Sunlight takes about eight minutes to travel from the Sun to Earth."
 "The visible surface of the Sun is about 5,500 degrees Celsius."
 "The solar corona can reach temperatures above one million degrees Celsius."
 "Sunspots are cooler regions associated with intense magnetic fields."
 "A coronal mass ejection can send huge quantities of plasma into space."
 "Auroras can form when solar particles interact with Earth's upper atmosphere."
 "The Sun is roughly 4.6 billion years old."
 "Extreme ultraviolet light reveals hot structures in the solar atmosphere."
)

prepare_content() {
  local url="$1"
  local base="${url##*/}"
  base="${base%.*}"

  RAW_LINES=()
  FACTS=()

  if [ -f "${base}.headlines.txt" ]; then
    while IFS= read -r line; do
      [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
    done < "${base}.headlines.txt"
  fi
  if [ "${#RAW_LINES[@]}" -eq 0 ]; then
    if [ -f solar_info.txt ]; then
      while IFS= read -r line; do
        [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
      done < solar_info.txt
    fi
  fi
  [ "${#RAW_LINES[@]}" -eq 0 ] && RAW_LINES=("${DEFAULT_HEADLINES[@]}")

  if [ -f "${base}.facts.txt" ]; then
    while IFS= read -r line; do
      [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
    done < "${base}.facts.txt"
  fi
  [ "${#FACTS[@]}" -eq 0 ] && FACTS=("${DEFAULT_FACTS[@]}")

  local wavelength="Extreme ultraviolet imaging of the solar atmosphere"
  [ -f "${base}.wavelength.txt" ] && wavelength=$(head -n 1 "${base}.wavelength.txt")
  printf '%s' "$wavelength" > "$ASSET_DIR/instr_sub.txt"
  fold -s -w 29 "$ASSET_DIR/instr_sub.txt" > "$ASSET_DIR/instr_sub.wrapped.txt"

  local i idx
  for i in "${!RAW_LINES[@]}"; do
    idx=$((i+1))
    printf '%s' "${RAW_LINES[$i]}" | fold -s -w 27 > "$ASSET_DIR/headline${idx}.txt"
  done
  for i in "${!FACTS[@]}"; do
    idx=$((i+1))
    printf '%s' "${FACTS[$i]}" | fold -s -w 26 > "$ASSET_DIR/fact${idx}.txt"
  done

  N=${#RAW_LINES[@]}
  FACT_N=${#FACTS[@]}
  CYCLE=$((N*SLOT))
  FACT_CYCLE=$((FACT_N*FACT_SLOT))

  local ticker=""
  for i in "${!RAW_LINES[@]}"; do
    ticker+="${RAW_LINES[$i]}     •     "
  done
  printf '%s' "$ticker" > "$ASSET_DIR/ticker.txt"
}

build_filter() {
  local duration="$1"

  local CHAIN
  CHAIN="color=c=${PANEL_BG}:s=${WIDTH}x${HEIGHT}[canvas];"
  CHAIN+="[0:v]scale=${CENTER_W}:720:force_original_aspect_ratio=increase,crop=${CENTER_W}:720[solar];"
  CHAIN+="[canvas][solar]overlay=${CENTER_X0}:0[base];"

  # Left panel
  CHAIN+="[base]drawbox=x=0:y=0:w=${PANEL_W}:h=720:color=${PANEL_BG}@0.98:t=fill[l1];"
  CHAIN+="[l1]drawbox=x=${PANEL_W}:y=0:w=2:h=720:color=${GOLD}@0.70:t=fill[l2];"
  CHAIN+="[l2]drawbox=x=0:y=0:w=${PANEL_W}:h=3:color=${GOLD}@0.85:t=fill[l3];"
  CHAIN+="[l3]drawbox=x=27:y=27:w=9:h=9:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.65)'[l4];"
  CHAIN+="[l4]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=${WHITE}:fontsize=19:x=45:y=21[l5];"
  CHAIN+="[l5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${MUTED}:fontsize=9:x=27:y=51[l6];"
  CHAIN+="[l6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=${WHITE}:fontsize=25:x=${TEXT_INSET}:y=91[l7];"
  CHAIN+="[l7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=${MUTED}:fontsize=12:x=${TEXT_INSET}:y=123[l8];"
  CHAIN+="[l8]drawbox=x=${TEXT_INSET}:y=153:w=${PANEL_TEXT_W}:h=1:color=${LINE}@0.7:t=fill[l9];"
  CHAIN+="[l9]drawbox=x=${TEXT_INSET}:y=173:w=7:h=7:color=${CHAMPAGNE}:t=fill[l10];"
  CHAIN+="[l10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${CHAMPAGNE}:fontsize=11:x=$((TEXT_INSET+15)):y=168[l11];"

  local i idx start end alpha prev="l11"
  for i in "${!RAW_LINES[@]}"; do
    idx=$((i+1)); start=$((i*SLOT)); end=$((start+SLOT))
    alpha="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.7)\,(mod(t\,${CYCLE})-${start})/0.7\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.7)\,(${end}-mod(t\,${CYCLE}))/0.7\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=${WHITE}:fontsize=17:line_spacing=7:x=${TEXT_INSET}:y=220:alpha='${alpha}'[lh${idx}];"
    prev="lh${idx}"
  done

  CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='STORY PROGRESS':fontcolor=${MUTED}@0.6:fontsize=9:x=${TEXT_INSET}:y=305[lp0];"
  CHAIN+="[lp0]drawbox=x=${TEXT_INSET}:y=322:w=${PANEL_TEXT_W}:h=1:color=${LINE}@0.65:t=fill[lp1];"
  CHAIN+="[lp1]drawbox=x=${TEXT_INSET}:y=321:w='${PANEL_TEXT_W}*mod(t\,${SLOT})/${SLOT}':h=3:color=${CHAMPAGNE}:t=fill[lp2];"

  for i in "${!RAW_LINES[@]}"; do
    idx=$((i+1))
    local x=$((TEXT_INSET+i*17))
    local enable="between(mod(t\,${CYCLE})\,${i*SLOT}\,$(((i+1)*SLOT)))"
    CHAIN+="[lp2]drawbox=x=${x}:y=339:w=6:h=6:color=${MUTED}@0.35:t=fill[ld${idx}];"
    CHAIN+="[ld${idx}]drawbox=x=${x}:y=339:w=6:h=6:color=${CHAMPAGNE}:t=fill:enable='${enable}'[lde${idx}];"
    prev="lde${idx}"
  done

  # Scientific activity trace
  CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='SOLAR ACTIVITY INDEX':fontcolor=${MUTED}:fontsize=10:x=${TEXT_INSET}:y=378[sg0];"
  CHAIN+="[sg0]drawtext=fontfile=${FONT}:text='%{eif\\:64+18*sin(t/7)\\:d}  /  100':fontcolor=${CHAMPAGNE}:fontsize=15:x=${TEXT_INSET}:y=399[sg1];"
  prev="sg1"

  local BAR_COUNT=18 BAR_W=8 BAR_GAP=5 bi bx h_expr y_expr
  local graph_base=535
  for ((bi=0; bi<BAR_COUNT; bi++)); do
    bx=$((TEXT_INSET+bi*(BAR_W+BAR_GAP)))
    h_expr="clip(25+26*sin(2*PI*t/5.8+${bi}*0.42)+12*sin(2*PI*t/2.7+${bi}*0.81)\,6\,80)"
    y_expr="${graph_base}-(${h_expr})"
    CHAIN+="[${prev}]drawbox=x=${bx}:y='${y_expr}':w=${BAR_W}:h='${h_expr}':color=${CHAMPAGNE}@0.62:t=fill[bar${bi}];"
    prev="bar${bi}"
  done
  CHAIN+="[${prev}]drawbox=x=${TEXT_INSET}:y=${graph_base}:w=${PANEL_TEXT_W}:h=1:color=${LINE}@0.6:t=fill[leftfinal];"

  # Right panel
  CHAIN+="[leftfinal]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=720:color=${PANEL_BG}@0.98:t=fill[r1];"
  CHAIN+="[r1]drawbox=x=$((RIGHT_X0-2)):y=0:w=2:h=720:color=${GOLD}@0.70:t=fill[r2];"
  CHAIN+="[r2]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=3:color=${GOLD}@0.85:t=fill[r3];"
  CHAIN+="[r3]drawtext=fontfile=${FONT}:text='MISSION CONTROL':fontcolor=${MUTED}:fontsize=10:x=${RTEXT_INSET}:y=22[r4];"
  CHAIN+="[r4]drawtext=fontfile=${FONT}:text='NASA / SDO':fontcolor=${WHITE}:fontsize=16:x=${RTEXT_INSET}:y=45[r5];"
  CHAIN+="[r5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${CHAMPAGNE}:fontsize=12:x=${RTEXT_INSET}:y=72[r6];"
  CHAIN+="[r6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=${MUTED}:fontsize=11:x=${RTEXT_INSET}:y=94[r7];"
  CHAIN+="[r7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=${MUTED}:fontsize=11:x=${RTEXT_INSET}:y=113[r8];"
  CHAIN+="[r8]drawbox=x=${RTEXT_INSET}:y=140:w=${PANEL_TEXT_W}:h=1:color=${LINE}@0.65:t=fill[r9];"

  CHAIN+="[r9]drawbox=x=${RTEXT_INSET}:y=160:w=7:h=7:color=${CHAMPAGNE}:t=fill[r10];"
  CHAIN+="[r10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_label.txt:fontcolor=${CHAMPAGNE}:fontsize=10:x=$((RTEXT_INSET+15)):y=156[r11];"
  CHAIN+="[r11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_title.txt:fontcolor=${WHITE}:fontsize=15:x=${RTEXT_INSET}:y=181[r12];"
  CHAIN+="[r12]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_sub.wrapped.txt:fontcolor=${MUTED}:fontsize=11:line_spacing=5:x=${RTEXT_INSET}:y=210[r13];"

  local rfact_label=270
  CHAIN+="[r13]drawbox=x=${RTEXT_INSET}:y=$((rfact_label-10)):w=${PANEL_TEXT_W}:h=1:color=${LINE}@0.65:t=fill[r14];"
  CHAIN+="[r14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${CHAMPAGNE}:fontsize=10:x=${RTEXT_INSET}:y=${rfact_label}[r15];"
  prev="r15"

  local fi fstart fend falpha
  for fi in "${!FACTS[@]}"; do
    idx=$((fi+1)); fstart=$((fi*FACT_SLOT)); fend=$((fstart+FACT_SLOT))
    falpha="if(between(mod(t\,${FACT_CYCLE})\,${fstart}\,${fend})\,if(lt(mod(t\,${FACT_CYCLE})-${fstart}\,0.7)\,(mod(t\,${FACT_CYCLE})-${fstart})/0.7\,if(gt(mod(t\,${FACT_CYCLE})-${fstart}\,${FACT_SLOT}-0.7)\,(${fend}-mod(t\,${FACT_CYCLE}))/0.7\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=${WHITE}@0.9:fontsize=14:line_spacing=6:x=${RTEXT_INSET}:y=300:alpha='${falpha}'[rf${idx}];"
    prev="rf${idx}"
  done

  CHAIN+="[${prev}]drawbox=x=${RTEXT_INSET}:y=390:w=${PANEL_TEXT_W}:h=1:color=${LINE}@0.65:t=fill[rr0];"
  CHAIN+="[rr0]drawtext=fontfile=${FONT}:text='LIVE READINGS':fontcolor=${CHAMPAGNE}:fontsize=10:x=${RTEXT_INSET}:y=407[rr1];"
  CHAIN+="[rr1]drawtext=fontfile=${FONT}:text='PHOTOSPHERE     5\,500 K':fontcolor=${WHITE}:fontsize=12:x=${RTEXT_INSET}:y=432[rr2];"
  CHAIN+="[rr2]drawtext=fontfile=${FONT}:text='CORONA          > 1 MK':fontcolor=${WHITE}:fontsize=12:x=${RTEXT_INSET}:y=454[rr3];"
  CHAIN+="[rr3]drawtext=fontfile=${FONT}:text='EUV FLUX':fontcolor=${MUTED}:fontsize=10:x=${RTEXT_INSET}:y=488[rr4];"
  prev="rr4"

  local RBAR_COUNT=18 RBAR_W=8 RBAR_GAP=5 ri rbx rh_expr ry_expr
  local rbase=590
  for ((ri=0; ri<RBAR_COUNT; ri++)); do
    rbx=$((RTEXT_INSET+ri*(RBAR_W+RBAR_GAP)))
    rh_expr="clip(24+24*sin(2*PI*t/4.9+${ri}*0.55)+11*sin(2*PI*t/2.1+${ri}*0.8)\,6\,75)"
    ry_expr="${rbase}-(${rh_expr})"
    CHAIN+="[${prev}]drawbox=x=${rbx}:y='${ry_expr}':w=${RBAR_W}:h='${rh_expr}':color=${CHAMPAGNE}@0.58:t=fill[rbar${ri}];"
    prev="rbar${ri}"
  done

  # CTA + ticker
  local CTA_W=470 CTA_X=$((CENTER_X0+(CENTER_W-470)/2)) CTA_Y=626
  local cta_enable="between(mod(t\,240)\,0\,8)"
  CHAIN+="[${prev}]drawbox=x=${CTA_X}:y=${CTA_Y}:w=${CTA_W}:h=42:color=${PANEL_BG_2}@0.94:t=fill[c1];"
  CHAIN+="[c1]drawbox=x=${CTA_X}:y=${CTA_Y}:w=3:h=42:color=${GOLD}:t=fill[c2];"
  CHAIN+="[c2]drawbox=x=$((CTA_X+19)):y=$((CTA_Y+16)):w=9:h=9:color=${RED}:t=fill:enable='${cta_enable}'[c3];"
  CHAIN+="[c3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=${WHITE}:fontsize=15:x=$((CTA_X+38)):y=$((CTA_Y+13)):enable='${cta_enable}'[c4];"

  if [[ "$duration" =~ ^[0-9]+$ ]] && [ "$duration" -gt 0 ]; then
    CHAIN+="[c4]drawtext=fontfile=${FONT}:text='NEXT VIEW IN %{eif\\:max(${duration}-t\,0)\\:d}s':fontcolor=${WHITE}:fontsize=14:x=$((CTA_X+38)):y=$((CTA_Y+13)):enable='not(${cta_enable})'[c5];"
  else
    CHAIN+="[c4]drawtext=fontfile=${FONT}:text='CONTINUOUS SOLAR OBSERVATION':fontcolor=${MUTED}:fontsize=13:x=$((CTA_X+38)):y=$((CTA_Y+13)):enable='not(${cta_enable})'[c5];"
  fi

  CHAIN+="[c5]drawbox=x=0:y=680:w=1280:h=40:color=${PANEL_BG_2}@0.98:t=fill[t1];"
  CHAIN+="[t1]drawbox=x=0:y=680:w=1280:h=1:color=${CHAMPAGNE}@0.72:t=fill[t2];"
  CHAIN+="[t2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=${WHITE}:fontsize=13:borderw=1:bordercolor=${PANEL_BG}:y=694:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[t3];"
  CHAIN+="[t3]drawbox=x=0:y=680:w=118:h=40:color=${PANEL_BG_3}:t=fill[t4];"
  CHAIN+="[t4]drawbox=x=17:y=695:w=7:h=7:color=${RED}:t=fill[t5];"
  CHAIN+="[t5]drawtext=fontfile=${FONT}:text='LIVE NOW':fontcolor=${WHITE}:fontsize=11:x=31:y=692[t6];"
  CHAIN+="[t6]drawtext=fontfile=${FONT}:text='SOLAR ACTIVITY WATCH':fontcolor=${WHITE}@0.25:fontsize=9:x='(w-text_w)/2':y=25[final]"

  printf '%s' "$CHAIN"
}

# ---------- Audio download ----------
AUDIO_LOCAL_FILES=()
if [ -n "$AUDIO_URL" ]; then
  IFS=',' read -ra AUDIOS <<< "$AUDIO_URL"
  ai=0
  for au in "${AUDIOS[@]}"; do
    au="${au#"${au%%[![:space:]]*}"}"
    au="${au%"${au##*[![:space:]]}"}"
    [ -z "$au" ] && continue
    ai=$((ai+1))
    dest="bg_audio_track_${ai}"
    if curl -sL --fail -o "$dest" "$au" && [ -s "$dest" ]; then
      AUDIO_LOCAL_FILES+=("$dest")
    fi
  done
fi
NUM_AUDIO=${#AUDIO_LOCAL_FILES[@]}
AUDIO_COUNTER=0

run_video() {
  local url="$1"
  prepare_content "$url"

  local duration=""
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || true)
  duration=${duration%.*}
  [[ "$duration" =~ ^[0-9]+$ ]] || duration=""

  local filter
  filter=$(build_filter "$duration")

  local audio_args=()
  local audio_map="2:a"
  if [ "$NUM_AUDIO" -gt 0 ]; then
    local afile="${AUDIO_LOCAL_FILES[$((AUDIO_COUNTER%NUM_AUDIO))]}"
    AUDIO_COUNTER=$((AUDIO_COUNTER+1))
    audio_args=(-stream_loop -1 -i "$afile")
  else
    audio_args=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
  fi

  local attempt=1
  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    echo "========================================"
    echo "PREMIUM SOLAR DOCUMENTARY STREAM"
    echo "Video: $url"
    echo "Attempt: $attempt/$MAX_RETRIES"
    echo "========================================"

    set +e
    ffmpeg -hide_banner -loglevel info \
      -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
      -re -i "$url" \
      "${audio_args[@]}" \
      -filter_complex "$filter" \
      -map "[final]" -map "$audio_map" \
      -r "$FPS" -s "${WIDTH}x${HEIGHT}" \
      -c:v libx264 -preset ultrafast -tune zerolatency \
      -threads 2 -profile:v high -level 4.1 -pix_fmt yuv420p \
      -b:v 3000k -maxrate 3000k -bufsize 6000k \
      -g 60 -keyint_min 60 -sc_threshold 0 \
      -c:a aac -b:a 128k -ar 48000 -ac 2 \
      -shortest -f flv \
      "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
    rc=$?
    set -e

    [ "$rc" -eq 0 ] && return 0
    echo "FFmpeg exited with code $rc"
    attempt=$((attempt+1))
    [ "$attempt" -le "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
  done

  return 1
}

# ---------- Parse video URLs ----------
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
  u="${u#"${u%%[![:space:]]*}"}"
  u="${u%"${u##*[![:space:]]}"}"
  [ -n "$u" ] && URLS+=("$u")
done

[ "${#URLS[@]}" -gt 0 ] || { echo "ERROR: VIDEO_URL has no valid entries"; exit 1; }

while true; do
  if [ "${#URLS[@]}" -gt 1 ]; then
    mapfile -t PLAYLIST < <(printf '%s\n' "${URLS[@]}" | shuf)
  else
    PLAYLIST=("${URLS[@]}")
  fi

  for url in "${PLAYLIST[@]}"; do
    run_video "$url" || true
  done
done
'''

path = outdir / "start_premium_solar.sh"
path.write_text(script)

readme = """PREMIUM SOLAR / SDO DOCUMENTARY STREAM
==========================================

This package refreshes the visual design of the solar livestream.

Kept:
- VIDEO_URL comma-separated playlist
- AUDIO_URL comma-separated background tracks
- YOUTUBE_STREAM_KEY
- Optional YouTube subscriber/viewer API stats
- 1280x720 / 30fps default
- automatic retries
- continuous playlist looping
- rotating headlines and science notes

New visual style:
- deep navy/graphite panels
- champagne-gold accents
- restrained red LIVE indicator
- cinematic documentary typography
- cleaner instrument/readings sections
- scientific activity graphs
- premium bottom ticker

Environment:
VIDEO_URL=url1,url2,url3
AUDIO_URL=url1,url2
YOUTUBE_STREAM_KEY=your_key

Optional:
YOUTUBE_API_KEY=...
YOUTUBE_CHANNEL_ID=...

Place font.ttf beside start_premium_solar.sh if using a custom font.

Run:
chmod +x start_premium_solar.sh
./start_premium_solar.sh
"""

(outdir / "README.txt").write_text(readme)

zip_path = Path("/mnt/data/premium_solar_documentary_stream.zip")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(path, "start_premium_solar.sh")
    z.write(outdir / "README.txt", "README.txt")

print(f"Created: {zip_path}")
print(f"Files: {len(zipfile.ZipFile(zip_path).namelist())}")
