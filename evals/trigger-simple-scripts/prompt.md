---
name: trigger-simple-scripts
description: Should trigger the simple-scripts skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Give me a quick az CLI script that sets these three app settings on our Azure web app 'shop-api' in resource group 'rg-shop': FeatureX=true, CacheMinutes=5, Region=westeurope.
