---
type: regex
pattern: '(server|backend|endpoint|api)[^.\n]{0,80}(calculat|comput|look\w* up|load|determin|deriv|recalculat|reads? the (price|total)|(own|authoritative) (price|amount|total))|(calculat|comput|recalculat|determin|deriv|look\w* up|load)\w*[^.\n]{0,80}(on the server|server[- ]side|from (your|the|its) (own )?(database|db|catalog|snapshot|checkout|cart|basket))|(never|don.?t|do not|must not) (trust|send|accept|forward|use)[^.\n]{0,40}(client|browser|frontend|its|the)?[^.\n]{0,20}(amount|price|total)|ignore[^.\n]{0,40}(amount|price|total)'
flags: i
match: contains
---
