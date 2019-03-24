#!/bin/bash

. "$(cd "$(dirname $0)" && pwd)/common.sh"

cat - | trd_send_to_line
