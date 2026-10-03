# Agent Guidelines

## Commits

- Commit after every modification: one change, one commit (每做一次修改就要做一次 commit). Do not batch unrelated edits into a single commit, and do not leave the working tree dirty at the end of a task.

## Verification before delivery

- Only hand work to the user with sufficient evidence that it actually works, and only after testing is done (必须有足够的证据并且做完测试后,才能提交给用户). "Build succeeded" is not evidence of behaviour: verify the changed behaviour itself — run the app, check logs or probes, reproduce the user-visible outcome — and say plainly what was and was not verified. If something cannot be verified in this environment, state that explicitly instead of implying it works.
