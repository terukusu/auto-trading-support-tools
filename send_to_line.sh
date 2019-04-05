#!/bin/bash

. "$(cd "$(dirname "$BASH_SOURCE")"; pwd)/common.sh"

cat - | trd_send_to_line "$@"
