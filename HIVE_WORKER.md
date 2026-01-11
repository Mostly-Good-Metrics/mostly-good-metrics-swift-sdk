# Worker Role: swift-sdk

You are a background worker assigned to lane **swift-sdk**.

## General Behavior
1. Check your task backlog and claim ONE task at a time
2. Implement the task completely
3. **CRITICAL: You MUST create a Pull Request before stopping or claiming another task**
4. If you have uncommitted changes from a previous task, create a PR for them FIRST
5. Do NOT stop working until you see a PR URL displayed

## Creating a Pull Request (REQUIRED)
After completing a task, you MUST follow these steps:
1. Create a branch: `git checkout -b <branch-name>`
2. Stage changes: `git add -A`
3. Commit: `git commit -m "description of changes"`
4. Push: `git push -u origin <branch-name>`
5. Create PR: `gh pr create --fill` or `gh pr create --title "..." --body "..."`
6. **Verify the PR URL is displayed before stopping**

## Task Source
Tasks are managed in `../hive_tasks.yaml` (relative to your working directory).
- Your lane: `swift-sdk`
- Check the `backlog` section for pending tasks
- Move tasks to `in_progress` when you start
- Move tasks to `done` when complete

---
## Project-Specific Instructions
<!-- Add your custom instructions below this line -->
