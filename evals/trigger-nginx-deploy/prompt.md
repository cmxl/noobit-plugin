---
name: trigger-nginx-deploy
description: Should trigger the nginx-deploy skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

I want to put nginx in front of my ASP.NET Core app in docker compose with HTTPS from Let's Encrypt. What are the key pieces of the setup? Bullet points only.
