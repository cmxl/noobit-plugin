#!/usr/bin/env bash
# Stages the broken bot into the empty run workspace (needs: claude plugin eval --scaffold).
set -euo pipefail
cp "$(dirname "$0")/inputs/DiscordBotService.cs" ./DiscordBotService.cs
