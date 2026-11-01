#!/bin/sh
# Diffuse en boucle tous les fichiers de /media vers YouTube Live.
# Audio (mp3, m4a, wav…) : affiché avec l'image /media/cover.jpg (ou fond noir).
# Vidéo (mp4, mkv, mov…) : diffusée telle quelle (réencodée en 720p).

URL="rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
SCALE="scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p"

if [ -z "$YOUTUBE_STREAM_KEY" ]; then
  echo "ERREUR : YOUTUBE_STREAM_KEY manquante"; sleep 60; exit 1
fi

while true; do
  found=0
  for f in /media/*; do
    [ -f "$f" ] || continue
    name=$(basename "$f" | tr 'A-Z' 'a-z')
    case "$name" in
      cover.jpg|cover.png) continue ;;

      *.mp3|*.m4a|*.aac|*.wav|*.ogg|*.flac)
        found=1
        echo "▶ Audio : $f"
        if [ -f /media/cover.jpg ]; then
          BG="-loop 1 -framerate 15 -i /media/cover.jpg"
        else
          BG="-f lavfi -i color=c=black:s=1280x720:r=15"
        fi
        ffmpeg -hide_banner -loglevel warning -re $BG -i "$f" \
          -map 0:v -map 1:a -shortest -vf "$SCALE" \
          -c:v libx264 -preset veryfast -tune stillimage -r 15 -g 30 \
          -b:v 800k -maxrate 800k -bufsize 1600k \
          -c:a aac -b:a 128k -ar 44100 -f flv "$URL"
        ;;

      *.mp4|*.mkv|*.mov|*.webm)
        found=1
        echo "▶ Vidéo : $f"
        ffmpeg -hide_banner -loglevel warning -re -i "$f" -vf "$SCALE" \
          -c:v libx264 -preset veryfast -r 30 -g 60 \
          -b:v 2500k -maxrate 2500k -bufsize 5000k \
          -c:a aac -b:a 128k -ar 44100 -f flv "$URL"
        ;;
    esac
  done
  if [ "$found" = 0 ]; then
    echo "Aucun fichier dans /media, nouvelle vérification dans 30 s…"
    sleep 30
  fi
done