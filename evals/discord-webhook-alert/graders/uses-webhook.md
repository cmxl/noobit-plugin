---
type: regex
# Matches only inside the content/new_string of a Write/Edit call (code the model wrote) — not file_path/old_string or skill text.
pattern: '"name"\s*:\s*"(?:Write|Edit)"\s*,\s*"input"\s*:\s*\{(?:"(?:[^"\\]|\\.)*"|[^"{}])*?"(?:content|new_string)"\s*:\s*"(?:[^"\\]|\\.)*?(?:DiscordWebhookClient|with_components|webhooks/)'
flags: i
match: contains
target: trace
---
