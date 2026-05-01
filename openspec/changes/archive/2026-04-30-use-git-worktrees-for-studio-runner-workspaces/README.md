# Use Git worktrees for Studio Runner workspaces

This change specifies how Symphony should prepare Studio Runner execution workspaces without creating infinite full repository copies.

The core model is: fetch the canonical local repository, create an isolated Git worktree from the remote default branch, run the agent inside that worktree, publish a PR, then clean up worktrees according to PR/run lifecycle.
