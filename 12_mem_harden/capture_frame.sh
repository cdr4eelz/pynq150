#!/bin/sh
# capture_frame.sh out.png [frame_no]   grab one 800x600 YUYV frame from /dev/video2.
# The UVC dongle (345f:2130) outputs black for a variable time after it is
# opened (60..300+ frames seen), so by default take frame 360 (~6 s).
N=${2:-360}
ffmpeg -hide_banner -loglevel error -y -f v4l2 -input_format yuyv422 -video_size 800x600 \
  -framerate 60 -i /dev/video2 -vf "select=eq(n\,$N)" -vsync 0 -frames:v 1 "$1" && echo "saved $(realpath "$1")"
