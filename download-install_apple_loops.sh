#!/bin/sh -x

###################
# download-install_apple_loops.sh - script to download and install all available Apple loops for the specified plist
# Shannon Pasto https://github.com/shannonpasto/AppleLoops
#
# v1.2.3 (21/01/2025)
# Russell Collis https://github.com/RussellCollis/AppleLoops
# v1.2.4 (13/03/2025)
# v1.2.5 (12/06/2025) Logic Pro 1120
# v1.2.6 (12/06/2025) - Added comprehensive logging

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

# --- Logging variables ---
LOG_FILE="/var/log/${ME%.*}.log" # Log file path (e.g., /var/log/download-install_apple_loops.log)
LOG_LEVEL_DEBUG=1
LOG_LEVEL_INFO=2
LOG_LEVEL_WARN=3
LOG_LEVEL_ERROR=4
CURRENT_LOG_LEVEL=$LOG_LEVEL_INFO # Set the desired logging level (e.g., INFO, DEBUG, WARN, ERROR)

###############################################################################
## function declarations

# Function to log messages to console and file
log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Check if the message's level is greater than or equal to the current log level
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
            # Fallback for unknown log levels
            echo "${timestamp} [UNKNOWN] ${message}" | tee -a "$LOG_FILE"
            ;;
    esac
}

exit_trap() {
    log INFO "Running exit trap for cleanup."

    # Clean up temporary directory
    /bin/rm -rf "${tmpDir}" >/dev/null 2>&1
    log DEBUG "Removed temporary directory: ${tmpDir}"

    # Kill caffeinate process if it's running
    if [ -n "${cafPID}" ]; then
        /bin/kill "${cafPID}" >/dev/null 2>&1
        log DEBUG "Killed caffeinate process (PID: ${cafPID})."
    else
        log DEBUG "Caffeinate process not found or not running."
    fi


    # Recreate /private/tmp with correct permissions if it doesn't exist
    if [ -d /private/tmp ]; then
        log INFO "/private/tmp folder exists."
    else
        log WARN "/private/tmp folder doesn't exist, attempting to create..."
        if /bin/mkdir -p /private/tmp && /bin/chmod 777 /private/tmp; then
            log INFO "Successfully created /private/tmp with permissions 777."
        else
            log ERROR "Failed to create /private/tmp or set permissions."
        fi
    fi
    log INFO "Exit trap complete."
}

###############################################################################
## start the script here
log INFO "Script started. Log file: ${LOG_FILE}"
trap exit_trap EXIT

# CHECK TO SEE IF A VALUE WAS PASSED IN PARAMETER 4 AND, IF SO, ASSIGN TO "appPlist"
if [ "${4}" != "" ] && [ "${appPlist}" = "" ]; then
    log INFO "Parameter 4 detected and configured as appPlist: '${4}'"
    appPlist="${4}"
elif [ "${4}" != "" ] || [ "${appPlist}" != "" ]; then
    log INFO "Parameter 4 '${4}' provided, but script variable 'appPlist' was already set to '${appPlist}'. Script variable takes precedence."
fi

tmpDir="/tmp/${appPlist}"
log INFO "Attempting to create temporary directory: '${tmpDir}'"
if ! /bin/mkdir -p "${tmpDir}"; then
    log ERROR "Failed to create temporary directory: '${tmpDir}'. Exiting."
    exit 1
fi
log INFO "Temporary directory created: '${tmpDir}'."

# See if we have a caching server on the network. Pick the first one.
log INFO "Checking for a caching server..."
if [ "$(/usr/bin/sw_vers -buildVersion | /usr/bin/cut -c 1-2 -)" -ge 24 ]; then
    # macOS Sonoma (or newer)
    cacheSrvrURL=$(/usr/bin/AssetCacheLocatorUtil -j 2>/dev/null | /usr/bin/jq -r '.results.reachability[]' | /usr/bin/head -n 1)
    log DEBUG "Using AssetCacheLocatorUtil with jq for macOS >= 14."
else
    # Older macOS versions
    cacheCount=$(/usr/bin/AssetCacheLocatorUtil -j 2>/dev/null | /usr/bin/plutil -extract results.reachability raw -o - -)
    log DEBUG "Using AssetCacheLocatorUtil with plutil for macOS < 14. Cache count: ${cacheCount}."
    if [ "${cacheCount}" -gt 0 ]; then
        cacheSrvrURL=$(/usr/bin/AssetCacheLocatorUtil -j 2>/dev/null | /usr/bin/plutil -extract results.reachability.0 raw -o - -)
    fi
fi

if [ "${cacheSrvrURL}" ]; then
    log INFO "Caching server found: '${cacheSrvrURL}'. Testing reachability..."
    # Test connectivity to the cache server
    if /usr/bin/curl --telnet-option 'BOGUS=1' --connect-timeout 2 -s telnet://"${cacheSrvrURL}" >/dev/null 2>&1; then
        log INFO "Caching server is reachable. Using it as base URL."
        baseURL="http://${cacheSrvrURL}/lp10_ms3_content_2016"
        baseURLOpt="?source=audiocontentdownload.apple.com&sourceScheme=https"
    else
        log WARN "Caching server '${cacheSrvrURL}' not reachable. Falling back to default Apple content server."
        baseURL="https://audiocontentdownload.apple.com/lp10_ms3_content_2016"
    fi
else
    log INFO "No caching server found or reachable. Using default Apple content server."
    baseURL="https://audiocontentdownload.apple.com/lp10_ms3_content_2016"
fi

log INFO "Base URL for content downloads: '${baseURL}'"

# Take a double shot espresso (prevent system sleep during downloads)
log INFO "Starting caffeinate to prevent system sleep."
/usr/bin/caffeinate -ims &
cafPID=$(pgrep caffeinate)
if [ -n "${cafPID}" ]; then
    log DEBUG "Caffeinate process started with PID: ${cafPID}"
else
    log WARN "Could not start caffeinate process."
fi

if [ "${appPlist}" = "" ]; then
    log INFO "No plist configured as a parameter. Searching /Applications for installed Apple apps."
    plistNames="garageband logicpro mainstage"
    for X in $plistNames; do
        log DEBUG "Searching for '${X}*.plist' within /Applications."
        /usr/bin/find /Applications -name "${X}*.plist" -maxdepth 4 | \
        /usr/bin/rev | /usr/bin/cut -d "/" -f 1 - | /usr/bin/rev | /usr/bin/cut -d "." -f 1 - \
        >> "${tmpDir}/thelist.txt" 2>/dev/null
    done

    if [ ! -s "${tmpDir}/thelist.txt" ]; then
        log ERROR "No valid Apple application plists found. Exiting."
        exit 1
    else
        appPlist=$(/bin/cat "${tmpDir}/thelist.txt")
        log INFO "Discovered app plists: '${appPlist}'"
    fi
fi

# Process each specified app plist
for X in $appPlist; do
    log INFO "Processing app plist: '${X}'"
    plistDownloadURL="${baseURL}/${X}.plist${baseURLOpt}"
    plistLocalPath="${tmpDir}/${X}.plist"

    log INFO "Fetching Apple plist for '${X}' from '${plistDownloadURL}'"
    if ! /usr/bin/curl -s "${plistDownloadURL}" -o "${plistLocalPath}"; then
        log ERROR "Failed to download plist for '${X}' from '${plistDownloadURL}'. Skipping this app."
        continue # Skip to the next app plist
    fi
    log DEBUG "Downloaded plist to '${plistLocalPath}'."

    # Validate the downloaded plist file
    if ! /usr/bin/plutil "${plistLocalPath}" >/dev/null 2>&1; then
        log ERROR "Invalid plist file found for '${X}' at '${plistLocalPath}'. Exiting."
        exit 1 # Invalid plist is a critical error, so exit
    fi
    log INFO "Plist for '${X}' validated successfully."

    # Loop through all the pkg files listed in the plist and download/install
    log INFO "Checking and installing packages for '${X}'."
    # Extract DownloadName from the plist. Add check for existence.
    pkgDownloadNames=$(/usr/bin/defaults read "${plistLocalPath}" Packages 2>/dev/null | /usr/bin/grep DownloadName | /usr/bin/awk -F \" '{print $2}')
    if [ -z "${pkgDownloadNames}" ]; then
        log WARN "No packages found in plist for '${X}'. Skipping package installation for this app."
        continue
    fi

    for thePKG in ${pkgDownloadNames}; do
        thePKGFile=$(/bin/echo "${thePKG}" | /usr/bin/sed 's/..\/lp10_ms3_content_2013\///')
        pkgIdentifier=$(basename "${thePKGFile}" .pkg)

        if ! /usr/sbin/pkgutil --pkgs | /usr/bin/grep -q "${pkgIdentifier}"; then
            log INFO "Package '${pkgIdentifier}' not installed. Proceeding with download and installation."
            pkgDownloadURL="${baseURL}/${thePKG}${baseURLOpt}"
            pkgLocalPath="${tmpDir}/${thePKGFile}"

            log DEBUG "Downloading package from '${pkgDownloadURL}' to '${pkgLocalPath}'."
            if ! /usr/bin/curl -s "${pkgDownloadURL}" -o "${pkgLocalPath}"; then
                log ERROR "Failed to download package '${thePKGFile}'. Skipping installation for this package."
                continue # Skip to the next package
            fi
            log INFO "Successfully downloaded package: '${thePKGFile}'."

            log INFO "Installing package: '${thePKGFile}' to /"
            if ! /usr/sbin/installer -pkg "${pkgLocalPath}" -target /; then
                log ERROR "Failed to install package: '${thePKGFile}'."
            else
                log INFO "Successfully installed package: '${thePKGFile}'."
            fi
        else
            log INFO "Package '${pkgIdentifier}' is already installed. Skipping."
        fi
    done
done

log INFO "Script finished successfully."
exit 0
