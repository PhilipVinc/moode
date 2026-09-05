#!/bin/bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2014 The moOde audio player project / Tim Curtis
#
# Qobuz Connect (qbzd) event hook. qbzd forks this script once per daemon
# event with the event described in QBZ_* environment variables (set via
# QBZD_HOOK, see startQobuz() in inc/renderer.php).
#

LOGFILE="/var/log/moode_qbzevent.log"
DEBUG=$(sudo moodeutl -d -gv debuglog)
SQLDB=/var/local/www/db/moode-sqlite3.db

QBZMETA_CACHE_FILE="/var/local/www/qbzmeta.json"
QBZD_API="http://127.0.0.1:8182"
# Budget for retrying a start that failed because the audio device was still
# busy (e.g. shairport-sync releasing it late). qbzd does not retry on its own.
RETRY_FILE="/tmp/qbzevent-retry-budget"
RETRY_BUDGET=5

debug_log () {
	if [[ $DEBUG == '0' ]]; then
		return 0
	fi
	echo "$1"
	TIME=$(date +'%Y%m%d %H%M%S')
	echo "$TIME $1" >> $LOGFILE
}

PLAYER_EVENTS=(
PlaybackStateChanged
TrackStarted
QconnectSessionChanged
PlaybackError
)

MATCH=0
for MATCH_EVENT in "${PLAYER_EVENTS[@]}"
do
	if [[ $QBZ_EVENT == $MATCH_EVENT ]]; then
		MATCH=1
		# The state and session flag are what a bug report needs: which event
		# arrived, in what order, and what it said.
		debug_log "Process: $QBZ_EVENT state=$QBZ_STATE session=$QBZ_SESSION_ACTIVE"
	fi
done
# Exit and log if not a match
if [[ $MATCH == 0 ]]; then
	debug_log "Logged:  "$QBZ_EVENT
	exit 0
fi

# qbzd forks this script once per event without waiting so invocations can
# overlap: serialize them (and their cfg_system updates) to preserve ordering
exec 9> /tmp/qbzevent.lock
flock 9

# cfg_system (rows come back in id order)
RESULT=$(sqlite3 -cmd '.timeout 5000' $SQLDB "SELECT value FROM cfg_system WHERE param IN ('alsavolume_max','alsavolume','amixname','camilladsp_volume_sync','inpactive','multiroom_tx','rsmafterqbz','qbzactive') ORDER BY id")
readarray -t arr <<<"$RESULT"
ALSAVOLUME_MAX=${arr[0]}
ALSAVOLUME=${arr[1]}
AMIXNAME=${arr[2]}
CDSP_VOLSYNC=${arr[3]}
INPACTIVE=${arr[4]}
MULTIROOM_TX=${arr[5]}
RSMAFTERQBZ=${arr[6]}
QBZACTIVE=${arr[7]}
RX_ADDRESSES=$(sudo moodeutl -d -gv rx_addresses)

if [[ $INPACTIVE == '1' ]]; then
	exit 1
fi

activate () {
	if [[ $QBZACTIVE == '1' ]]; then
		return 0
	fi
	QBZACTIVE='1'
	$(sqlite3 -cmd '.timeout 5000' $SQLDB "UPDATE cfg_system SET value='1' WHERE param='qbzactive'")
	# Take over the audio device
	/usr/bin/mpc stop > /dev/null
	# Send to front-end
	/var/www/util/send-fecmd.php "qbzactive1"
	# Arm the failed-start retry budget, but never replenish it here: a retry
	# goes through loading (re-activation) again and would otherwise reset its
	# own budget. Only a real start (TrackStarted) replenishes.
	if [[ ! -f $RETRY_FILE ]]; then
		echo $RETRY_BUDGET > $RETRY_FILE
	fi

	# Local
	if [[ $CDSP_VOLSYNC == "on" ]]; then
		# Set 0dB CDSP volume
		sed -i '0,/- -.*/s//- 0.0/' /var/lib/cdsp/statefile.yml
	elif [[ $ALSAVOLUME != "none" ]]; then
		# Set 0dB ALSA volume
		/var/www/util/sysutil.sh set-alsavol "$AMIXNAME" $ALSAVOLUME_MAX
	fi

	# Multiroom receivers
	if [[ $MULTIROOM_TX == "On" ]]; then
		for IP_ADDR in $RX_ADDRESSES; do
			RESULT=$(curl -G -S -s --data-urlencode "cmd=trx_control -set-alsavol" http://$IP_ADDR/command/)
			if [[ $RESULT != "" ]]; then
				RESULT=$(curl -G -S -s --data-urlencode "cmd=trx_control -set-alsavol" http://$IP_ADDR/command/)
				if [[ $RESULT != "" ]]; then
					echo $(date +%F" "%T) "Event: trx_control -set-alsavol failed: $IP_ADDR" >> $LOGFILE
				fi
			fi
		done
	fi
}

# True while qbzd still owns playback: playing, or paused with a live Connect
# session (the session keeps the audio device across a pause, AirPlay parity).
# Fail-safe: an unreachable control API answers "not active" so a dead daemon
# always releases the UI.
still_active () {
	local STATE
	# renders_here, not session_active: the latter only says the daemon holds a
	# cloud connection, which stays true when the Qobuz app moves playback to
	# its own speakers -- so the overlay used to sit there owning the screen
	# while this player was silent and no longer the session's renderer
	# (reported by Tim Curtis). `// true` keeps an older daemon, which does not
	# report the field, behaving exactly as before.
	STATE=$(curl -s --max-time 2 $QBZD_API/api/status | \
		jq -r '"\(.playback.state) \(.qconnect.session_active) \(.qconnect.renders_here // true)"' 2>/dev/null)
	case "$STATE" in
		"playing true true"|"paused true true") return 0 ;;
		*) return 1 ;;
	esac
}

deactivate () {
	if [[ $QBZACTIVE == '0' ]]; then
		return 0
	fi
	# Verify against the daemon before tearing the render down. Transient
	# stopped/error events fire during normal operation — a gapless track
	# transition, a superseded stream being abandoned on track change — and
	# acting on them dropped the overlay mid-playback, so every later UI
	# rebuild (click, resize, page load) showed the library panel instead.
	debug_log "Deact?:  from $QBZ_EVENT (state=$QBZ_STATE session_active=$QBZ_SESSION_ACTIVE)"
	if still_active; then
		debug_log "Keep:    render (daemon still active)"
		return 0
	fi
	QBZACTIVE='0'
	# Worker picks this up and sends qbzactive0 to front-end
	$(sqlite3 -cmd '.timeout 5000' $SQLDB "UPDATE cfg_system SET value='0' WHERE param='qbzactive'")
	# NOTE: the retry budget survives deactivation on purpose. A failed start
	# arrives as loading -> paused -> PlaybackError, so the budget must still
	# be there when the PlaybackError event is processed after the pause.

	# Local
	/var/www/util/vol.sh -restore

	if [[ $CDSP_VOLSYNC == "on" ]]; then
		# Restore CDSP volume
		systemctl restart mpd2cdspvolume
	fi

	# Multiroom receivers
	if [[ $MULTIROOM_TX == "On" ]]; then
		for IP_ADDR in $RX_ADDRESSES; do
			RESULT=$(curl -G -S -s --data-urlencode "cmd=set_volume -restore" http://$IP_ADDR/command/)
			if [[ $RESULT != "" ]]; then
				RESULT=$(curl -G -S -s --data-urlencode "cmd=set_volume -restore" http://$IP_ADDR/command/)
				if [[ $RESULT != "" ]]; then
					echo $(date +%F" "%T) "Event: set_volume -restore failed: $IP_ADDR" >> $LOGFILE
				fi
			fi
		done
	fi
}

if [[ $QBZ_EVENT == "PlaybackStateChanged" ]]; then
	if [[ $QBZ_STATE == "playing" || $QBZ_STATE == "loading" ]]; then
		# Take the card BEFORE activate(), which returns early when the render
		# is already marked active and so never reaches its own mpc stop. That
		# early return is why casting while the radio played did nothing: the
		# session was still active from a previous cast, MPD kept the device,
		# and qbzd's open failed ~1s later with the card busy.
		if [[ -n $(/usr/bin/mpc status | grep playing) ]]; then
			debug_log "Takeover: stopping MPD for an incoming $QBZ_STATE"
			/usr/bin/mpc stop > /dev/null
		fi
		activate
	elif [[ $QBZ_STATE == "stopped" ]]; then
		deactivate
	fi
	# NOTE: paused KEEPS the render (AirPlay/Spotify parity — their flags are
	# session-scoped). The session still owns the audio device while paused,
	# and any renderUI rebuild (page load, window resize) reads qbzactive from
	# cfg_system — deactivating on pause made the overlay vanish on reload or
	# resize whenever playback happened to be paused.
fi

if [[ $QBZ_EVENT == "QconnectSessionChanged" ]]; then
	if [[ $QBZ_SESSION_ACTIVE == "true" ]]; then
		# Free the card as soon as the app SELECTS this player, not when it
		# starts playing. spotevent.sh does exactly this on session_connected,
		# and it is why Spotify takes over cleanly while we did not: MPD keeps
		# the ALSA device for several seconds after `mpc stop`, and stopping it
		# at the same instant qbzd opens leaves the open racing a release that
		# has not happened yet. Selecting the device happens seconds earlier.
		if [[ -n $(/usr/bin/mpc status | grep playing) ]]; then
			debug_log "Takeover: stopping MPD, the app selected this player"
			/usr/bin/mpc stop > /dev/null
		fi
	fi
	if [[ $QBZ_SESSION_ACTIVE == "false" ]]; then
		WAS_ACTIVE=$QBZACTIVE
		deactivate
		# Session gone: no more start attempts to retry
		rm -f $RETRY_FILE
		if [[ $WAS_ACTIVE == '1' && $RSMAFTERQBZ == "Yes" ]]; then
			/usr/bin/mpc play > /dev/null
		fi
	fi
fi

# A start attempt can fail because the audio device is still busy: retry
if [[ $QBZ_EVENT == "PlaybackError" ]]; then
	debug_log "Error:   "$QBZ_MESSAGE
	# Arm the budget here too. A cast that fails on its very first open never
	# went through a loading event, so activate() never ran and there is no
	# budget file yet — which used to mean zero retries for exactly the case
	# that needs them.
	if [[ ! -f $RETRY_FILE ]]; then
		echo $RETRY_BUDGET > $RETRY_FILE
	fi
	RETRIES_LEFT=$(cat $RETRY_FILE 2> /dev/null || echo 0)
	if [[ -n $(/usr/bin/mpc status | grep playing) ]]; then
		# MPD holds the card, so qbzd cannot open _audioout: its ALSA layer
		# retries for about 1.5s and gives up. This used to end the attempt --
		# the renderer stayed silent while the radio played on, which is the
		# "Qobuz will not start while moOde is playing" report.
		#
		# Take the device instead. Casting is a newer user action than whatever
		# was already playing, and moOde's renderers are last-one-wins: the
		# reverse direction is already handled in worker.php, which pauses Qobuz
		# when MPD starts underneath it.
		debug_log "Takeover: stopping MPD so the cast can have the device"
		/usr/bin/mpc stop > /dev/null
		sleep 1
	fi
	if [[ $RETRIES_LEFT -gt 0 ]]; then
		echo $((RETRIES_LEFT - 1)) > $RETRY_FILE
		sleep 1
		qbzd play -q
	else
		# Out of retries: since paused no longer deactivates, release the render
		# here or a failed start would leave the UI locked on a silent session.
		deactivate
	fi
fi

# Build the metadata frame and send it to the front-end.
#
# Two values describe the audio, and they come from different places on
# purpose (moOde 10.3.3 renderer contract):
#   - sformat, the SOURCE format, is supplied by the renderer daemon. Only
#     qbzd knows what it is streaming from Qobuz.
#   - oformat, the OUTPUT format, is moOde's to determine: get-oformat.php
#     reads the card's hw_params. Asking qbzd for it would report what the
#     daemon believes it opened, not what the hardware actually runs at, and
#     it would miss everything moOde's own chain does downstream.
#
# $1 = playstate ("Resume" or "Pause")
send_metadata () {
	local PLAYSTATE=$1
	local OFORMAT
	OFORMAT=$(/var/www/util/get-oformat.php)
	METADATA_JSON=$(jq -n -c \
		--arg a "update_qbzmeta" \
		--arg b "$TITLE" \
		--arg c "$ARTIST" \
		--arg d "$ALBUM" \
		--arg e "$DURATION" \
		--arg f "$COVER_URL" \
		--arg g "$SFORMAT" \
		--arg h "$OFORMAT" \
		--arg i "$PLAYSTATE" \
		--arg j "$TRACK_ID" \
		'{fecmd: $a, title: $b, artist: $c, album: $d, duration: $e, cover_url: $f, sformat: $g, oformat: $h, playstate: $i, track_id: $j}')
	echo -e "$METADATA_JSON" > $QBZMETA_CACHE_FILE
	debug_log "Meta:    playstate=$PLAYSTATE sformat=$SFORMAT oformat=$OFORMAT"
	/var/www/util/send-fecmd.php "$METADATA_JSON"
}

# Repopulate the metadata fields from the cache written by the last
# TrackStarted, so a playstate change can re-send the frame without the track
# details the event itself does not carry. Fails (returns 1) when there is no
# usable cache yet.
load_cached_metadata () {
	if [[ ! -s $QBZMETA_CACHE_FILE ]]; then
		return 1
	fi
	local KEY VALUE
	while IFS== read -r KEY VALUE; do
		case "$KEY" in
			title) TITLE=$VALUE ;;
			artist) ARTIST=$VALUE ;;
			album) ALBUM=$VALUE ;;
			duration) DURATION=$VALUE ;;
			cover_url) COVER_URL=$VALUE ;;
			sformat) SFORMAT=$VALUE ;;
			track_id) TRACK_ID=$VALUE ;;
		esac
	done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' $QBZMETA_CACHE_FILE 2> /dev/null)
	# An empty cover means the cache was written before a track was resolved;
	# re-sending it would blank the overlay (spotevent.sh guards the same way).
	if [[ -z $COVER_URL ]]; then
		return 1
	fi
	# Nor re-send a frame for a track the daemon has already moved off. Picking
	# a new track fires PlaybackStateChanged BEFORE TrackStarted, so a cache
	# written for the previous track put ITS cover on screen for a moment and
	# then swapped -- the artwork flash slowfret reported. When the ids disagree
	# there is nothing worth showing yet; the imminent TrackStarted carries the
	# real frame. An older daemon reports no track id, and then this is skipped.
	local LIVE_TRACK_ID
	LIVE_TRACK_ID=$(curl -s --max-time 2 $QBZD_API/api/status | \
		jq -r '.playback.track_id // empty' 2>/dev/null)
	if [[ -n $TRACK_ID && -n $LIVE_TRACK_ID && $TRACK_ID != $LIVE_TRACK_ID ]]; then
		debug_log "Stale:   cached track $TRACK_ID, daemon plays $LIVE_TRACK_ID"
		return 1
	fi
	return 0
}

# Update metadata and send to front-end
if [[ $QBZ_EVENT == "TrackStarted" ]]; then
	activate
	# Playback started: replenish the failed-start retry budget
	echo $RETRY_BUDGET > $RETRY_FILE
	TITLE=$QBZ_TITLE
	ARTIST=$QBZ_ARTIST
	ALBUM=$QBZ_ALBUM
	DURATION=$QBZ_DURATION
	COVER_URL=$QBZ_COVER_URL
	TRACK_ID=$QBZ_TRACK_ID
	SFORMAT="FLAC $QBZ_BIT_DEPTH/$QBZ_SAMPLE_RATE kHz"
	send_metadata "Resume"
fi

# Playstate: drives the now-playing icon and the "Not playing" output format
# on the renderer overlay. The track details come from the cache — the state
# change itself carries none.
if [[ $QBZ_EVENT == "PlaybackStateChanged" ]]; then
	if [[ $QBZ_STATE == "playing" ]]; then
		PLAYSTATE="Resume"
	elif [[ $QBZ_STATE == "paused" ]]; then
		PLAYSTATE="Pause"
	else
		PLAYSTATE=""
	fi
	if [[ -n $PLAYSTATE ]] && load_cached_metadata; then
		send_metadata "$PLAYSTATE"
	fi
fi
