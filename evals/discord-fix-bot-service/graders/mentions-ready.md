---
type: regex
pattern: '(subscri\w*|\+=|handlers?|events?)[^\n]{0,80}\bReady\b|\bReady\b[^\n]{0,100}(subscri\w*|handlers?|reconnect\w*|every time|each time|again|fires)'
flags: i
match: contains
---
