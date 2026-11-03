#!/bin/sh
URL="rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
DIR="${MEDIA_DIR:-/media}"
mkdir -p "$DIR"
chown 1000:1000 "$DIR"
SCALE="scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p"
LIST="/tmp/playlist.$$"

if [ -z "$YOUTUBE_STREAM_KEY" ]; then
  echo "ERREUR : YOUTUBE_STREAM_KEY manquante"; sleep 60; exit 1
fi

list_files() {
  find "$DIR" -maxdepth 3 -type f ! -iname 'cover.*' \
    \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.ogg' -o -iname '*.flac' \
       -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' \) | sort
}

# Paramètres communs : tous les segments ont le même format
VENC="-c:v libx264 -preset veryfast -profile:v high -level 4.1 -pix_fmt yuv420p -r 30 -g 60 -keyint_min 60 -sc_threshold 0"
AENC="-c:a aac -b:a 128k -ar 44100 -ac 2"

# ⚠ Tout ce qui est écrit sur stdout part dans le pipe → logs sur stderr (>&2)
play() {
  f="$1"
  case "$(echo "$f" | tr 'A-Z' 'a-z')" in
    *.mp3|*.m4a|*.aac|*.wav|*.ogg|*.flac)
      echo "▶ Audio : $f" >&2
      if [ -f "$DIR/cover.jpg" ]; then
        ffmpeg -nostdin -hide_banner -loglevel warning \
          -re -loop 1 -framerate 30 -i "$DIR/cover.jpg" -re -i "$f" \
          -map 0:v -map 1:a -shortest -vf "$SCALE" \
          $VENC -tune stillimage -b:v 800k -maxrate 800k -bufsize 1600k \
          $AENC -f mpegts -
      else
        ffmpeg -nostdin -hide_banner -loglevel warning \
          -re -f lavfi -i "color=c=black:s=1280x720:r=30" -re -i "$f" \
          -map 0:v -map 1:a -shortest -vf "$SCALE" \
          $VENC -tune stillimage -b:v 800k -maxrate 800k -bufsize 1600k \
          $AENC -f mpegts -
      fi
      ;;
    *)
      echo "▶ Vidéo : $f" >&2
      ffmpeg -nostdin -hide_banner -loglevel warning -re -i "$f" -vf "$SCALE" \
        $VENC -b:v 2500k -maxrate 2500k -bufsize 5000k \
        $AENC -f mpegts -
      ;;
  esac
}

# Écran noir + silence quand il n'y a aucun fichier (garde le live ouvert)
idle() {
  echo "Aucun fichier dans $DIR, écran noir 30 s…" >&2
  ffmpeg -nostdin -hide_banner -loglevel warning -re -t 30 \
    -f lavfi -i "color=c=black:s=1280x720:r=30" \
    -f lavfi -i "anullsrc=r=44100:cl=stereo" \
    $VENC -b:v 300k -maxrate 300k -bufsize 600k $AENC -f mpegts -
}

feeder() {
  FAILS=0
  while true; do
    list_files > "$LIST"
    if [ ! -s "$LIST" ]; then
      if idle; then FAILS=0; else FAILS=$((FAILS+1)); sleep 1; fi
      [ "$FAILS" -ge 3 ] && exit 1
    else
      while IFS= read -r f; do
        if play "$f"; then FAILS=0; else FAILS=$((FAILS+1)); sleep 1; fi
        # 3 échecs d'affilée = le pipe est cassé (RTMP tombé) → on sort
        # pour que la boucle principale relance la connexion
        [ "$FAILS" -ge 3 ] && exit 1
      done < "$LIST"
    fi
  done
}

# Une seule connexion RTMP, relancée uniquement si elle tombe
while true; do
  feeder | ffmpeg -hide_banner -loglevel warning -fflags +genpts -i pipe:0 \
    -c copy -flvflags no_duration_filesize -f flv "$URL"
  echo "Connexion RTMP interrompue, reprise dans 5 s…" >&2
  sleep 5
done