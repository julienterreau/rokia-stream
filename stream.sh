#!/bin/sh
# Diffusion continue (sans coupure entre les fichiers) d'une playlist vers YouTube Live.
# 1) Chaque fichier uploadé est converti UNE fois dans un format identique (cache).
# 2) Une seule connexion ffmpeg diffuse la playlist en boucle, sans réencodage (-c copy).

URL="${STREAM_URL:-rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}}"
DIR="${MEDIA_DIR:-/media}"
NAME="$(basename "$DIR")"
CACHE="${CACHE_ROOT:-/cache}/$NAME"
LIST="$CACHE/playlist.txt"
SRC="$CACHE/sources.txt"

# Qualité : 720 (défaut) ou 1080
HEIGHT="${VIDEO_HEIGHT:-720}"
if [ "$HEIGHT" = "1080" ]; then W=1920; H=1080; VB=4500k; VBUF=9000k; LVL=4.1
else W=1280; H=720; VB=2500k; VBUF=5000k; LVL=4.0; fi

VF="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2,fps=30,format=yuv420p,setsar=1"
ENC="-c:v libx264 -preset veryfast -profile:v high -level $LVL -pix_fmt yuv420p -r 30 -g 60 -keyint_min 60 -sc_threshold 0 -b:v $VB -maxrate $VB -bufsize $VBUF -x264-params repeat-headers=1 -c:a aac -b:a 160k -ar 44100 -ac 2 -video_track_timescale 90000 -movflags +faststart"
MIN_LOOP=21600   # la playlist est répétée pour durer au moins 6 h par connexion

mkdir -p "$DIR" "$CACHE"
chown 1000:1000 "$DIR" 2>/dev/null

if [ -z "$YOUTUBE_STREAM_KEY" ] && [ -z "$STREAM_URL" ]; then
  echo "ERREUR : YOUTUBE_STREAM_KEY manquante"; sleep 60; exit 1
fi

# Fichiers diffusables (uploads terminés depuis plus d'1 min), hors cover
list_sources() {
  find "$DIR" -maxdepth 3 -type f -mmin +1 ! -iname 'cover.*' \
    \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.ogg' -o -iname '*.flac' \
       -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' \) | sort
}

fingerprint() {
  { list_sources | while IFS= read -r f; do stat -c '%n|%s|%Y' "$f"; done
    [ -f "$DIR/cover.jpg" ] && stat -c '%n|%s|%Y' "$DIR/cover.jpg"
    echo "$HEIGHT"
  } | md5sum | cut -c1-32
}

is_audio() {
  case "$(echo "$1" | tr 'A-Z' 'a-z')" in
    *.mp3|*.m4a|*.aac|*.wav|*.ogg|*.flac) return 0 ;;
  esac
  return 1
}

cache_file() {
  key="$(stat -c '%n|%s|%Y' "$1")|$HEIGHT"
  if is_audio "$1" && [ -f "$DIR/cover.jpg" ]; then
    key="$key|$(stat -c '%s|%Y' "$DIR/cover.jpg")"
  fi
  echo "$CACHE/$(echo "$key" | md5sum | cut -c1-16).mp4"
}

convert() {
  f="$1"; out="$2"; tmp="$CACHE/tmp-$$.mp4"
  if is_audio "$f"; then
    if [ -f "$DIR/cover.jpg" ]; then BG="-loop 1 -framerate 30 -i $DIR/cover.jpg"
    else BG="-f lavfi -i color=c=black:s=${W}x${H}:r=30"; fi
    ffmpeg -nostdin -y -hide_banner -loglevel error $BG -i "$f" \
      -map 0:v -map 1:a -shortest -vf "$VF" $ENC "$tmp" < /dev/null
  elif [ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" < /dev/null)" ]; then
    ffmpeg -nostdin -y -hide_banner -loglevel error -i "$f" \
      -map 0:v:0 -map 0:a:0 -vf "$VF" -af apad -shortest $ENC "$tmp" < /dev/null
  else
    ffmpeg -nostdin -y -hide_banner -loglevel error -i "$f" -f lavfi -i anullsrc=r=44100:cl=stereo \
      -map 0:v:0 -map 1:a -shortest -vf "$VF" $ENC "$tmp" < /dev/null
  fi
  if [ $? -eq 0 ] && [ -s "$tmp" ]; then mv "$tmp" "$out"; return 0; fi
  rm -f "$tmp"; return 1
}

duration() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" < /dev/null
}

prepare() {
  list_sources > "$SRC"
  : > "$LIST.items"
  TOTAL=0
  while IFS= read -r f <&3; do
    out="$(cache_file "$f")"
    if [ ! -f "$out" ]; then
      echo "⚙ Conversion : $f"
      if ! convert "$f" "$out"; then echo "✖ Échec de conversion (ignoré) : $f"; continue; fi
    fi
    echo "file '$out'" >> "$LIST.items"
    d="$(duration "$out")"
    TOTAL="$(awk -v a="$TOTAL" -v b="${d:-0}" 'BEGIN{print a+b}')"
  done 3< "$SRC"

  # Supprime du cache les fichiers qui ne sont plus dans la playlist
  for c in "$CACHE"/*.mp4; do
    [ -f "$c" ] || continue
    grep -qF "$c" "$LIST.items" || rm -f "$c"
  done

  COUNT="$(grep -c . "$LIST.items")"
  if [ "$COUNT" -eq 0 ]; then : > "$LIST"; return; fi
  REPS="$(awk -v t="$TOTAL" -v m="$MIN_LOOP" 'BEGIN{ if (t<1) t=1; r=int(m/t)+1; if (r>5000) r=5000; print r }')"
  : > "$LIST.new"; i=0
  while [ "$i" -lt "$REPS" ]; do cat "$LIST.items" >> "$LIST.new"; i=$((i+1)); done
  mv "$LIST.new" "$LIST"
  echo "✔ Playlist prête : $COUNT fichier(s), $(awk -v t="$TOTAL" 'BEGIN{printf "%d", t/60}') min, ${H}p"
}

PID=""
running() { [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; }
stop_stream() {
  if running; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi
  PID=""
}
start_stream() {
  echo "▶ Diffusion continue ($NAME)"
  ffmpeg -nostdin -hide_banner -loglevel warning -re -f concat -safe 0 -i "$LIST" \
    -c copy -f flv "$URL" < /dev/null &
  PID=$!
}

LAST=""
while true; do
  FP="$(fingerprint)"
  if [ "$FP" != "$LAST" ]; then
    echo "↻ Changement détecté dans $DIR, préparation…"
    prepare
    LAST="$FP"
    stop_stream
  fi
  if ! running; then
    if [ -s "$LIST" ]; then start_stream; else echo "Aucun fichier prêt dans $DIR (attente)…"; fi
  fi
  sleep "${CHECK_EVERY:-30}"
done