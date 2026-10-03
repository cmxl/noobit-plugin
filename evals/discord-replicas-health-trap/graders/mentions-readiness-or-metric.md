---
type: regex
pattern: 'health/ready|readiness|metric'
flags: i
match: contains
target: last_message
---
