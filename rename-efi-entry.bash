#!/bin/bash
#=======================================================================================================================
# Script to rename EFI boot entries
#
# This script renames an existing EFI boot entry by deleting it and re-creating with a required label.
# See https://bbs.archlinux.org/viewtopic.php?pid=1215494#p1215494 .
# See https://bbs.archlinux.org/viewtopic.php?pid=1083424#p1083424 .
# See https://www.linuxbabe.com/command-line/how-to-use-linux-efibootmgr-examples .
#
# Usage:
#     sudo ./rename-efi-entry.bash existing_efi_label new_efi_label [bootnum]
# Example:
#     sudo ./rename-efi-entry.bash ubuntu 'ubuntu 18.04'
#   or:
#     sudo ./rename-efi-entry.bash ubuntu 'ubuntu 18.04' 0001
#   or:
#     sudo ./rename-efi-entry.bash '*' 'ubuntu 18.04' 0001
#
# Author:  Sergey Ushakov <s-n-ushakov@yandex.ru> : https://github.com/s-n-ushakov
# Started: 2019-10-31
# Contributors:
#   - Craig Francis                               : https://github.com/craigfrancis : partition table regex refinement
#   - Jeric de Leon                               : https://github.com/jericdeleon  : NVMe and MMC support
#=======================================================================================================================

# function to print usage
print_usage () {
  echo Usage:
  echo "  sudo $0 existing_efi_label new_efi_label [bootnum]"
  echo Example:
  echo "  sudo $0 ubuntu 'ubuntu 18.04'"
  echo Example:
  echo "  sudo $0 ubuntu 'ubuntu 18.04' 0001"
  echo Example:
  echo "  sudo $0 '*' 'ubuntu 18.04' 0001"
}

# function to print usage and EFI data
print_usage_and_efi_data () {
  print_usage
  echo
  echo Current EFI data:
  efibootmgr --verbose
}

# function to print debug messages if test_mode is enabled
# usage: debug "your message here"
debug() {
  if [[ $test_mode -eq 1 ]]; then
    echo "DEBUG: $*" >&2
  fi
}

# The reason we are doing is because it seems that efibootmgr output differ slightly across different distros.
# Arch and Fedora do not have the `File` prefix in the loader path, while Ubuntu and Mint does.

# standard efibootmgr (most common): ends with loader path
REGEX_LOADER='^Boot([[:xdigit:]]{4})\*?[[:blank:]]+(.+)[[:blank:]]+HD\(([[:digit:]]+),[^,]+,([^,]+)[^\)]+\)\/(.+)$'

# alternative format: loader path wrapped in File(...)
REGEX_LOADER_FILE='^Boot([[:xdigit:]]{4})\*?[[:blank:]]+(.+)[[:blank:]]+HD\(([[:digit:]]+),[^,]+,([^,]+)[^\)]+\)\/File\(([^\)]+)\)$'

# sfdisk format for extracting device and partition uuid
# e.g. /dev/sda1 : start=..., size=..., ..., uuid=2FFCC127-F6CE-40F0-9932-D1DFD14E9462
REGEX_SFDISK_UUID='^([^[:blank:]]+)[[:blank:]]:[[:blank:]].*[[:blank:]]uuid=([^,]+)'

REGEX_UUID='^(/dev/(sd[a-z]|nvme[[:digit:]]+n[[:digit:]]+|mmcblk[[:digit:]]+))p?([[:digit:]]+)$'
# ----------------------------------------------------------------------------------------------------------------------

# script start ---------------------------------------------------------------------------------------------------------

# check whether we run as root
if [[ $EUID -ne 0 ]]; then
  echo "$0 : ERROR : this script must be run as root"
  print_usage_and_efi_data
  exit 1
fi

# check command line arguments
if [ -z "$2" ] ; then
  if [ -z "$1" ] ; then
    echo "$0 : ERROR : no existing EFI label specified to be renamed"
    print_usage_and_efi_data
    exit 1
  else
    echo "$0 : ERROR : no new EFI label specified"
    print_usage
    exit 1
  fi
fi
old_label="$1"
new_label="$2"
old_bootnum="$3"

# default: execute normally
test_mode=0

# parse remaining arguments for optional flags
for arg in "$@"; do
  if [[ "$arg" == "--test" ]]; then
    test_mode=1
  fi
done

if [[ $test_mode -eq 1 ]]; then
  echo "$0 : INFO : test mode enabled; no commands will be executed, only verification and dry run"
fi


# obtain disk device names as `disk_names` array -----------------------------------------------------------------------

# obtain disk data as long text
disk_data_all=$(lsblk --nodeps --noheadings --pairs | grep 'TYPE="disk"')

# split disk data into a string array
debug "Finding disk devices..."
readarray -t disk_data_array <<<"$disk_data_all"

# obtain an array of disk names
disk_names=()
for disk_data_line in "${disk_data_array[@]}" ; do
  if [[ $disk_data_line =~ ^NAME=\"([^\"]+)\" ]] ; then
    disk_names+=(${BASH_REMATCH[1]})
    debug "Found disk: ${BASH_REMATCH[1]}"
  fi
done
# ----------------------------------------------------------------------------------------------------------------------

# obtain an associative array of devices against partition uuid values -------------------------------------------------
debug "Mapping partition UUIDs to device names..."

# the associative array to be filled
# data example : partitions['2ffcc127-f6ce-40f0-9932-d1dfd14e9462']='/dev/sda1'
declare -A partitions

# loop over all disk devices
for disk_name in "${disk_names[@]}" ; do
  debug "Scanning disk /dev/$disk_name for partitions..."
  # obtain partition data as long text, suppressing possible error messages in stderr,
  #   e.g. "sfdisk: /dev/sdb: does not contain a recognized partition table"
  # NOTE sfdisk call requires `sudo`
  partition_data_all=$(sfdisk -d /dev/$disk_name 2>/dev/null | grep ': start=')

  # split partition data into a string array
  readarray -t partition_data_array <<<"$partition_data_all"

  # parse partition data and add to the result array
  # raw data examples:
  # - Ubuntu 18.04
  #   /dev/sda1 : start=        2048, size=     1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=2FFCC127-F6CE-40F0-9932-D1DFD14E9462, name="EFI System Partition"
  #   /dev/sda1 : start=        2048, size=     1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=2FFCC127-F6CE-40F0-9932-D1DFD14E9462
  for partition_data_line in "${partition_data_array[@]}" ; do
    if [[ $partition_data_line =~ $REGEX_SFDISK_UUID ]] ; then
      device=${BASH_REMATCH[1]}
      uuid_lowercase="${BASH_REMATCH[2],,}"
      partitions[$uuid_lowercase]=$device
      debug "Mapped UUID $uuid_lowercase to $device"

    fi
  done
done
if [ ${#partitions[@]} -eq 0 ]; then
    echo "$0 : WARNING : Could not find any partitions with UUIDs via sfdisk."
fi
# ----------------------------------------------------------------------------------------------------------------------

# obtain EFI data ------------------------------------------------------------------------------------------------------
debug "Scanning EFI boot entries..."

# obtain EFI data as long text
efi_data_all=$(efibootmgr --verbose)

# split EFI data into a string array
readarray -t efi_data_array <<<"$efi_data_all"

# obtain EFI data for a matching label
for efi_data_line in "${efi_data_array[@]}" ; do
  if [[ $efi_data_line =~ ^Boot([[:xdigit:]]{4})\*?[[:blank:]]+(.+)[[:blank:]]+HD\(([[:digit:]]+),[^,]+,([^,]+)[^\)]+\)/File\(([^\)]+)\) ]] ; then
    label="${BASH_REMATCH[2]}"
    if [ "$label" = "$old_label" ] || [ "$old_label" = '*' ] ; then
      if [ -z "$target_bootnum" ] ; then   # no `bootnum` match or candidate found yet
        if [ -z "$old_bootnum" ] || [ ${BASH_REMATCH[1]} = "$old_bootnum" ] ; then
          target_bootnum=${BASH_REMATCH[1]}
          target_part=${BASH_REMATCH[3]}
          target_uuid=${BASH_REMATCH[4]}
          target_loader=${BASH_REMATCH[5]}
        fi
      else   # `bootnum` match or candidate already found
        if [ -z "$old_bootnum" ] ; then
          echo "ERROR: more than one boot entry found with label matching '$old_label': $target_bootnum and ${BASH_REMATCH[1]};"
          echo "       please use optional 'bootnum' command line argument to resolve this ambiguity."
          exit 1
        fi
      fi
    fi
  fi
done
# ----------------------------------------------------------------------------------------------------------------------

# check if a matching label was found
if [ -z "$target_bootnum" ] ; then
  echo "$0 : ERROR : no EFI data found for any label matching '$old_label'."
  exit 1
fi
debug "Target found: BootNum=$target_bootnum, Part=$target_part, UUID=$target_uuid, Loader=$target_loader"

# obtain device for the partition with uuid that corresponds to the given label
device_for_uuid=${partitions[$target_uuid]}
if [ -z "$device_for_uuid" ] ; then
  echo "$0 : ERROR : EFI label '$old_label' is related to partition '$target_uuid' that is not currently known to the system."
  exit 1
fi
debug "Partition UUID $target_uuid corresponds to device $device_for_uuid"

# verify that device/partition name matches some expected pattern;
# the following partition name patterns/samples are recognized:
# - SCSI family : e.g. /dev/sda1
# - NVMe        : e.g. /dev/nvme0n1p1
# - MMC family  : e.g. /dev/mmcblk0p1
# see https://wiki.archlinux.org/index.php/Device_file#Block_device_names
if [[ $device_for_uuid =~ $REGEX_UUID ]] ; then
  device_name=${BASH_REMATCH[1]}
  device_part=${BASH_REMATCH[3]}
else
  echo "$0 : ERROR : unexpected device name format '$device_for_uuid' found by 'sfdisk' for partition that relates to the given label."
  exit 1
fi

# verify that partition number of the device matches partition number in the EFI entry
if [[ $device_part != "$target_part" ]] ; then
  echo "$0 : ERROR : partition number of the device [$device_part] is different from partition number in the EFI entry [$target_part]."
  exit 1
fi

# prepare efibootmgr commands to be executed
printf -v escaped_loader "%q" "$target_loader"
efi_command_1="efibootmgr --bootnum $target_bootnum --delete-bootnum"
efi_command_2="efibootmgr --create --disk $device_name --part $target_part --label '$new_label' --loader $escaped_loader"

# obtain final user consent and apply modifications
echo The following commands are about to be executed:
echo "  $efi_command_1"
echo "  $efi_command_2"
read -p "Execute these commands? [y/N] " -n 1 -r
echo   # terminate the shell UI line
if [[ $REPLY =~ ^[Yy]$ ]] ; then
  echo "... executing \`$efi_command_1\` ..."
  eval $efi_command_1
  echo "... executing \`$efi_command_2\` ..."
  eval $efi_command_2
else
  echo "$0 : INFO : command execution aborted"
fi
