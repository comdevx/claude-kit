---
name: youtube-transcribe
description: Download and transcribe a YouTube video — separates audio and video, converts to wav, and runs Whisper speech-to-text. Use this skill whenever the user pastes a YouTube URL and wants to transcribe, get subtitles, extract speech, or convert video audio to text. Triggers on phrases like "transcribe this", or any YouTube URL accompanied by transcription intent. Also use when the user wants to download YouTube audio/video separately.
---

# YouTube Transcribe

Accepts a YouTube URL and optional language code, then:
1. Downloads video (mp4) and audio (webm) separately via yt-dlp
2. Converts audio to 16kHz mono wav via ffmpeg
3. Transcribes with whisper-cli (medium model, GPU-accelerated on Apple Silicon)
4. Saves transcript with timestamps + plain text versions

## Usage

```
/youtube-transcribe <url> [language] [start] [end]
```

- `language` — ISO code: `th`, `en`, `ja`, `zh`, `ko`, etc. Omit to auto-detect.
- `start` — start time: `1:30`, `90`, `1:30:00` (optional)
- `end` — end time: `3:00`, `180` (optional, requires start)

**Examples:**
```
/youtube-transcribe https://www.youtube.com/watch?v=xxxx th
/youtube-transcribe https://youtu.be/xxxx en 1:30 3:00
/youtube-transcribe https://www.youtube.com/watch?v=xxxx th 5:00 10:30
/youtube-transcribe https://www.youtube.com/watch?v=xxxx -- 2:00 4:00
```

Use `--` as language placeholder if you want time range but auto-detect language.

## Prerequisites check

Before running, verify these tools are available. If any are missing, guide the user to install:

```bash
which yt-dlp   || echo "MISSING: brew install yt-dlp"
which ffmpeg   || echo "MISSING: brew install ffmpeg"
which whisper-cli || echo "MISSING: brew install whisper-cpp"
ls ~/.whisper-models/ggml-medium.bin 2>/dev/null || echo "MISSING MODEL: curl -L https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin -o ~/.whisper-models/ggml-medium.bin"
```

If the model is missing, tell the user it's ~1.5GB and ask before downloading.

## Step-by-step workflow

### 1. Get video info

```bash
yt-dlp --dump-json "<URL>" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('Title:', d.get('title'))
print('Channel:', d.get('channel'))
print('Duration:', d.get('duration'), 's')
print('Language:', d.get('language'))
"
```

Show the user: title, channel, duration.

### 2. Set output directory

Use a clean directory under `/tmp/yt-<video_id>/`:

```bash
VIDEO_ID=$(yt-dlp --get-id "<URL>")
OUT="/tmp/yt-${VIDEO_ID}"
mkdir -p "$OUT"
```

### 3. Download audio and video in parallel

If `start`/`end` were specified, pass `--download-sections` to yt-dlp to download only that range — much faster for long videos:

```bash
# With time range (e.g. start=1:30 end=3:00):
SECTION_FLAG="--download-sections *01:30-03:00"

# Without time range:
SECTION_FLAG=""

# Audio (background)
yt-dlp -o "$OUT/audio.%(ext)s" -f "bestaudio" --no-playlist $SECTION_FLAG "<URL>" &

# Video up to 720p (background)
yt-dlp -o "$OUT/video.%(ext)s" -f "bestvideo[height<=720]" --no-playlist $SECTION_FLAG "<URL>" &

wait
echo "Downloaded:"
ls -lh "$OUT"/
```

Time format for `--download-sections`: use `*HH:MM:SS-HH:MM:SS` or `*MM:SS-MM:SS`. Convert the user's input to this format before passing.

### 4. Convert audio to wav

If `start`/`end` were given, use ffmpeg `-ss`/`-to` to trim precisely (in case yt-dlp section boundaries aren't exact):

```bash
AUDIO_FILE=$(ls "$OUT"/audio.* | head -1)

# With time range:
ffmpeg -i "$AUDIO_FILE" -ss <start> -to <end> -ar 16000 -ac 1 -y "$OUT/audio.wav" 2>&1 | tail -2

# Without time range:
ffmpeg -i "$AUDIO_FILE" -ar 16000 -ac 1 -y "$OUT/audio.wav" 2>&1 | tail -2
```

### 5. Transcribe

```bash
LANG_FLAG=""
# If language was specified:
LANG_FLAG="--language <lang>"

whisper-cli \
  --model ~/.whisper-models/ggml-medium.bin \
  $LANG_FLAG \
  --output-txt \
  --output-srt \
  --output-file "$OUT/transcript" \
  "$OUT/audio.wav" 2>&1 | grep -E "^\[|total time|ERROR"
```

This produces:
- `transcript.txt` — plain text (no timestamps)
- `transcript.srt` — SubRip format with timestamps

### 6. Report results

Show the user:
- Video info summary (title, channel, duration)
- File paths: `$OUT/video.*`, `$OUT/audio.*`, `$OUT/transcript.txt`, `$OUT/transcript.srt`
- Whisper total time
- First 5 lines of transcript as a preview

```bash
echo "=== Transcript preview ==="
head -10 "$OUT/transcript.txt"
echo ""
echo "=== Files ==="
ls -lh "$OUT/"
```

## Notes

- The medium model (~1.5GB) handles Thai, Japanese, Chinese, Korean well. For English-only, `ggml-small.bin` is faster.
- On Apple M-series chips, whisper-cli uses Metal GPU automatically — typically 2-5× real-time speed.
- If `ggml-medium.bin` isn't present but `ggml-large.bin` is, use that instead.
- For very long videos (>1 hour), warn the user transcription may take 5-10 minutes.
- Video and audio are saved separately — user can use them independently.
