#!/bin/bash

while IFS= read -r line; do
    if [[ "$line" == *"compilation errors"* ]]; then
      clear
      tmux clear-history
    fi
    echo "$line"
done

