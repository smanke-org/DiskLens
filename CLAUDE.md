# DiskLens

Drive the app with `disklens` (the app binary; `disklens help`). See `.claude/skills/disklens/SKILL.md`. Commands live in
`Sources/DiskLens/Agent/AgentCommands.swift`; test them on a Debug build (`swift build`) with `APP_STORE=/tmp/<name>`, which
starts a test copy on its own saved scans and settings, with no window (Release builds ignore it).
