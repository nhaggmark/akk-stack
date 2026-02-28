import re

MAX_LENGTH = 450

# Terms that should never appear in NPC dialogue (case-insensitive)
ERA_BLOCKLIST = [
    r"\bPlane of Knowledge\b",
    r"\bPlanes of Power\b",
    r"\bberserker\b",
    r"\bDiscord\b",
    r"\bMuramite\b",
    r"\btechnology\b",
    r"\bdemocracy\b",
    r"\bmental health\b",
    r"\beconomy\b",
    r"\bscience\b",
    r"\bevolution\b",
    r"\banxiety\b",
    r"\bstress\b",
]

_blocklist_patterns = [re.compile(p, re.IGNORECASE) for p in ERA_BLOCKLIST]


def truncate_at_sentence(text: str, max_length: int = MAX_LENGTH) -> str:
    """Truncate text at the nearest sentence boundary before max_length."""
    if len(text) <= max_length:
        return text

    # Find the last sentence-ending punctuation before the limit
    truncated = text[:max_length]
    # Look for the last sentence boundary (.!?) followed by a space or end
    last_boundary = -1
    for match in re.finditer(r"[.!?](?:\s|$)", truncated):
        last_boundary = match.end()

    if last_boundary > 0:
        return truncated[:last_boundary].rstrip()

    # No sentence boundary found -- hard truncate at last space
    last_space = truncated.rfind(" ")
    if last_space > 0:
        return truncated[:last_space].rstrip() + "..."
    return truncated + "..."


def strip_quotes(text: str) -> str:
    """Remove wrapping quotes that LLMs sometimes add around responses."""
    stripped = text.strip()
    if len(stripped) >= 2:
        if (stripped[0] == '"' and stripped[-1] == '"') or (
            stripped[0] == "'" and stripped[-1] == "'"
        ):
            stripped = stripped[1:-1].strip()
    return stripped


def check_era_violations(text: str) -> list[str]:
    """Return list of era-violating terms found in the text."""
    violations = []
    for pattern in _blocklist_patterns:
        if pattern.search(text):
            violations.append(pattern.pattern)
    return violations


def filter_era_violations(text: str) -> str:
    """Remove sentences containing era-violating terms."""
    violations = check_era_violations(text)
    if not violations:
        return text

    # Split into sentences and remove offending ones
    sentences = re.split(r"(?<=[.!?])\s+", text)
    clean_sentences = []
    for sentence in sentences:
        has_violation = False
        for pattern in _blocklist_patterns:
            if pattern.search(sentence):
                has_violation = True
                break
        if not has_violation:
            clean_sentences.append(sentence)

    if not clean_sentences:
        return ""

    return " ".join(clean_sentences)


def strip_character_prefix(text: str) -> str:
    """Remove character name prefix if model echoes it (e.g., 'Guard Mizraen: ...')."""
    # Match patterns like "Name:" or '"Name:' at the start
    stripped = re.sub(r'^["\s]*[\w\s]+:\s*', '', text, count=1)
    # Only use stripped version if it didn't eat the whole response
    if len(stripped) > 10:
        return stripped
    return text


def process_response(text: str) -> str:
    """Full post-processing pipeline for LLM responses."""
    if not text:
        return ""

    text = strip_quotes(text)
    text = strip_character_prefix(text)
    text = filter_era_violations(text)
    if not text:
        return ""
    text = truncate_at_sentence(text)
    return text.strip()
