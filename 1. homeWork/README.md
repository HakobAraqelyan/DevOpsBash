Classwork 1

Task 1: Greeting Script
Goal: Write a script that
asks for the user's name
checks if the name is empty
prints a greeting
Requirements:
use read
use if/else
use -z to check emptiness
exit with status 1 if no name
you can use argument instead of read command!

Task 2: File Organizer Script
Goal:
 Write a script that:
creates folders: images, docs, scripts
loops through files in current directory
moves files based on extension:
.jpg .png → images
.txt .md → docs
.sh → scripts
prints what it moved
Requirements:
use mkdir -p
use for file in *
use case

Task 3: Disk Usage Warning
Goal:
 Write a script that:
checks disk usage with df -h /
extracts the % number
if > 80%, print WARNING
else print OK
Requirements:
use command substitution $( )
use cut, awk, or grep
use if