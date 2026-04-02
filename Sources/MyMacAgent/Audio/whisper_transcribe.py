#!/usr/bin/env python3
"""Transcribe audio file using mlx-whisper. Called by MyMacAgent as subprocess."""
import sys
import json
import mlx_whisper

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: whisper_transcribe.py <audio_file> [language]"}))
        sys.exit(1)

    audio_path = sys.argv[1]
    language = sys.argv[2] if len(sys.argv) > 2 else None

    try:
        result = mlx_whisper.transcribe(
            audio_path,
            path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
            language=language
        )

        output = {
            "text": result["text"],
            "language": result.get("language", ""),
            "segments": [
                {"start": s["start"], "end": s["end"], "text": s["text"]}
                for s in result.get("segments", [])
            ]
        }
        print(json.dumps(output, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

if __name__ == "__main__":
    main()
