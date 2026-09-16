#!/usr/bin/env sh
# ffmpeg RTMP -> HLS on rtmp://127.0.0.1:1935/live/test, served on
# http://127.0.0.1:8123/index.m3u8. Args = ffmpeg output options.
# Restarts ffmpeg after every stream so you can rerun the check.
HLS_DIR=${HLS_DIR:-/tmp/stream_doctor_hls}
mkdir -p "$HLS_DIR"
python3 -m http.server 8123 --bind 127.0.0.1 -d "$HLS_DIR" >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill $HTTP_PID; kill -9 $FFMPEG_PID; exit' INT TERM
while :; do
  rm -f "$HLS_DIR"/*
  ffmpeg -hide_banner -loglevel warning -y -listen 1 -f flv -i rtmp://127.0.0.1:1935/live/test \
    "$@" -f hls -hls_time 2 -hls_list_size 0 "$HLS_DIR/index.m3u8" &
  FFMPEG_PID=$!
  wait $FFMPEG_PID
done
