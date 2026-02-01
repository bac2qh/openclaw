#!/usr/bin/env python3
"""Speaker diarization using pyannote.

This script uses pyannote.audio to identify who spoke when in an audio file.
Requires a Hugging Face token with access to pyannote models.

Usage:
    diarize.py <audio_file> [output_file]

Environment:
    HF_TOKEN: Hugging Face API token (required)

Example:
    HF_TOKEN=hf_xxx python diarize.py meeting.wav speakers.txt
"""
import os
import sys

from pyannote.audio import Pipeline


def diarize(audio_path: str, output_path: str | None = None) -> str:
    """
    Perform speaker diarization on an audio file.

    Args:
        audio_path: Path to audio file (WAV, MP3, M4A, etc.)
        output_path: Optional path to save diarization results

    Returns:
        Formatted diarization results as a string
    """
    hf_token = os.environ.get("HF_TOKEN")
    if not hf_token:
        raise ValueError(
            "HF_TOKEN environment variable required. "
            "Get token from https://huggingface.co/settings/tokens"
        )

    # Load pretrained pipeline
    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1", use_auth_token=hf_token
    )

    # Run diarization
    diarization = pipeline(audio_path)

    # Format results
    results = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        start = turn.start
        end = turn.end
        results.append(f"[{start:.1f}s - {end:.1f}s] {speaker}")

    output = "\n".join(results)

    # Save to file if requested
    if output_path:
        with open(output_path, "w") as f:
            f.write(output)

    return output


def main() -> None:
    """CLI entry point."""
    if len(sys.argv) < 2:
        print("Usage: diarize.py <audio_file> [output_file]", file=sys.stderr)
        sys.exit(1)

    audio_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.exists(audio_file):
        print(f"Error: Audio file not found: {audio_file}", file=sys.stderr)
        sys.exit(1)

    try:
        result = diarize(audio_file, output_file)
        if not output_file:
            print(result)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
