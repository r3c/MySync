#!/bin/sh -e

log() {
	local level="$1"

	shift

	if [ "$opt_log" -le "$level" ]; then
		case "$level" in
			0)
				printf >&2 "debug: %s\n" "$@"
				;;

			1)
				printf >&2 "%s\n" "$@"
				;;

			2)
				printf >&2 "warning: %s\n" "$@"
				;;

			3)
				printf >&2 "error: %s\n" "$@"
				;;
		esac
	fi
}

# Command line options
opt_config="$(dirname "$0")"/arshive.conf
opt_dryrun=
opt_log=1

while getopts :c:dhqv opt; do
	case "$opt" in
		c)
			opt_config="$(readlink -m "$OPTARG")"
			;;

		d)
			opt_dryrun=1
			;;

		h)
			echo >&2 "$(basename $0) [-c <path>] [-d] [-h] [-q] [-v]"
			echo >&2 '  -c <path>: use specified configuration file'
			echo >&2 '  -d: dry run, execute commands but do not write or delete backups'
			echo >&2 '  -h: display help and exit'
			echo >&2 '  -q: quiet mode'
			echo >&2 '  -v: verbose mode'
			exit
			;;

		q)
			opt_log=2
			;;

		v)
			opt_log=0
			;;

		:)
			log 3 "missing argument for option '-$OPTARG'"
			exit 1
			;;

		*)
			log 3 "unknown option '-$OPTARG'"
			exit 1
			;;
	esac
done

# Fail if unknown command line arguments are found
shift "$((OPTIND - 1))"

if [ $# -gt 0 ]; then
	log 3 "unrecognized command line arguments: '$@'"
	exit 1
fi

# Read configuration file and verify settings
if [ ! -r "$opt_config" ]; then
	log 3 "missing or unreadable configuration file: '$opt_config'"
	exit 1
fi

. "$opt_config"

basedir="$(dirname "$(readlink -m "$opt_config")")"
filemode="${filemode:-0644}"
lines="${lines:-10}"
logerr="$(cd "$basedir" && readlink -m "${logerr:-/tmp/arshive.log.err}")"
logout="$(cd "$basedir" && readlink -m "${logout:-/tmp/arshive.log.out}")"
placeholder='\{([^{}]*)\}'
target="$(cd "$basedir" && readlink -m "${target:-/tmp}")"

if ! printf "%s\n" "$filemode" | grep -qE '^[0-7]{3,4}$'; then
	log 3 "invalid configuration: option filemode ($filemode) must be using octal format (e.g. 0644)"
	exit 1
elif ! printf "%s\n" "$lines" | grep -qE '^[0-9]+$'; then
	log 3 "invalid configuration: option 'lines' ($lines) must be an integer"
	exit 1
elif printf "%s\n" "$placeholder" | grep -qF ':'; then
	log 3 "invalid configuration: option 'placeholder' ($placeholder) cannot use character ':'"
	exit 1
elif [ -z "$sources" ]; then
	log 3 "invalid configuration: no source files defined"
	exit 1
elif [ ! -d "$target" -o ! -r "$target" -o ! -w "$target" ]; then
	log 3 "invalid configuration: option 'target' ($target) is not a readable & writable directory"
	exit 1
fi

log 0 "starting with configuration from '$opt_config':"
log 0 "  filemode: $filemode"
log 0 "  lines: $lines"
log 0 "  logerr: $logerr"
log 0 "  logout: $logout"
log 0 "  placeholder: $placeholder"
log 0 "  target: $target"

# Parse each rules file defined in "sources" setting
result=0
stderr="$(mktemp)"
stdout="$(mktemp)"

for source in $(cd "$basedir" && readlink -m $sources); do
	log 0 "processing rule file '$source'"

	# Check source path validity
	if [ ! -r "$source" ]; then
		log 3 "missing or unreadable rule file '$source'"
		result=1

		continue
	fi

	# Scan rules defined in current rule file
	{
		sed -r '/^(#|$)/d;s/\r$//' "$source"
		echo 'flush:'
	} |
	{
		compatibility_pattern='^[[:blank:]]*([^[:blank:]]+)[[:blank:]]+([0-9]+)[[:blank:]]+([0-9]+)[[:blank:]]+(.*)$'
		line_index=0
		next_option_interval=86400
		next_option_keep=7
		option_pattern='^[[:blank:]]+([-_0-9A-Za-z]+)[[:blank:]]*=[[:blank:]]*(.*)$'
		rule_command=''
		rule_name=''
		rule_pattern='^([-_0-9A-Za-z]+)[[:blank:]]*:[[:blank:]]*(.*)$'

		while IFS='' read -r line; do
			line_index="$((line_index + 1))"

			# Parse current line
			if printf "%s\n" "$line" | grep -Eq "$rule_pattern"; then
				parse_1="$(printf "%s\n" "$line" | sed -nr "s/$rule_pattern/\\1/p")"
				parse_2="$(printf "%s\n" "$line" | sed -nr "s/$rule_pattern/\\2/p")"

				if ! printf "%s\n" "$parse_2" | grep -Eq -- "^\$|$placeholder"; then
					log 3 "command '$parse_2' does not contain a placeholder for rule '$parse_1' in file '$source' at line #$line_index"
					result=1

					continue
				fi

				next_option_interval=86400
				next_option_keep=7
				next_rule_command="$parse_2"
				next_rule_name="$parse_1"
			elif printf "%s\n" "$line" | grep -Eq "$option_pattern"; then
				parse_1="$(printf "%s\n" "$line" | sed -nr "s/$option_pattern/\\1/p")"
				parse_2="$(printf "%s\n" "$line" | sed -nr "s/$option_pattern/\\2/p")"

				case "$parse_1" in
					interval|keep)
						if ! printf "%s\n" "$parse_2" | grep -Eq -- '^[0-9]+$'; then
							log 2 "option '$parse_1' has a non-integer value '$parse_2' for rule '$next_rule_name' in file '$source' at line #$line_index"
							result=1

							continue
						fi

						;;

					*)
						log 2 "option '$parse_1' is unknown in file '$source' at line #$line_index"
						result=1

						continue

						;;
				esac

				eval "option_$parse_1='$parse_2'"

				continue
			elif printf "%s\n" "$line" | grep -Eq "$compatibility_pattern"; then
				next_option_interval="$(printf "%s\n" "$line" | sed -nr "s/$compatibility_pattern/\\2/p")"
				next_option_keep="$(printf "%s\n" "$line" | sed -nr "s/$compatibility_pattern/\\3/p")"
				next_rule_command="$(printf "%s\n" "$line" | sed -nr "s/$compatibility_pattern/\\4/p")"
				next_rule_name="$(printf "%s\n" "$line" | sed -nr "s/$compatibility_pattern/\\1/p")"

				if [ "$next_option_keep" -ge 3600 ]; then
					option_keep="$((next_option_keep / next_option_interval))"

					log 2 "compatibility: parameter 'keep' was too large for rule '$next_rule_name' in file '$source' at line #$line_index and was probably a duration ; up to $next_option_keep backup files will be kept instead"
				fi
			else
				log 3 "ignoring unrecognized line '$line' in file '$source' at line #$line_index"
				result=1

				continue
			fi

			# Flush command if there was a pending one, otherwise continue parsing
			if [ -n "$rule_command" ]; then
				# Browse existing backups
				create=
				keep="$option_keep"
				now="$(date +%s)"
				suffix="$(printf "%s\n" "$rule_command" | sed -nr -- "s:.*$placeholder.*:\\1:p")"

				for file in $(find -- "$target" -maxdepth 1 -type f -name "$rule_name.*$suffix" | sort -r); do
					# Check is a new backup file is required
					if [ -z "$create" ]; then
						backup="$(printf "%s\n" "${file#$target/$rule_name.}" | sed -nr -- "s:^([0-9]+)$suffix\$:\\1:p")"

						if [ -z "$backup" ]; then
							log 2 "$rule_name: file '$file' doesn't match current rule and will be ignored"
							result=1
						elif [ "$((now - backup))" -ge "$option_interval" ]; then
							create=1
						else
							create=0
							keep="$((keep + 1))"

							log 1 "$rule_name: up to date"
						fi
					fi

					# Delete expired backup files
					if [ "$keep" -gt 1 ]; then
						keep="$((keep - 1))"
					elif [ -n "$opt_dryrun" ]; then
						log 1 "$rule_name: backup file '$file' should have been deleted"
					else
						log 1 "$rule_name: deleting backup file '$file'"
						rm -f -- "$file"
					fi
				done

				# Stop if no new backup is required
				test "${create:-1}" -ne 0 || continue

				# Prepare new backup
				if [ -z "$opt_dryrun" ]; then
					file="$target/$rule_name.$now$suffix"
				else
					file=/dev/null
				fi

				# Execute backup command
				if ! sh -c "$(printf "%s\n" "$rule_command" | sed -r "s:$placeholder:$file:")" </dev/null 1>"$stdout" 2>"$stderr"; then
					log 2 "$rule_name: exited with error code, see logs for details"
					result=1
				fi

				if [ "$(stat -c %s "$stderr")" -ne 0 ]; then
					{
						printf "%s\n" "=== $rule_name: $(date '+%Y-%m-%d %H:%M:%S'): stderr ==="
						cat "$stderr"
					} >> "$logerr"

					log 2 "$rule_name: got data on stderr, see '$logerr' for details"
					head -n "$lines" "$stderr" >&2
					result=1
				fi

				if [ "$(stat -c %s "$stdout")" -ne 0 ]; then
					{
						printf "%s\n" "=== $rule_name: $(date '+%Y-%m-%d %H:%M:%S'): stdout ==="
						cat "$stdout"
					} >> "$logout"
				fi

				if [ -n "$opt_dryrun" ]; then
					log 1 "$rule_name: should backup with [interval=$option_interval][keep=$option_keep]"
				elif ! [ -r "$file" ]; then
					log 2 "$rule_name: command didn't create backup file '$file'"
					result=1
				elif ! chmod -- "$filemode" "$file"; then
					log 2 "$rule_name: couldn't change mode of backup file '$file'"
				else
					log 1 "$rule_name: new backup file saved as '$file'"
				fi
			fi

			# Prepare next command
			option_interval="$next_option_interval"
			option_keep="$next_option_keep"
			rule_command="$next_rule_command"
			rule_name="$next_rule_name"
		done
	}
done

log 0 'all done'

# Cleanup temporary files
rm -f "$stderr" "$stdout"

exit "$result"