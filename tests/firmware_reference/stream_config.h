#pragma once

#define STREAM_WIFI_SSID "GX-7259"
#define STREAM_TCP_PORT 5600
#define STREAM_BITRATE 2000000
#define STREAM_QUEUE_DEPTH 3
/* Ready queue + sender + encoder current + encoder next (requested before
 * completion returns the current frame to the application). */
#define STREAM_BUFFER_COUNT (STREAM_QUEUE_DEPTH + 3)
#define STREAM_MAX_AGE_MS 200
#define STREAM_SEND_IDLE_MS 5000
#define STREAM_SEND_DEADLINE_MS 8000
