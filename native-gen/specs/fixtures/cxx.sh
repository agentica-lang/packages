#!/bin/sh
# A CC that builds a native module as C++: the words agentica gives the C compiler, with -std=c11 swapped for C++11.
for word; do
  shift
  case $word in
    -std=c11) set -- "$@" -std=c++11 ;;
    *) set -- "$@" "$word" ;;
  esac
done
exec c++ -x c++ -Wall -Wextra -Werror "$@"
