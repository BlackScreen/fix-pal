#!/bin/bash

#
# Slow down a Matroska-contained movie to correct for PAL speedup.
#
# usage: $SCRIPT_NAME <infile> <outfile>
#

# If interrupted with CTRL+C, do cleanup
trap cleanup INT

# Define the usage string
USAGE="usage: $0 <infile> <outfile>"

# Enter and calculate the correction factor
CORRECTION_FACTOR="25025/24000"
audio_factor=`bc -l <<< "1/($CORRECTION_FACTOR)"`

# Select language to keep (audio and subtitle tracks) in the output file
# Example: "eng" for only english tracks, "" for all tracks from the source file
LANGUAGE_SELECTION="eng"

# FUNCTION: Clean up the temp directory
function cleanup {
	echo "Cleaning up temp files..."
	rm -rf "${tmpdir}" # Thanks to James Ainslie
}

# FUNCTION: If a given file already exists, ask for confirmation before proceeding.
function confirm_overwrite {
	local file="$1"
	if [ -e "$file" ]; then
		read -p "Output file \`${outfile}\` already exists.
Do you want to overwrite it? [y|N] " yn
		case $yn in
			[Yy]* ) ;;
			* ) exit ;;
		esac
	fi
}

# FUNCTION: Read an arbitrary track file, and produce a new one with timings slowed down.
# This function modified slightly from code by James Ainslie from
# <https://blog.delx.net.au/2016/05/fixing-pal-speedup-and-how-film-and-video-work/comment-page-1/#comment-100160>
function edit_timings {
	local old_track_file="$1"
	local new_track_file="$2"
	local factor="$3"
	local search='[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}.[0-9]\{3\}'
	touch "$new_track_file"
	while IFS= read -r line || [[ -n $line ]]; do
		local timestamp=$(echo $line | grep -o $search | cat)
		if [ "$timestamp" ]; then
			local old_time=$timestamp
			local hrs=$(echo $old_time | cut -f1 -d:)
			local mins=$(echo $old_time | cut -f2 -d:)
			local secs=$(echo $old_time | cut -f3 -d: | cut -f1 -d.)
			local ms=$(echo $old_time | cut -f3 -d: | cut -f2 -d.)
			local old_ms=$(echo $hrs \* 3600000 + $mins \* 60000 + $secs \* 1000 + $ms | bc)
			local new_ms=$(echo $old_ms \* $factor | bc)
			printf -v hh "%02d" $(echo $new_ms / 3600000 | bc)
			printf -v mm "%02d" $(echo $new_ms % 3600000 / 60000 | bc)
			printf -v ss "%02d" $(echo $new_ms % 60000 / 1000 | bc)
			printf -v ms "%03d" $(echo $new_ms % 1000 | bc)
			local new_time="${hh}:${mm}:${ss}.${ms}"
			local line=$(echo "$line" | sed "s/${search}/${new_time}/g")
		fi
		echo "$line" >> "$new_track_file"
	done < "$old_track_file"
}

# FUNCTION: Pull out the chapter data, then generate a new chapter file with re-timed
# chapters. This function modified slightly from code by James Ainslie from
# <https://blog.delx.net.au/2016/05/fixing-pal-speedup-and-how-film-and-video-work/comment-page-1/#comment-100160>
function fix_chapters {
	echo "Adjusting chapters..."
	if mkvmerge -i "${infile}" | grep --quiet Chapters ; then
		old_chapter_file="${tmpdir}/oldChapters.xml"
		new_chapter_file="${tmpdir}/newChapters.xml"
		mkvextract "$infile" chapters "$old_chapter_file"
		edit_timings "$old_chapter_file" "$new_chapter_file" $CORRECTION_FACTOR
		chapter_string="--chapters ${new_chapter_file}"
	else
		echo "No chapters found."
		chapter_string=""
	fi
}

# FUNCTION: Get all tracks that AREN'T AUDIO (e.g. video and subtitle tracks), then build
# the `--sync` string for a subsequent `mkvmerge` call.
function get_sync_flags {
	local file="$1"
	syncstring=''

	while IFS= read -r line || [[ -n $line ]]; do
		local match=$(echo $line | grep 'Track ID' | grep -v 'audio' | cat)
		if [ "$match" ]; then
			local track_id=$(echo $match | egrep -o -m1 "[0-9]*:" | cat)
			syncstring="$syncstring --sync ${track_id}0,${CORRECTION_FACTOR}"
		fi
	done <<<"$(mkvmerge -i "$file")"
}

# FUNCTION: Determine the sample rate for audio. If different tracks have different
# rates, chooses that of the first audio track.
function get_audio_sample_rate {
	local file="$1"
	sample_rates=$(mkvinfo "$file" | grep -m1 "Sampling frequency")
	audio_sample_rate=$(echo $sample_rates | egrep -o "[0-9]*\.[0-9]*")
}

# FUNCTION: Alter the audio sample rate. Copy video, subtitles, chapters exactly as they
# are in the temp file.
function fix_audio {
	get_audio_sample_rate "$infile"

	if [ $LANGUAGE_SELECTION != "" ]; then
		audio_check=$(ffprobe -select_streams a -show_entries stream=index,codec_type:stream_tags=language -of compact "$infile" -v quiet | grep $LANGUAGE_SELECTION)
		subtitle_check=$(ffprobe -select_streams s -show_entries stream=index,codec_type:stream_tags=language -of compact "$infile" -v quiet | grep $LANGUAGE_SELECTION)

		if [ -z "$audio_check" ]; then
        		audio_mapping=""
		else
        		audio_mapping="-map 0:a:m:language:$LANGUAGE_SELECTION"
		fi

		if [ -z "$subtitle_check" ]; then
        		subtitle_mapping=""
		else
        		subtitle_mapping="-map 0:s:m:language:$LANGUAGE_SELECTION"
		fi

		FFMPEG_MAPPING="-map 0:v $audio_mapping $subtitle_mapping"
	else
		FFMPEG_MAPPING="-map 0"
	fi

	ffmpeg -y -i "$tempfile" $FFMPEG_MAPPING \
	-filter:a "asetrate=${audio_sample_rate}*${audio_factor}" \
	-c:v copy -c:s copy -c:a libvorbis -q:a 6 -max_interleave_delta 0 "$outfile"
}

# Validate args
if [ $# == 1 ] && [ -d "$1" ]; then
	# Loop through files in folder
	for file in "$1"/*
	do
		# Source & dest files
		infile="$(echo $file)"
		outpath="$(dirname "${infile}")/Fixed"
		outname="$(basename "${infile}")"
		outfile="$(echo $outpath)/$(echo $outname)"
		tmpdir="$(mktemp -d "${TMPDIR:-/var/tmp}/pal-XXXXXXXX")" # Thanks to James Ainslie
		tempfile="${tmpdir}/temp.mkv"

		echo Input: "$infile"
		echo Output: "$outfile"
		echo

		# Create output directory, if it does not exist
		mkdir -p "$outpath"

		# Start processing of the source file
		confirm_overwrite "$outfile"
		fix_chapters
		get_sync_flags "$infile"

		# For each video track, adjust the framerate by the correction factor. (No
		# re-encoding necessary!) Adjust subtitle timings to match. Add the adjusted
		# chapters from the new chapter file. Write everything to a temp file.
		mkvmerge --output "$tempfile" $syncstring --no-chapters $chapter_string "$infile"

		fix_audio
		cleanup
	done
elif [ $# == 2 ] && [ -f "$1" ]; then
	# Source & dest files
	infile="$1"
	outfile="$2"
	tmpdir="$(mktemp -d "${TMPDIR:-/var/tmp}/pal-XXXXXXXX")" # Thanks to James Ainslie
	tempfile="${tmpdir}/temp.mkv"

	echo Input: "$infile"
	echo Output: "$outfile"
	echo

	# Start processing of the source file
	confirm_overwrite "$outfile"
	fix_chapters
	get_sync_flags "$infile"

	# For each video track, adjust the framerate by the correction factor. (No
	# re-encoding necessary!) Adjust subtitle timings to match. Add the adjusted
	# chapters from the new chapter file. Write everything to a temp file.
	mkvmerge --output "$tempfile" $syncstring --no-chapters $chapter_string "$infile"

	fix_audio
	cleanup
else
	echo ${USAGE}
	exit
fi
