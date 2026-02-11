---
name: weather
description: Get current weather and forecasts (no API key required).
metadata: {"openclaw": {"requires": {"bins": ["curl"]}}}
---
# Weather Skill
Use `curl wttr.in/CityName` to get weather forecasts.
## Usage
- Current weather: `curl wttr.in/Beijing`
- 3-day forecast: `curl wttr.in/Beijing?format=v2`
- One-line: `curl wttr.in/Beijing?format="%l:+%c+%t+%w"`
