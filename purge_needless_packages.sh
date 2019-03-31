#!/bin/bash

read -p "This scrpit will purge apache2 bind9 postfix rpcbind samba and related packages. realy do it? (y/n)" YN_LOADSETTING

if [ "${YN_LOADSETTING}" != "y" ]; then
  echo "canceled."
  exit 0
fi

for p in apache2 bind9 postfix rpcbind samba php mysql postgresql; do
  sudo apt purge -y $(dpkg -l | grep $p | tr -s ' ' | cut -d' ' -f2)
done
