#!/bin/bash

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

cat - | atst_send_to_line "$@"
