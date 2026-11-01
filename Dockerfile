FROM alpine:3.20
RUN apk add --no-cache ffmpeg
COPY stream.sh /stream.sh
RUN chmod +x /stream.sh
CMD ["/bin/sh", "/stream.sh"]