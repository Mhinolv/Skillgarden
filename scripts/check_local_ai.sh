#!/bin/zsh
# The release acceptance check of local AI on this Mac (#130). See docs/local-ai.md.
# Usage: scripts/check_local_ai.sh --model <file.gguf> [--runtime <Skillgarden.app>] [--out <folder>]
# It builds the SkillgardenAICheck tool, then runs it with the bundled runtime and the fixtures in Tests/Fixtures.
# Stdout: one PASS or FAIL line for each check, then a RESULT line. Stderr: the build log and the progress.
# Exit 0: all checks pass. Exit 1: a check failed. Exit 2: a setup error.
# The script uses no network and never downloads a model.
set -uo pipefail
ROOT=${0:A:h:h}
USAGE="usage: scripts/check_local_ai.sh --model <file.gguf> [--runtime <Skillgarden.app>] [--out <folder>]"
MODEL=""
RUNTIME=$ROOT/build/Skillgarden.app
OUT=$ROOT/build/local-ai-check

while (( $# )); do
  case $1 in
    -h|--help) print -r -- "$USAGE"; exit 0 ;;
    --model|--runtime|--out)
      if (( $# < 2 )) || [[ -z $2 ]]; then print -r -- "error: $1 needs a value" >&2; exit 2; fi
      case $1 in
        --model) MODEL=$2 ;;
        --runtime) RUNTIME=$2 ;;
        --out) OUT=$2 ;;
      esac
      shift 2 ;;
    *) print -r -- "error: unknown option $1" >&2; print -r -- "$USAGE" >&2; exit 2 ;;
  esac
done
[[ -n $MODEL ]] || { print -r -- "error: --model is required" >&2; print -r -- "$USAGE" >&2; exit 2 }

# The build log goes to stderr, so that stdout has only the results.
"$ROOT/scripts/build.sh" --product SkillgardenAICheck >&2 || { print -r -- "error: the check tool did not build" >&2; exit 2 }
BIN=$("$ROOT/scripts/build.sh" --show-bin-path 2>/dev/null)/SkillgardenAICheck
[[ -x $BIN ]] || { print -r -- "error: the check tool is not at $BIN" >&2; exit 2 }

exec "$BIN" --model "${MODEL:a}" --runtime "${RUNTIME:a}" --out "${OUT:a}" --fixtures "$ROOT/Tests/Fixtures"
