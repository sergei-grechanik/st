#!/bin/bash

# vim: shiftwidth=4

# TODO: This script uses bash-specific features. Would be nice to make it more
#       portable.

HELP="This script send the given image to the terminal and outputs characters
that can be used to display this image using the unicode image placeholder
symbol approach. Note that it will use a single line of the output to display
uploading progress (which may be disabled with '-q').

  Usage:
    $(basename $0) [OPTIONS] <image_file>
    $(basename $0) --fix [<IDs>]

  Options:
    -c N, --columns N
        The number of columns for the image. By default the script will try to
        compute the optimal value by itself.
    -r N, --rows N
        The number of rows for the image. By default the script will try to
        compute the optimal value by itself.
    --id N
        Use the specified image id instead of finding a free one.
    --256
        Restrict the image id to be within the range [1; 255] and use the 256
        colors mode to specify the image id (~24 bits will be used for image ids
        by default).
    -o <file>, --output <file>
        Use <file> to output the characters representing the image, instead of
        stdout.
    -a, --append
        Do not clear the output file (the one specified with -o).
    -e <file>, --err <file>
        Use <file> to output error messages in addition to displaying them as
        the status.
    -l <file>, --log <file>
        Enable logging and write logs to <file>.
    -f <image_file>, --file <image_file>
        The image file (but you can specify it as a positional argument).
    -q, --quiet
        Do not show status messages or uploading progress. Error messages are
        still shown (but you can redirect them with -e).
    --fix [IDs], --reupload [IDs]
        Reupload the given IDs. If no IDs are given, try to guess which images
        need reuploading automatically.
    --noesc
        Do not issue the escape codes representing row numbers (encoded as
        foreground color).
    --max-cols N
        Do not exceed this value when automatically computing the number of
        columns. By default the width of the terminal is used as the maximum.
    --max-rows N
        Do not exceed this value when automatically computing the number of
        rows. This value cannot be larger than 255. By default the height of the
        terminal is used as the maximum.
    --cols-per-inch N
    --rows-per-inch N
        Floating point values specifying the number of terminal columns and rows
        per inch (may be approximate). Used to compute the optimal number of
        columns and rows when -c and -r are not specified. If these parameters
        are not specified, the environment variables
        TERMINAL_IMAGES_COLS_PER_INCH and TERMINAL_IMAGES_ROWS_PER_INCH will
        be used. If they are not specified either, 12.0 and 6.0 will be used as
        columns per inch and rows per inch respectively.
    --override-dpi N
        Override dpi value for the image (both vertical and horizontal). By
        default dpi values will be requested using the 'identify' utility.
    --no-tmux-hijack
        Do not try to hijack focus by creating a new pane when inside tmux and
        the current pane is not active (just fail instead).
    -h, --help
        Show this message

  Environment variables:
    TERMINAL_IMAGES_COLS_PER_INCH
    TERMINAL_IMAGES_ROWS_PER_INCH
        See  --cols-per-inch and --rows-per-inch.
    TERMINAL_IMAGES_CACHE_DIR
        The directory to store images being uploaded (in case if they need to be
        reuploaded) and information about used image ids.
    TERMINAL_IMAGES_NO_TMUX_HIJACK
        If set, disable tmux hijacking.
"

# Exit the script on keyboard interrupt
trap "exit 1" INT

cols=""
rows=""
max_cols=""
max_rows=""
use_256=""
image_id=""
cols_per_inch="$TERMINAL_IMAGES_COLS_PER_INCH"
rows_per_inch="$TERMINAL_IMAGES_ROWS_PER_INCH"
cache_dir="$TERMINAL_IMAGES_CACHE_DIR"
override_dpi=""
file=""
out="/dev/stdout"
err=""
log=""
quiet=""
noesc=""
append=""
tmux_hijack_allowed="1"
[[ -z "$TERMINAL_IMAGES_NO_TMUX_HIJACK" ]] || tmux_hijack_allowed=""
tmux_hijack_helper=""
store_code=""
store_pid=""
default_timeout=3

reupload=""
reupload_ids=()

# A utility function to print logs
echolog() {
    if [[ -n "$log" ]]; then
        (flock 1; echo "$$ $(date +%s.%3N) $1") >> "$log"
    fi
}

# A utility function to display what the script is doing.
echostatus() {
    echolog "$1"
    if [[ -z "$quiet" ]]; then
        # clear the current line
        echo -en "\033[2K\r"
        # And display the status
        echo -n "$1"
    fi
}

# Display a message, both as the status and to $err.
echostderr() {
    if [[ -z "$err" ]]; then
        echo "$1" >> /dev/stderr
        echolog "$1"
    else
        echostatus "$1"
        echo "$1" >> "$err"
    fi
}

# Display an error message, both as the status and to $err, prefixed with
# "error:".
echoerr() {
    echostderr "error: $1"
}

# Parse the command line.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--columns)
            cols="$2"
            shift 2
            ;;
        -r|--rows)
            rows="$2"
            shift 2
            ;;
        -a|--append)
            append="1"
            shift
            ;;
        -o|--output)
            out="$2"
            shift 2
            ;;
        -e|--err)
            err="$2"
            shift 2
            ;;
        -l|--log)
            log="$2"
            shift 2
            ;;
        -q|--quiet)
            quiet="1"
            shift
            ;;
        -h|--help)
            echo "$HELP"
            exit 0
            ;;
        -f|--file)
            if [[ -n "$file" ]]; then
                echoerr "Multiple image files are not supported"
                exit 1
            fi
            file="$2"
            shift 2
            ;;
        --id)
            image_id="$2"
            shift 2
            ;;
        --256)
            use_256=1
            shift
            ;;
        --noesc)
            noesc=1
            shift
            ;;
        --no-tmux-hijack)
            tmux_hijack_allowed=""
            shift
            ;;
        --max-cols)
            max_cols="$2"
            shift 2
            ;;
        --max-rows)
            max_rows="$2"
            if (( max_rows > 255 )); then
                echoerr "--max-rows cannot be larger than 255 ($2 is specified)"
                exit 1
            fi
            shift 2
            ;;
        --cols-per-inch)
            cols_per_inch="$2"
            shift 2
            ;;
        --rows-per-inch)
            rows_per_inch="$2"
            shift 2
            ;;
        --override-dpi)
            override_dpi="$2"
            shift 2
            ;;

        # Subcommand-like options
        --fix|--reupload)
            reupload=1
            shift
            while [[ "$1" =~ ^[0-9]+$ ]]; do
                reupload_ids+=("$1")
                shift
            done
            ;;

        # Options used internally.
        --store-pid)
            store_pid="$2"
            shift 2
            ;;
        --store-code)
            store_code="$2"
            shift 2
            ;;
        --tmux-hijack-helper)
            tmux_hijack_helper=1
            shift
            ;;

        -*)
            echoerr "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -n "$file" ]]; then
                echoerr "Multiple image files are not supported: $file and $1"
                exit 1
            fi
            file="$1"
            shift
            ;;
    esac
done

echolog ""

# Store the pid of the current process if requested. This is needed for tmux
# hijacking so that the original script can wait for the uploading process.
if [[ -n "$store_pid" ]]; then
    echolog "Storing $$ to $store_pid"
    echo "$$" > "$store_pid"
fi

#####################################################################
# Detecting tmux and figuring out the actual terminal name
#####################################################################

# The name of the terminal, used to adjust to the specific flavor of the
# protocol (like whether we need to convert to PNG).
actual_term="$TERM"

# Some id of the terminal. Used to figure out whether some image has already
# been uploaded to the terminal without querying the terminal itself. Without
# tmux we just use the window id of the terminal which should somewhat uniquely
# identify the instance of the terminal.
terminal_id="$TERM-$WINDOWID"

# Some id of the session. Each session contains its own "namespace" of image
# ids, i.e. if two processes belong to the same session and load different
# images, these images have to be assigned to different image ids. Without tmux
# we just use the terminal id since we can't (easily) reattach a session to a
# different terminal. For tmux see below.
session_id="$terminal_id"

# This variable indicates whether we are inside tmux.
inside_tmux=""
if [[ -n "$TMUX" ]] && [[ "$TERM" =~ "screen" ]]; then
    inside_tmux="1"
    # Get the actual current terminal name from tmux.
    actual_term="$(tmux display-message -p "#{client_termname}")"
    # There doesn't seem to be a nice way to reliably get the current WINDOWID
    # of the terminal we are attached to (please correct me if I'm wrong). So we
    # use the last client pid of tmux as terminal id.
    terminal_id="tmux-client-$(tmux display-message -p "#{client_pid}")"
    # For the session id we use the tmux server pid with tmux session id.
    session_id="tmux-$(tmux display-message -p "#{pid}-#{session_id}")"
fi

# Replace non-alphabetical chars with '-' to make them suitable for dir names.
terminal_id="$(sed 's/[^0-9a-zA-Z]/-/g' <<< "$terminal_id")"
session_id="$(sed 's/[^0-9a-zA-Z]/-/g' <<< "$session_id")"

# Make sure that the cache dir contains session and terminal subdirs.
[[ -n "$cache_dir" ]] || cache_dir="$HOME/.cache/terminal-images"
session_dir_256="$cache_dir/sessions/${session_id}-8bit_ids"
terminal_dir_256="$cache_dir/terminals/${terminal_id}-8bit_ids"
session_dir_24bit="$cache_dir/sessions/${session_id}-24bit_ids"
terminal_dir_24bit="$cache_dir/terminals/${terminal_id}-24bit_ids"

mkdir -p "$cache_dir/cache/" 2> /dev/null
mkdir -p "$session_dir_256" 2> /dev/null
mkdir -p "$terminal_dir_256" 2> /dev/null
mkdir -p "$session_dir_24bit" 2> /dev/null
mkdir -p "$terminal_dir_24bit" 2> /dev/null

echolog "terminal_id=$terminal_id"
echolog "session_id=$session_id"

#####################################################################
# Creating a temp dir and adjusting the terminal state
#####################################################################

# Create a temporary directory to store the chunked image.
tmpdir="$(mktemp -d)"

if [[ ! "$tmpdir" || ! -d "$tmpdir" ]]; then
    echoerr "Can't create a temp dir"
    exit 1
fi

# We need to disable echo, otherwise the response from the terminal containing
# the image id will get echoed. We will restore the terminal settings on exit
# unless we get brutally killed.
stty_orig=`stty -g`
stty -echo
# Disable ctrl-z. Pressing ctrl-z during image uploading may cause some horrible
# issues otherwise.
stty susp undef

# Utility to read response from the terminal that we don't need anymore. (If we
# don't read it it may end up being displayed which is not pretty).
consume_errors() {
    while read -r -d '\' -t 0.1 term_response; do
        echolog "Consuming unneeded response: $(sed 's/\x1b/^[/g' <<< "$term_response")"
    done
}

# On exit restore terminal settings, consume possible errors from the terminal
# and remove the temporary directory.
cleanup() {
    consume_errors
    stty $stty_orig
    [[ -z "$tmpdir" ]] || rm "$tmpdir/"* 2> /dev/null
    rmdir "$tmpdir" || echolog "Could not remove $tmpdir"
}

# Register the cleanup function to be called on the EXIT signal.
trap cleanup EXIT TERM

#####################################################################
# Helper functions for image uploading
#####################################################################

# Functions to emit the start and the end of a graphics command.
if [[ -n "$inside_tmux" ]]; then
    # If we are in tmux we have to wrap the command in Ptmux.
    start_gr_command() {
        echo -en '\ePtmux;\e\e_G'
    }
    end_gr_command() {
        echo -en '\e\e\\\e\\'
    }
else
    start_gr_command() {
        echo -en '\e_G'
    }
    end_gr_command() {
        echo -en '\e\\'
    }
fi

# Send a graphics command with the correct start and end
gr_command() {
    start_gr_command
    echo -en "$1"
    end_gr_command
    if [[ -n "$log" ]]; then
        local gr_command="$(start_gr_command)$(echo -en "$1")$(end_gr_command)"
        echolog "SENDING COMMAND: $(sed 's/\x1b/^[/g' <<< "$gr_command")"
    fi
}

# Show the invalid terminal response message.
invalid_terminal_response() {
    echoerr "Invalid terminal response: $(sed 's/\x1b/^[/g' <<< "$term_response")"
}

# Get a response from the terminal and store it in term_response,
# returns 1 if there is no response.
get_terminal_response() {
    term_response=""
    term_response_printable=""
    # -r means backslash is part of the line
    # -d '\' means \ is the line delimiter
    # -t 2 is timeout
    if ! read -r -d '\' -t 2 term_response; then
        if [[ -z "$term_response" ]]; then
            echoerr "No response from terminal"
        else
            invalid_terminal_response
        fi
        return 1
    fi
    term_response_printable="$(sed 's/\x1b/^[/g' <<< "$term_response")"
    echolog "term_response: $term_response_printable"
}

# Uploads an image to the terminal.
# Usage: upload_image $image_id $file $cols $rows
upload_image() {
    local image_id="$1"
    local file="$2"
    local cols="$3"
    local rows="$4"

    rm "$tmpdir/"* 2> /dev/null

    if [[ "$actual_term" == *kitty* ]]; then
        # Check if the image is a png, and if it's not, try to convert it.
        if ! (file "$file" | grep -q "PNG image"); then
            echostatus "Converting $file to png"
            if ! convert "$file" "$tmpdir/image.png" || \
                    ! [[ -f "$tmpdir/image.png" ]]; then
                echoerr "Cannot convert image to png"
                return 1
            fi
            file="$tmpdir/image.png"
        fi
    fi

    # base64-encode the file and split it into chunks. The size of each graphics
    # command shouldn't be more than 4096, so we set the size of an encoded
    # chunk to be 3968, slightly less than that.
    echostatus "base64-encoding and chunking the image"
    cat "$file" | base64 -w0 | split -b 3968 - "$tmpdir/chunk_"

    # Write the size of the image in bytes to the "size" file.
    wc -c < "$file" > "$tmpdir/size"

    upload_chunked_image "$image_id" "$tmpdir" "$cols" "$rows"
    return $?
}

# Uploads an already chunked image to the terminal.
# Usage: upload_chunked_image $image_id $chunks_dir $cols $rows
upload_chunked_image() {
    local image_id="$1"
    local chunks_dir="$2"
    local cols="$3"
    local rows="$4"

    # Check if we are in the active tmux pane. Uploading images from inactive
    # panes is impossible, so we either need to fail or to hijack focus by
    # creating a new pane.
    if [[ -n "$inside_tmux" ]]; then
        local tmux_active="$(tmux display-message -t $TMUX_PANE \
                                -p "#{window_active}#{pane_active}")"
        if [[ "$tmux_active" != "11" ]]; then
            hijack_tmux "$image_id" "$chunks_dir" "$cols" "$rows"
            return $?
        fi
    fi

    # Read the original file size from the "size" file
    local size_info=""
    if [[ -e "$chunks_dir/size" ]]; then
        size_info=",S=$(cat "$chunks_dir/size")"
    fi

    # Issue a command indicating that we want to start data transmission for a
    # new image.
    # a=t    the action is to transmit data
    # i=$image_id
    # f=100  PNG. st will ignore this field, for kitty we support only PNG.
    # t=d    transmit data directly
    # c=,r=  width and height in cells
    # s=,v=  width and height in pixels (not used here)
    # o=z    use compression (not used here)
    # m=1    multi-chunked data
    # S=     original file size
    gr_command "a=t,i=$image_id,f=100,t=d,c=${cols},r=${rows},m=1${size_info}"

    chunks_count="$(ls -1 "$chunks_dir/chunk_"* | wc -l)"
    chunk_i=0
    start_time="$(date +%s%3N)"
    speed=""

    # Transmit chunks and display progress.
    for chunk in "$chunks_dir/chunk_"*; do
        echolog "Uploading chunk $chunk"
        chunk_i=$((chunk_i+1))
        if [[ $((chunk_i % 10)) -eq 1 ]]; then
            # Do not compute the speed too often
            if [[ $((chunk_i % 100)) -eq 1 ]]; then
                # We use +%s%3N tow show time in nanoseconds
                CURTIME="$(date +%s%3N)"
                TIMEDIFF="$((CURTIME - start_time))"
                if [[ "$TIMEDIFF" -ne 0 ]]; then
                    speed="$(((chunk_i*4 - 4)*1000/TIMEDIFF)) K/s"
                fi
            fi
            echostatus "$((chunk_i*4))/$((chunks_count*4))K [$speed]"
        fi
        # The uploading of the chunk goes here.
        start_gr_command
        echo -en "i=$image_id,m=1;"
        cat $chunk
        end_gr_command
    done

    # Tell the terminal that we are done.
    gr_command "i=$image_id,m=0"

    echostatus "Awaiting terminal response"
    get_terminal_response
    if [[ "$?" != 0 ]]; then
        return 1
    fi
    regex='.*_G.*;OK.*'
    if ! [[ "$term_response" =~ $regex ]]; then
        echoerr "Uploading error: $term_response_printable"
        return 1
    fi
    return 0
}

# Creates a tmux pane and uploads an already chunked image to the terminal.
# Usage: hijack_tmux $image_id $chunks_dir $cols $rows
hijack_tmux() {
    local image_id="$1"
    local chunks_dir="$2"
    local cols="$3"
    local rows="$4"

    if [[ -z "$tmux_hijack_allowed" ]]; then
        echoerr "Not in active pane and tmux hijacking is not allowed"
        return 1
    fi

    echostatus "Not in active pane, hijacking tmux"
    local tmp_pid="$(mktemp)"
    local tmp_ret="$(mktemp)"
    echolog "tmp_pid=$tmp_pid"
    # Run a helper in a new pane
    tmux split-window -l 1 "$0" \
        -c "$cols" \
        -r "$rows" \
        -e "$err" \
        -l "$log" \
        -f "$chunks_dir" \
        --id "$image_id" \
        --store-pid "$tmp_pid" \
        --store-code "$tmp_ret" \
        --tmux-hijack-helper
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    # The process we've created should write its pid to the specified file. It's
    # not always quick.
    for iter in $(seq 10); do
        sleep 0.1
        local pid_to_wait="$(cat $tmp_pid)"
        if [[ -n "$pid_to_wait" ]]; then
            break
        fi
    done
    if [[ -z "$pid_to_wait" ]]; then
        echoerr "Can't create a tmux hijacking process"
        return 1
    fi
    echolog "Waiting for the process $pid_to_wait"
    # Wait for the process to finish.
    # tail --pid=$pid_to_wait -f /dev/null
    while true; do
        sleep 0.1
        if ! kill -0 "$pid_to_wait" 2> /dev/null; then
            break
        fi
    done
    ret_code="$(cat $tmp_ret)"
    echolog "Process $pid_to_wait finished with code $ret_code"
    rm "$tmp_ret" 2> /dev/null || echolog "Could not rm $tmp_ret"
    rm "$tmp_pid" 2> /dev/null || echolog "Could not rm $tmp_pid"
    [[ -n "$ret_code" ]] || ret_code="1"
    return "$ret_code"
}

#####################################################################
# Running the tmux hijack helper if requested.
#####################################################################

if [[ -n "$tmux_hijack_helper" ]]; then
    # Do not allow any more hijack attempts.
    tmux_hijack_allowed=""
    upload_chunked_image "$image_id" "$file" "$cols" "$rows"
    ret_code="$?"
    echo "$ret_code" > "$store_code"
    exit "$ret_code"
fi

#####################################################################
# Handling the reupload command
#####################################################################

if [[ -n "$reupload" ]]; then
    # If no IDs were specified, collect all ids that are not known to be
    # uploaded into this terminal.
    if [[ ${#reupload_ids[@]} == 0 ]]; then
        for inst_file in "$session_dir_256"/*; do
            id="$(head -1 "$inst_file")"
            if [[ ! -e "$terminal_dir_256/$id" ]]; then
                reupload_ids+="$id"
            fi
        done
        for inst_file in "$session_dir_24bit"/*; do
            id="$(head -1 "$inst_file")"
            if [[ ! -e "$terminal_dir_24bit/$id" ]]; then
                reupload_ids+="$id"
            fi
        done
    fi

    if [[ ${#reupload_ids[@]} == 0 ]]; then
        echostderr "No images need fixing in $session_dir_256 and $session_dir_24bit"
        exit 0
    fi

    for session_dir in "$session_dir_256" "$session_dir_24bit"; do
        for inst in $(ls -t "$session_dir"); do
            inst_file="$session_dir/$inst"
            [[ -e "$inst_file" ]] || continue
            id="$(head -1 "$inst_file")"
            for idx in "${!reupload_ids[@]}"; do
                if [[ "${reupload_ids[idx]}" == "$id" ]]; then
                    unset reupload_ids[idx]
                    break
                fi
            done
        done
    done

    if [[ ${#reupload_ids[@]} != 0 ]]; then
        echoerr "Could not find IDs: ${reupload_ids[*]}"
        exit 1
    fi

    exit 0
fi

#####################################################################
# Compute the number of rows and columns
#####################################################################

# Check if the file exists.
if ! [[ -f "$file" ]]; then
    echoerr "File not found: $file (pwd: $(pwd))"
    exit 1
fi

echolog "Image file: $file (pwd: $(pwd))"

# Compute the formula with bc and round to the nearest integer.
bc_round() {
    echo "$(LC_NUMERIC=C printf %.0f "$(echo "scale=2;($1) + 0.5" | bc)")"
}

if [[ -z "$cols" || -z "$rows" ]]; then
    # Compute the maximum number of rows and columns if these values were not
    # specified.
    if [[ -z "$max_cols" ]]; then
        max_cols="$(tput cols)"
    fi
    if [[ -z "$max_rows" ]]; then
        max_rows="$(tput lines)"
        if (( max_rows > 255 )); then
            max_rows=255
        fi
    fi
    # Default values of rows per inch and columns per inch.
    [[ -n "$cols_per_inch" ]] || cols_per_inch=12.0
    [[ -n "$rows_per_inch" ]] || rows_per_inch=6.0
    # Get the size of the image and its resolution
    props=($(identify -format '%w %h %x %y' -units PixelsPerInch "$file"))
    if [[ "${#props[@]}" -ne 4 ]]; then
        echoerr "Couldn't get result from identify"
        exit 1
    fi
    if [[ -n "$override_dpi" ]]; then
        props[2]="$override_dpi"
        props[3]="$override_dpi"
    fi
    echolog "Image pixel width: ${props[0]} pixel height: ${props[1]}"
    echolog "Image x dpi: ${props[2]} y dpi: ${props[3]}"
    echolog "Columns per inch: ${cols_per_inch} Rows per inch: ${rows_per_inch}"
    opt_cols_expr="(${props[0]}*${cols_per_inch}/${props[2]})"
    opt_rows_expr="(${props[1]}*${rows_per_inch}/${props[3]})"
    if [[ -z "$cols" && -z "$rows" ]]; then
        # If columns and rows are not specified, compute the optimal values
        # using the information about rows and columns per inch.
        cols="$(bc_round "$opt_cols_expr")"
        rows="$(bc_round "$opt_rows_expr")"
    elif [[ -z "$cols" ]]; then
        # If only one dimension is specified, compute the other one to match the
        # aspect ratio as close as possible.
        cols="$(bc_round "${opt_cols_expr}*${rows}/${opt_rows_expr}")"
    elif [[ -z "$rows" ]]; then
        rows="$(bc_round "${opt_rows_expr}*${cols}/${opt_cols_expr}")"
    fi

    echolog "Image size before applying min/max columns: $cols, rows: $rows"
    # Make sure that automatically computed rows and columns are within some
    # sane limits
    if (( cols > max_cols )); then
        rows="$(bc_round "$rows * $max_cols / $cols")"
        cols="$max_cols"
    fi
    if (( rows > max_rows )); then
        cols="$(bc_round "$cols * $max_rows / $rows")"
        rows="$max_rows"
    fi
    if (( cols < 1 )); then
        cols=1
    fi
    if (( rows < 1 )); then
        rows=1
    fi
fi

echolog "Image size columns: $cols, rows: $rows"

#####################################################################
# Helper functions for finding image ids
#####################################################################

# Checks if the given string is an integer within the correct id range.
is_image_id_correct() {
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        if [[ -n "$use_256" ]]; then
            if (( "$1" < 256 )) && (( "$1" > 0 )); then
                return 0
            fi
        else
            if (( "$1" >= 256 )) && (( "$1" < 16777216 )); then
                return 0
            fi
        fi
    fi
    echoerr "$1 is incorrect"
    return 1
}

# Finds an image id for the instance $img_instance.
find_image_id() {
    local inst_file
    # Make sure that some_dir/* returns an empty list if some_dir is empty.
    shopt -s nullglob
    # Try to find an existing session image id corresponding to the instance.
    inst_file="$session_dir/$img_instance"
    if [[ -e "$inst_file" ]]; then
        image_id="$(head -1 "$inst_file")"
        if ! is_image_id_correct "$image_id"; then
            echoerr "Found invalid image_id $image_id, deleting $inst_file"
            rm "$inst_file"
        else
            touch "$inst_file"
            echolog "Found an existing image id $image_id"
            return 0
        fi
    fi
    # If there is no image id corresponding to the instance, try to find a free
    # image id.
    if [[ -n "$use_256" ]]; then
        local id
        local ids_array=($(seq 0 255))
        # Load ids and mark occupied ids with "0" (0 is an invalid id anyway).
        for inst_file in "$session_dir"/*; do
            id="$(head -1 "$inst_file")"
            if ! is_image_id_correct "$id"; then
                echoerr "Found invalid image_id $id, deleting $inst_file"
                rm "$inst_file"
            else
                ids_array[$id]="0"
            fi
        done
        # Try to find an array element that is not "0".
        for id in "${ids_array[@]}"; do
            if [[ "$id" != "0" ]]; then
                image_id="$id"
                echolog "Found a free image id $image_id"
                return 0
            fi
        done
        # On failure we need to reassign the id of the oldest image.
        local oldest_file=""
        for inst_file in "$session_dir"/*; do
            if [[ -z $oldest_file || $inst_file -ot $oldest_file ]]; then
                oldest_file="$inst_file"
            fi
        done
        image_id="$(head -1 "$inst_file")"
        echolog "Recuperating the id $image_id from $oldest_file"
        rm "$oldest_file"
        return 0
    else
        local ids_array=()
        # Load ids into the array.
        for inst_file in "$session_dir"/*; do
            id="$(head -1 "$inst_file")"
            if ! is_image_id_correct "$id"; then
                echoerr "Found invalid image_id $id, deleting $inst_file"
                rm "$inst_file"
            else
                ids_array+="$id"
            fi
        done
        image_id=""
        # Generate a random id until we find one that is not in use.
        while [[ -z "$image_id" ]]; do
            image_id="$(shuf -i 256-16777215 -n 1)"
            # Check that the id is not in use
            for id in "${ids_array[@]}"; do
                if [[ "$image_id" == "$id" ]]; then
                    image_id=""
                    break
                fi
            done
        done
        return 0
    fi
}

#####################################################################
# Assigning the image id
#####################################################################

# If the id is explicitly specified, set the $use_256 variable accordingly and
# then check that the id is correct.
if [[ -n "$image_id" ]]; then
    if (( "$image_id" < 256 )); then
        use_256="1"
    else
        use_256=""
    fi
    if ! is_image_id_correct "$image_id"; then
        echoerr "The specified image id $image_id is not correct"
        exit 1
    fi
fi

# 8-bit and 24-bit image ids live in different namespaces. We use different
# session and terminal directories to store information about them.
if [[ -n "$use_256" ]]; then
    session_dir="$cache_dir/sessions/${session_id}-8bit_ids"
    terminal_dir="$cache_dir/terminals/${terminal_id}-8bit_ids"
else
    session_dir="$cache_dir/sessions/${session_id}-24bit_ids"
    terminal_dir="$cache_dir/terminals/${terminal_id}-24bit_ids"
fi

# Compute md5sum and copy the file to the cache dir.
img_md5="$(md5sum "$file" | cut -f 1 -d " ")"
echolog "Image md5sum: $img_md5"

cached_file="$cache_dir/cache/$img_md5"
if [[ ! -e "$cached_file" ]]; then
    cp "$file" "$cached_file"
else
    touch "$cached_file"
fi

# Image instance is an image with its positioning attributes: columns, rows and
# any other attributes we may add in the future (alignment, scale mode, etc).
# Each image id corresponds to a single image instance.
img_instance="${img_md5}_${cols}_${rows}"

if [[ -n "$image_id" ]]; then
    echolog "Using the specified image id $image_id"
else
    # Find an id for the image. We want to avoid reuploading, and at the same
    # time we want to minimize image id collisions.
    echolog "Searching for a free image id"
    (
        flock --timeout "$default_timeout" 9 || \
            { echoerr "Could not acquire a lock on $session_dir.lock"; exit 1; }
        # Find the image id (see the function definition below).
        image_id=""
        find_image_id
        if [[ -z "$image_id" ]]; then
            echoerr "Failed to find an image id"
            exit 1
        fi
        # If it hasn't been loaded, create the instance file.
        if [[ ! -e "$session_dir/$img_instance" ]]; then
            echo "$image_id" > "$session_dir/$img_instance"
        fi
    ) 9>"$session_dir.lock" || exit 1

    image_id="$(head -1 "$session_dir/$img_instance")"

    echolog "Found an image id $image_id"
fi

#####################################################################
# Image uploading
#####################################################################

# Check if this instance has already been uploaded to this terminal with the
# found image id.
# TODO: Also check date and reupload if too old.
if [[ -e "$terminal_dir/$image_id" ]] &&
   [[ "$(head -1 "$terminal_dir/$image_id")" == "$img_instance" ]]; then
    echolog "Image already uploaded"
else
    (
        flock --timeout "$default_timeout" 9 || \
            { echoerr "Could not acquire a lock on $terminal_dir.lock"; exit 1; }
        rm "$terminal_dir/$image_id" 2> /dev/null
        upload_image "$image_id" "$file" "$cols" "$rows"
        if [[ "$?" == "0" ]]; then
            echo "$img_instance" > "$terminal_dir/$image_id"
        fi
    ) 9>"$terminal_dir.lock" || exit 1
fi

#####################################################################
# Printing the image placeholder
#####################################################################

rowcolumn_diacritics=("\U305" "\U30d" "\U30e" "\U310" "\U312" "\U33d" "\U33e"
    "\U33f" "\U346" "\U34a" "\U34b" "\U34c" "\U350" "\U351" "\U352" "\U357"
    "\U35b" "\U363" "\U364" "\U365" "\U366" "\U367" "\U368" "\U369" "\U36a"
    "\U36b" "\U36c" "\U36d" "\U36e" "\U36f" "\U483" "\U484" "\U485" "\U486"
    "\U487" "\U592" "\U593" "\U594" "\U595" "\U597" "\U598" "\U599" "\U59c"
    "\U59d" "\U59e" "\U59f" "\U5a0" "\U5a1" "\U5a8" "\U5a9" "\U5ab" "\U5ac"
    "\U5af" "\U5c4" "\U610" "\U611" "\U612" "\U613" "\U614" "\U615" "\U616"
    "\U617" "\U657" "\U658" "\U659" "\U65a" "\U65b" "\U65d" "\U65e" "\U6d6"
    "\U6d7" "\U6d8" "\U6d9" "\U6da" "\U6db" "\U6dc" "\U6df" "\U6e0" "\U6e1"
    "\U6e2" "\U6e4" "\U6e7" "\U6e8" "\U6eb" "\U6ec" "\U730" "\U732" "\U733"
    "\U735" "\U736" "\U73a" "\U73d" "\U73f" "\U740" "\U741" "\U743" "\U745"
    "\U747" "\U749" "\U74a" "\U7eb" "\U7ec" "\U7ed" "\U7ee" "\U7ef" "\U7f0"
    "\U7f1" "\U7f3" "\U816" "\U817" "\U818" "\U819" "\U81b" "\U81c" "\U81d"
    "\U81e" "\U81f" "\U820" "\U821" "\U822" "\U823" "\U825" "\U826" "\U827"
    "\U829" "\U82a" "\U82b" "\U82c" "\U82d" "\U951" "\U953" "\U954" "\Uf82"
    "\Uf83" "\Uf86" "\Uf87" "\U135d" "\U135e" "\U135f" "\U17dd" "\U193a"
    "\U1a17" "\U1a75" "\U1a76" "\U1a77" "\U1a78" "\U1a79" "\U1a7a" "\U1a7b"
    "\U1a7c" "\U1b6b" "\U1b6d" "\U1b6e" "\U1b6f" "\U1b70" "\U1b71" "\U1b72"
    "\U1b73" "\U1cd0" "\U1cd1" "\U1cd2" "\U1cda" "\U1cdb" "\U1ce0" "\U1dc0"
    "\U1dc1" "\U1dc3" "\U1dc4" "\U1dc5" "\U1dc6" "\U1dc7" "\U1dc8" "\U1dc9"
    "\U1dcb" "\U1dcc" "\U1dd1" "\U1dd2" "\U1dd3" "\U1dd4" "\U1dd5" "\U1dd6"
    "\U1dd7" "\U1dd8" "\U1dd9" "\U1dda" "\U1ddb" "\U1ddc" "\U1ddd" "\U1dde"
    "\U1ddf" "\U1de0" "\U1de1" "\U1de2" "\U1de3" "\U1de4" "\U1de5" "\U1de6"
    "\U1dfe" "\U20d0" "\U20d1" "\U20d4" "\U20d5" "\U20d6" "\U20d7" "\U20db"
    "\U20dc" "\U20e1" "\U20e7" "\U20e9" "\U20f0" "\U2cef" "\U2cf0" "\U2cf1"
    "\U2de0" "\U2de1" "\U2de2" "\U2de3" "\U2de4" "\U2de5" "\U2de6" "\U2de7"
    "\U2de8" "\U2de9" "\U2dea" "\U2deb" "\U2dec" "\U2ded" "\U2dee" "\U2def"
    "\U2df0" "\U2df1" "\U2df2" "\U2df3" "\U2df4" "\U2df5" "\U2df6" "\U2df7"
    "\U2df8" "\U2df9" "\U2dfa" "\U2dfb" "\U2dfc" "\U2dfd" "\U2dfe" "\U2dff"
    "\Ua66f" "\Ua67c" "\Ua67d" "\Ua6f0" "\Ua6f1" "\Ua8e0" "\Ua8e1" "\Ua8e2"
    "\Ua8e3" "\Ua8e4" "\Ua8e5" "\Ua8e6" "\Ua8e7" "\Ua8e8" "\Ua8e9" "\Ua8ea"
    "\Ua8eb" "\Ua8ec" "\Ua8ed" "\Ua8ee" "\Ua8ef" "\Ua8f0" "\Ua8f1" "\Uaab0"
    "\Uaab2" "\Uaab3" "\Uaab7" "\Uaab8" "\Uaabe" "\Uaabf" "\Uaac1" "\Ufe20"
    "\Ufe21" "\Ufe22" "\Ufe23" "\Ufe24" "\Ufe25" "\Ufe26" "\U10a0f" "\U10a38"
    "\U1d185" "\U1d186" "\U1d187" "\U1d188" "\U1d189" "\U1d1aa" "\U1d1ab"
    "\U1d1ac" "\U1d1ad" "\U1d242" "\U1d243" "\U1d244")

# Each line starts with the escape sequence to set the foreground color to the
# image id, unless --noesc is specified.
line_start=""
line_end=""
if [[ -z "$noesc" ]]; then
    if [[ -n "$use_256" ]]; then
        line_start="$(echo -en "\e[38;5;${image_id}m")"
        line_end="$(echo -en "\e[39;m")"
    else
        blue="$(( "$image_id" % 256 ))"
        green="$(( ("$image_id" / 256) % 256 ))"
        red="$(( ("$image_id" / 65536) % 256 ))"
        line_start="$(echo -en "\e[38;2;${red};${green};${blue}m")"
        line_end="$(echo -en "\e[39;m")"
    fi
fi

# Clear the status line.
echostatus

# Clear the output file
if [[ -z "$append" ]]; then
    > "$out"
fi

# Fill the output with characters representing the image
for y in `seq 0 $(expr $rows - 1)`; do
    echo -n "$line_start" >> "$out"
    for x in `seq 0 $(expr $cols - 1)`; do
        printf "\UEEEE${rowcolumn_diacritics[$y]}${rowcolumn_diacritics[$x]}"
    done
    echo -n "$line_end" >> "$out"
    printf "\n" >> "$out"
done

echolog "Finished displaying the image"
exit 0
