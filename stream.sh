#!/bin/sh
URL="rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
SCALE="scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,format=yuv420p"

if [ -z "$YOUTUBE_STREAM_KEY" ]; then
  echo "ERREUR : YOUTUBE_STREAM_KEY manquante"; sleep 60; exit 1
fi

# Liste des fichiers diffusables (racine de /media, hors cover)
list_files() {
  find /media -maxdepth 1 -type f \
    \( -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.ogg' -o -iname '*.flac' \
       -o -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' \) | sort
}

# $1 = fichier, $2 = options de boucle ("-stream_loop -1" ou vide)
play() {
  f="$1"; LOOP="$2"
  case "$(echo "$f" | tr 'A-Z' 'a-z')" in
    *.mp3|*.m4a|*.aac|*.wav|*.ogg|*.flac)
      echo "▶ Audio : $f $LOOP"
      if [ -f /media/cover.jpg ]; then
        BG="-loop 1 -framerate 15 -i /media/cover.jpg"
      else
        BG="-f lavfi -i color=c=black:s=1280x720:r=15"
      fi
      ffmpeg -hide_banner -loglevel warning -re $BG $LOOP -i "$f" \
        -map 0:v -map 1:a -shortest -vf "$SCALE" \
        -c:v libx264 -preset veryfast -tune stillimage -r 15 -g 30 \
        -b:v 800k -maxrate 800k -bufsize 1600k \
        -c:a aac -b:a 128k -ar 44100 -f flv "$URL"
      ;;
    *)
      echo "▶ Vidéo : $f $LOOP"
      ffmpeg -hide_banner -loglevel warning -re $LOOP -i "$f" -vf "$SCALE" \
        -c:v libx264 -preset veryfast -r 30 -g 60 \
        -b:v 2500k -maxrate 2500k -bufsize 5000k \
        -c:a aac -b:a 128k -ar 44100 -f flv "$URL"
      ;;
  esac
}

while true; do
  FILES=$(list_files)
  COUNT=$(echo "$FILES" | grep -c . )

  if [ "$COUNT" -eq 0 ]; then
    echo "Aucun fichier dans /media, nouvelle vérification dans 30 s…"
    sleep 30
  elif [ "$COUNT" -eq 1 ]; then
    # Un seul fichier : boucle infinie SANS coupure.
    # On vérifie toutes les 10 min si d'autres fichiers ont été ajoutés.
    play "$FILES" "-stream_loop -1" &
    PID=$!
    while kill -0 $PID 2>/dev/null; do
      sleep 600
      [ "$(list_files | grep -c .)" -ne 1 ] && kill $PID && break
    done
    wait $PID 2>/dev/null
  else
    # Plusieurs fichiers : on les enchaîne dans l'ordre, en boucle.
    echo "$FILES" | while IFS= read -r f; do play "$f" ""; done
  fi
  sleep 2
done