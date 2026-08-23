#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWLEDGE_CLI="$REPOSITORY_ROOT/scripts/ai-knowledge/kb.py"

cd "$REPOSITORY_ROOT"

PYTHONDONTWRITEBYTECODE=1 python3 "$KNOWLEDGE_CLI" validate
PYTHONDONTWRITEBYTECODE=1 python3 "$KNOWLEDGE_CLI" audit
PYTHONDONTWRITEBYTECODE=1 python3 "$KNOWLEDGE_CLI" eval
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/ai-knowledge/tests -p 'test_*.py'
