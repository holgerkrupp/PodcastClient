STORE="$HOME/Library/Group Containers/group.de.holgerkrupp.PodcastClient"
BACKUP="$HOME/Desktop/UpNext-Database-Backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP"

for file in "$STORE"/SharedDatabase.sqlite*; do
  [[ -e "$file" ]] && mv "$file" "$BACKUP/"
done