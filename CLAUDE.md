# CLAUDE.md

This file provides guidance for Claude Code when working on this SDK.

## Development Process

### 1. All Changes Require Tests

Every code change must include corresponding tests:
- New features need unit tests covering the main functionality
- Bug fixes need a test that reproduces the bug and verifies the fix
- API changes need tests for both the old behavior (if backwards compatible) and new behavior

### 2. PR Workflow

After creating a PR:
1. **Monitor CI** - Watch for failing tests in the PR checks
2. **Fix failures** - If tests fail, fix them before requesting review
3. **Verify locally** - Run the test suite locally before pushing fixes

### 3. Code Quality

- Follow existing code style and patterns in the codebase
- Keep changes focused - one feature/fix per PR
- Update documentation if adding new public APIs

### 4. Public API Changes

**DO NOT change public-facing APIs without explicit approval.**

If a change absolutely requires modifying a public API:
1. **STOP** and confirm with the user before proceeding
2. If approved, add a prominent warning in the PR description:

```
## ⚠️ BREAKING CHANGE ⚠️

This PR modifies public APIs:
- `oldMethod()` renamed to `newMethod()`
- `SomeClass` constructor signature changed

Migration required for existing users.
```

Public APIs include:
- Public method signatures (names, parameters, return types)
- Public class/struct names and their public properties
- Configuration options
- Event names and property keys sent to the server
