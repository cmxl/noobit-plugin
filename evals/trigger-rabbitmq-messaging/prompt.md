---
name: trigger-rabbitmq-messaging
description: Should trigger the rabbitmq-messaging skill on a realistic request
tags: [trigger]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

When an order is placed in our order service, the shipping service needs to know about it. How should service A tell service B reliably, without losing messages if the DB commit succeeds but publishing fails? Brief design.
