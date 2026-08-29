# Get the list of commit hashes in reverse order (oldest to newest)
for commit in $(git log origin/codex/database-split..codex/database-split --format="%H" --reverse); do
    echo "Pushing commit: $commit"
    # Push that specific commit hash to the remote branch
    git push origin $commit:refs/heads/codex/database-split
done