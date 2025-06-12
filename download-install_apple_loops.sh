#!/bin/sh -x

###################
# download-install_apple_loops.sh - script to download and install all available Apple loops for the specified plist
# Shannon Pasto https://github.com/shannonpasto/AppleLoops
#
# v1.2.3 (21/01/2025)
# Russell Collis https://github.com/RussellCollis/AppleLoops
# v1.2.4 (13/03/2025)
# v2 (12/06/2025) Logic Pro 1120 + Logging

###################

## uncomment the next line to output debugging to stdout
#set -x

###############################################################################
## variable declarations
# shellcheck disable=SC2034
ME=$(basename "$0")
# shellcheck disable=SC2034
BINPATH=$(dirname "$0")
appPlist="" # garageband1047 logicpro1120 mainstage362. multiple plists can be specified, separate with a space

# Logging variables
LOG_FILE="/var/log/${ME%.*}.log"
LOG_LEVEL_DEBUG=1
LOG_LEVEL_INFO=2
LOG_LEVEL_WARN=3
LOG_LEVEL_ERROR=4
CURRENT_LOG_LEVEL=$LOG_LEVEL_INFO # Set desired logging level (e.g., INFO, DEBUG)

###############################################################################
## function declarations

# Function to log messages
log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    case "$level" in
        DEBUG)
            if [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_DEBUG" ]; then
                echo "${timestamp} [DEBUG] ${message}" | tee -a "$LOG_FILE"
            fi
            ;;
        INFO)
            if [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_INFO" ]; then
                echo "${timestamp} [INFO] ${message}" | tee -a "$LOG_FILE"
            fi
            ;;
        WARN)
            if [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_WARN" ]; then
                echo "${timestamp} [WARN] ${message}" | tee -a "$LOG_FILE"
            fi
            ;;
        ERROR)
            if [ "$CURRENT_LOG_LEVEL" -le "$LOG_LEVEL_ERROR" ]; then
                echo "${timestamp} [ERROR] ${message}" | tee -a "$LOG_FILE"
            fi
            ;;
        *)
            echo "${timestamp} [UNKNOWN] ${message}" | tee -a "$LOG_FILE"
            ;;
    esac
}

exit_trap() {
    log INFO "Running exit trap..."
    # clean up
    /bin/rm -rf "${tmpDir}" >/dev/null 2>&1
    log DEBUG "Removed temporary directory: ${tmpDir}"
    /bin/kill "${cafPID}" >/dev/null 2>&1
    log DEBUG "Killed caffeinate process (PID: ${cafPID})"

    # Recreate /private/tmp with correct permissions if $4 is not populated
    if [ -d /private/tmp ]; then
        log INFO "/private/tmp folder exists."
    else
        log WARN "/private/tmp folder doesn't exist, creating..."
        /bin/mkdir -p /private/tmp
        /bin/chmod 777 /private/tmp
        log INFO "Created /private/tmp with permissions 777."
    fi
    log INFO "Exit trap complete."
}

###############################################################################
## start the script here
log INFO "Script started."
trap exit_trap EXIT

# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 4 AND, IF SO, ASSIGN TO "appPlist"
if [ "${4}" != "" ] && [ "${appPlist}" = "" ]; then
    log INFO "Parameter 4 configured: ${4}"
    appPlist="${4}"
elif [ "${4}" != "" ] || [ "${appPlist}" != "" ]; then
    log INFO "Parameter 4 overwritten by script variable. Using: ${appPlist}"
fi

tmpDir="/tmp/${appPlist}"
log INFO "Creating temporary directory: ${tmpDir}"
/bin/mkdir -p "${tmpDir}" || log ERROR "Failed to create temporary directory: ${tmpDir}" && exit 1

# see if we have a caching server on the network. pick the first one
log INFO "Checking for caching server..."
if [ "$(/usr/bin/sw_vers -buildVersion | /usr/bin/cut -c 1-2 -)" -ge 24 ]; then
    cacheSrvrURL=$(/usr/bin/AssetCacheLocatorUtil -j 2>/dev/null | /usr/bin/jq -r '.results.reachability[]' | /usr/bin/head -n 1)
else
    cacheCount=$(/usr/bin/AssetCacheLocatorUtil -j 2>/dev/null | /usr/bin/plutil -extract results.reachability raw -o - -)
    if [ "${cacheCount}" -gt 0 ]; then
        cacheSrvrURL=$(/usr/bin/AssetCacheLocatorUtil -j 2>/dev/null | /usr/bin/plutil -extract results.reachability.0 raw -o - -)
    fi
fi

if [ "${cacheSrvrURL}" ]; then
    log INFO "Cache server located: ${cacheSrvrURL}. Testing reachability..."
    /usr/bin/curl --telnet-option 'BOGUS=1' --connect-timeout 2 -s telnet://"${cacheSrvrURL}"
    if [ $? = 48 ]; then
        log INFO "Cache server reachable."
        baseURL="http://${cacheSrvrURL}/lp10_ms3_content_2016"
        baseURLOpt="?source=audiocontentdownload.apple.com&sourceScheme=https"
    else
        log WARN "Cache server not reachable. Falling back to default URL."
        baseURL="https://audiocontentdownload.apple.com/lp10_ms3_content_2016"
    fi
else
    log INFO "Cache Server not found or not reachable. Using default URL."
    baseURL="https://audiocontentdownload.apple.com/lp10_ms3_content_2016"
fi

log INFO "Base URL is ${baseURL}"

# take a double shot espresso
log INFO "Starting caffeinate process to prevent sleep."
/usr/bin/caffeinate -ims &
cafPID=$(pgrep caffeinate)
log DEBUG "Caffeinate PID: ${cafPID}"

if [ "${appPlist}" = "" ]; then
    log INFO "No plist configured as a parameter. Searching /Applications for any/all apps."
    plistNames="garageband logicpro mainstage"
    for X in $plistNames; do
        log DEBUG "Searching for ${X}*.plist in /Applications."
        /usr/bin/find /Applications -name "${X}*.plist" -maxdepth 4 | /usr/bin/rev | /usr/bin/cut -d "/" -f 1 - | /usr/bin/rev | /usr/bin/cut -d "." -f 1 - >> "${tmpDir}/thelist.txt"
    done

    if [ ! -s "${tmpDir}/thelist.txt" ]; then
        log ERROR "No valid application found. Exiting."
        exit 1
    else
        appPlist=$(/bin/cat "${tmpDir}/thelist.txt")
        log INFO "Found plists: ${appPlist}"
    fi
fi

for X in $appPlist; do
    # get the plist file
    log INFO "Fetching the Apple plist for ${X} from ${baseURL}/${X}.plist${baseURLOpt}"
    /usr/bin/curl -s "${baseURL}/${X}.plist${baseURLOpt}" -o "${tmpDir}/${X}".plist
    if [ $? -ne 0 ]; then
        log ERROR "Failed to download plist for ${X}. Skipping."
        continue
    fi

    if ! /usr/bin/plutil "${tmpDir}/${X}".plist >/dev/null 2>&1; then
        log ERROR "Invalid plist file for ${X}. Exiting."
        exit 1
    fi
    log INFO "Successfully downloaded and validated plist for ${X}."

    # loop through all the pkg files and download/install
    log INFO "Starting package download and installation for ${X}."
    for thePKG in $(/usr/bin/defaults read "${tmpDir}/${X}".plist Packages | /usr/bin/grep DownloadName | /usr/bin/awk -F \" '{print $2}'); do
        thePKGFile=$(/bin/echo "${thePKG}" | /usr/bin/sed 's/..\/lp10_ms3_content_2013\///')
        if ! /usr/sbin/pkgutil --pkgs | /usr/bin/grep -q "$(basename "${thePKGFile}" .pkg)"; then
            log INFO "Installing ${thePKGFile}..."
            log DEBUG "Downloading ${baseURL}/${thePKG}${baseURLOpt} to ${tmpDir}/${thePKGFile}"
            /usr/bin/curl -s "${baseURL}/${thePKG}${baseURLOpt}" -o "${tmpDir}/${thePKGFile}"
            if [ $? -ne 0 ]; then
                log ERROR "Failed to download ${thePKGFile}. Skipping."
                continue
            fi
            log DEBUG "Installing ${tmpDir}/${thePKGFile} to /"
            /usr/sbin/installer -pkg "${tmpDir}/${thePKGFile}" -target /
            if [ $? -ne 0 ]; then
                log ERROR "Failed to install ${thePKGFile}."
            else
                log INFO "${thePKGFile} installed successfully."
            fi
        else
            log INFO "${thePKGFile} already installed. Skipping."
        fi
    done
done

log INFO "Script finished successfully."
exit 0
