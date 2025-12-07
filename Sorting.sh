#!/bin/bash

defaultPath="./"
path="${$1: -$defaultPath}"

echo "D: $path"
echo "0: $1"

# files=$(ls $path)

# echo $files

# for file in $files; do
#     if [ -d "$path/$file" ]; then

#         echo "$path/$file is a directory."
    
#     elif [ -f "$path/$file" ]; then
#         echo "$path/$file is a file."
    
#         if [[ $path/$file == *.sh ]]; then
    
#             mkdir -p "$path/Scripts/"
#             mv "$path/$file" "$path/Scripts/"
#             echo "$path/$file is a shell script."
    
#         elif [[ $path/$file == *.txt ]] || [[ $path/$file == *.md ]]; then
    
#             mkdir -p "$path/Documents/"
#             mv "$path/$file" "$path/Documents/"
#             echo "$path/$file is a text file."
    
#         elif [[ $path/$file == *.jpg ]] || [[ $path/$file == *.png ]]; then
    
#             mkdir -p "$path/Images/"
#             mv "$path/$file" "$path/Images/"
#             echo "$path/$file is an image file."
    
#         else
    
#             echo "$path/$file is of an unknown file type."
    
#         fi
    
#     else
    
#         echo "$path/$file is neither a file nor a directory."
    
#     fi

# done
