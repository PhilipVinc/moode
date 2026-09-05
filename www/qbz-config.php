<?php
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2014 The moOde audio player project / Tim Curtis
*/

require_once __DIR__ . '/inc/common.php';
require_once __DIR__ . '/inc/renderer.php';
require_once __DIR__ . '/inc/session.php';
require_once __DIR__ . '/inc/sql.php';

$dbh = sqlConnect();
phpSession('open');

if (isset($_POST['save']) && $_POST['save'] == '1') {
	foreach ($_POST['config'] as $key => $value) {
		chkValue($key, $value);
		sqlUpdate('cfg_qobuz', $dbh, $key, $value);
	}
	$notify = $_SESSION['qobuzsvc'] == '1' ?
		array('title' => NOTIFY_TITLE_INFO, 'msg' => NAME_QOBUZ . NOTIFY_MSG_SVC_RESTARTED) :
		array('title' => '', 'msg' => '');
	submitJob('qobuzsvc', '', $notify['title'], $notify['msg']);
}

phpSession('close');

$result = sqlRead('cfg_qobuz', $dbh);
$cfgQobuz = array();

foreach ($result as $row) {
	$cfgQobuz[$row['param']] = $row['value'];
}
// Self-heal a cfg_qobuz that predates a param: without the row, the generic
// UPDATE in the save handler would silently no-op.
$qobuzDefaults = array('buffer_seconds' => '2', 'volume_mode' => 'auto',
	'stream_first' => 'Yes', 'track_cache' => 'Yes', 'quality_fallback' => 'fallback',
	'memory_cache_mb' => 'auto', 'alsa_buffer_ms' => 'auto', 'initial_volume' => 'off',
	'track_caching' => (@file('/proc/meminfo') && preg_match('/^MemTotal:\s+(\d+) kB/m', file_get_contents('/proc/meminfo'), $mt) && (int)$mt[1] >= 1900 * 1024) ? 'memory' : 'disk');
foreach ($qobuzDefaults as $param => $default) {
	if (!isset($cfgQobuz[$param])) {
		sqlInsert('cfg_qobuz', $dbh, "'" . $param . "', '" . $default . "'");
		$cfgQobuz[$param] = $default;
	}
}

// Where Qobuz audio goes. There is nothing to configure here any more -- the
// renderer outputs to moOde's own _audioout (or btstream) and therefore follows
// Audio Config like MPD does -- but "it follows Audio Config" is not much use
// without saying what Audio Config currently amounts to, so spell it out.

// qobuzSess() (inc/renderer.php) rather than $_SESSION directly: not every DSP
// flag exists as a cfg_system row on every release, and an undefined -- or
// empty -- key compared against 'Off' reads as ON, which would report a stage
// that is not even installed.
$audioOut = qobuzSess('audioout', 'Local');
$_qobuz_output_chain = 'moOde audio chain (' . ($audioOut == 'Local' ? '_audioout' : 'btstream') . ')';

$qobuzChainStages = array();
if ($audioOut != 'Local') {
	$qobuzChainStages[] = 'Bluetooth output';
} else if (qobuzSess('multiroom_tx', 'Off') == 'On') {
	$qobuzChainStages[] = 'Multiroom sender';
}
if (qobuzSess('camilladsp', 'off') != 'off') {
	$qobuzChainStages[] = 'CamillaDSP';
}
if (qobuzSess('alsaequal', 'Off') != 'Off') {
	$qobuzChainStages[] = 'Graphic EQ';
}
if (qobuzSess('eqfa12p', 'Off') != 'Off') {
	$qobuzChainStages[] = 'Parametric EQ';
}
if (qobuzSess('crossfeed', 'Off') != 'Off') {
	$qobuzChainStages[] = 'Crossfeed';
}
if (qobuzSess('invert_polarity', '0') != '0') {
	$qobuzChainStages[] = 'Polarity inversion';
}
if (qobuzSess('peppy_display', '0') == '1' || qobuzSess('enable_peppyalsa', '0') == '1') {
	$qobuzChainStages[] = 'PeppyALSA';
}

// An unknown output mode must NOT read as Direct.
$alsaOutputMode = qobuzSess('alsa_output_mode', 'plughw');
$alsaOutputModeName = isset(ALSA_OUTPUT_MODE_NAME[$alsaOutputMode]) ?
	ALSA_OUTPUT_MODE_NAME[$alsaOutputMode] : $alsaOutputMode;
if (!empty($qobuzChainStages)) {
	$_qobuz_output_detail = 'Through ' . implode(', ', $qobuzChainStages) .
		', so tracks are converted to that chain\'s rate';
} else if ($alsaOutputMode == 'hw') {
	$_qobuz_output_detail = 'Nothing in the chain and Output mode is Direct, so tracks reach ' .
		'the DAC at their own rate';
} else {
	$_qobuz_output_detail = 'Nothing in the chain, but Audio Config &gt; ALSA options &gt; ' .
		'Output mode is ' . $alsaOutputModeName . '; set it to Direct for bit-perfect playback';
}

// Hardware volume needs a DAC that has a volume control. It no longer needs
// anything of the routing: the mixer card is named separately now
// (audio.alsa_mixer_device), so it works through _audioout like everything else.
$hwVolumeReason = '';
if ($audioOut != 'Local') {
	$hwVolumeReason = 'n/a &mdash; audio output is Bluetooth';
} else if (qobuzSess('alsavolume', 'none') == 'none') {
	$hwVolumeReason = 'n/a &mdash; this DAC has no hardware volume control';
}

$_select['quality'] .= "<option value=\"mp3\" " . (($cfgQobuz['quality'] == 'mp3') ? "selected" : "") . ">MP3 320 kbps</option>\n";
$_select['quality'] .= "<option value=\"cd\" " . (($cfgQobuz['quality'] == 'cd') ? "selected" : "") . ">CD 16 bit / 44.1 kHz</option>\n";
$_select['quality'] .= "<option value=\"hires\" " . (($cfgQobuz['quality'] == 'hires') ? "selected" : "") . ">Hi-Res 24 bit / 96 kHz</option>\n";
$_select['quality'] .= "<option value=\"hires_plus\" " . (($cfgQobuz['quality'] == 'hires_plus') ? "selected" : "") . ">Hi-Res 24 bit / 192 kHz (Default)</option>\n";
// Track caching, gapless and card wear are one decision, so they are one
// control. Caching is what makes gapless possible at all (the next track has to
// be ready before the current one ends), and the only real question is where
// those bytes live.
//
// "In memory" is offered only where there is room for the CURRENT and NEXT
// track at once -- a Hi-Res pair is around 450 MB, and holding two whole tracks
// is exactly what took a 1 GB player into swap. Below the threshold the option
// is not rendered at all; the help text says who gets it, so its absence reads
// as "not for this player" rather than as a missing feature.
$memTotalKb = 0;
if (is_readable('/proc/meminfo') && preg_match('/^MemTotal:\s+(\d+) kB/m', file_get_contents('/proc/meminfo'), $m)) {
	$memTotalKb = (int)$m[1];
}
// 2 GB nominal: a board sold as 2 GB reports ~1.94 GiB, so test below the round number.
$_memory_caching_offered = $memTotalKb >= 1900 * 1024;

// The default follows the player: memory where there is room, card otherwise.
if ($_memory_caching_offered) {
	$qobuzCaching = array('memory' => 'In memory, nothing written to the card (Default)',
		'disk' => 'On the SD card');
} else {
	$qobuzCaching = array('disk' => 'On the SD card (Default)');
}
$qobuzCaching['off'] = 'Off, stream only (no gapless)';
foreach ($qobuzCaching as $value => $label) {
	$_select['track_caching'] .= "<option value=\"" . $value . "\" " .
		(($cfgQobuz['track_caching'] == $value) ? "selected" : "") . ">" . $label . "</option>\n";
}
$_select['normalize_volume'] .= "<option value=\"Yes\" " . (($cfgQobuz['normalize_volume'] == 'Yes') ? "selected" : "") . ">Yes</option>\n";
$_select['normalize_volume'] .= "<option value=\"No\" "  . (($cfgQobuz['normalize_volume'] == 'No')  ? "selected" : "") . ">No (Default)</option>\n";
foreach (array('2' => '2 seconds (Default)', '5' => '5 seconds', '10' => '10 seconds') as $secs => $label) {
	$_select['buffer_seconds'] .= "<option value=\"" . $secs . "\" " .
		(($cfgQobuz['buffer_seconds'] == $secs) ? "selected" : "") . ">" . $label . "</option>\n";
}

$_select['volume_mode'] .= "<option value=\"auto\" " . (($cfgQobuz['volume_mode'] == 'auto') ? "selected" : "") . ">Auto (Default)</option>\n";
$_select['volume_mode'] .= "<option value=\"hardware\" " . (($cfgQobuz['volume_mode'] == 'hardware') ? "selected" : "") .
	($hwVolumeReason == '' ? "" : " disabled") . ">DAC hardware volume" .
	($hwVolumeReason == '' ? "" : " (" . $hwVolumeReason . ")") . "</option>\n";
$_select['volume_mode'] .= "<option value=\"software\" " . (($cfgQobuz['volume_mode'] == 'software') ? "selected" : "") . ">Software</option>\n";
$_select['volume_mode'] .= "<option value=\"locked\" "   . (($cfgQobuz['volume_mode'] == 'locked')   ? "selected" : "") . ">Locked at 100%</option>\n";

// ALSA buffer length for the bit-perfect direct path. The default is sized
// for a desktop; a Pi streaming hi-res over WiFi to a USB DAC has to survive
// network jitter, an SD card and a shared USB bus on a quarter of a second of
// slack, and an underrun there is an audible click. Raising it costs a few MB
// and latency nobody listening to a renderer can perceive.
$qobuzBufferLengths = array('auto' => 'Auto, from the track\'s sample rate (Default)',
	'250' => '250 ms', '500' => '500 ms', '1000' => '1 second',
	'2000' => '2 seconds (most tolerant)');
foreach ($qobuzBufferLengths as $value => $label) {
	$_select['alsa_buffer_ms'] .= "<option value=\"" . $value . "\" " .
		(($cfgQobuz['alsa_buffer_ms'] == $value) ? "selected" : "") . ">" . $label . "</option>\n";
}

// Volume to set on ourselves when a Qobuz app picks this player. A controller
// that has never spoken to this renderer sends its own volume, which for the
// iOS app is near 100 % — startling on a system with no volume control after
// moOde. "Off" is AirPlay's behaviour: whatever the app asks for.
$qobuzInitialVolumes = array('off' => 'Whatever the app asks for (Default)');
foreach (array(10, 20, 30, 40, 50, 60, 70, 80, 90, 100) as $pct) {
	$qobuzInitialVolumes[(string)$pct] = $pct . '%';
}
foreach ($qobuzInitialVolumes as $value => $label) {
	$_select['initial_volume'] .= "<option value=\"" . $value . "\" " .
		(($cfgQobuz['initial_volume'] == $value) ? "selected" : "") . ">" . $label . "</option>\n";
}

$_select['stream_first'] .= "<option value=\"Yes\" " . (($cfgQobuz['stream_first'] == 'Yes') ? "selected" : "") . ">As soon as buffered (Default)</option>\n";
$_select['stream_first'] .= "<option value=\"No\" "  . (($cfgQobuz['stream_first'] == 'No')  ? "selected" : "") . ">After the full track downloads</option>\n";

$_select['track_cache'] .= "<option value=\"Yes\" " . (($cfgQobuz['track_cache'] == 'Yes') ? "selected" : "") . ">Cache tracks on disk (Default)</option>\n";
$_select['track_cache'] .= "<option value=\"No\" "  . (($cfgQobuz['track_cache'] == 'No')  ? "selected" : "") . ">Stream only, do not cache</option>\n";

$_select['quality_fallback'] .= "<option value=\"fallback\" " . (($cfgQobuz['quality_fallback'] == 'fallback') ? "selected" : "") . ">Play at a lower quality (Default)</option>\n";
$_select['quality_fallback'] .= "<option value=\"skip\" "     . (($cfgQobuz['quality_fallback'] == 'skip')     ? "selected" : "") . ">Skip the track</option>\n";

waitWorker('qbz_config');

$tpl = "qbz-config.html";
$section = basename(__FILE__, '.php');
storeBackLink($section, $tpl);

include('header.php');
eval("echoTemplate(\"" . getTemplate("templates/$tpl") . "\");");
include('footer.php');
