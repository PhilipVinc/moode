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
	// Local pairing and a fixed account login are mutually exclusive in this
	// UI: turning pairing on drops the login (and any in-flight browser login)
	// so the renderer restart below comes up account-less. The single-slot job
	// queue is taken by the qobuzsvc restart, so log out synchronously here.
	if (isset($_POST['config']['pairing']) && $_POST['config']['pairing'] == 'Yes') {
		$prevPairing = sqlQuery("SELECT value FROM cfg_qobuz WHERE param='pairing'", $dbh);
		if (!empty($prevPairing[0]['value']) && $prevPairing[0]['value'] == 'No') {
			sysCmd('pkill -f qbzd-login 2> /dev/null');
			sysCmd('qbzd logout');
		}
	}
	foreach ($_POST['config'] as $key => $value) {
		chkValue($key, $value);
		sqlUpdate('cfg_qobuz', $dbh, $key, $value);
	}
	$notify = $_SESSION['qobuzsvc'] == '1' ?
		array('title' => NOTIFY_TITLE_INFO, 'msg' => NAME_QOBUZ . NOTIFY_MSG_SVC_RESTARTED) :
		array('title' => '', 'msg' => '');
	submitJob('qobuzsvc', '', $notify['title'], $notify['msg']);
}
if (isset($_POST['qobuz_login']) && $_POST['qobuz_login'] == '1') {
	// The button is disabled while pairing is on; guard the POST as well.
	$pairing = sqlQuery("SELECT value FROM cfg_qobuz WHERE param='pairing'", $dbh);
	if (empty($pairing[0]['value']) || $pairing[0]['value'] != 'Yes') {
		submitJob('qobuz_login', '', NOTIFY_TITLE_INFO, 'Login started, refresh this screen to view the login link');
	}
}
if (isset($_POST['qobuz_logout']) && $_POST['qobuz_logout'] == '1') {
	submitJob('qobuz_logout', '', NOTIFY_TITLE_INFO, 'Logged out from Qobuz');
}

phpSession('close');

$result = sqlRead('cfg_qobuz', $dbh);
$cfgQobuz = array();

foreach ($result as $row) {
	$cfgQobuz[$row['param']] = $row['value'];
}
// Self-heal a cfg_qobuz that predates a param: without the row, the generic
// UPDATE in the save handler would silently no-op.
$qobuzDefaults = array('pairing' => 'Yes', 'buffer_seconds' => '2', 'volume_mode' => 'auto',
	'stream_first' => 'Yes', 'track_cache' => 'Yes', 'quality_fallback' => 'fallback',
	'memory_cache_mb' => 'auto', 'alsa_buffer_ms' => 'auto', 'initial_volume' => 'off');
foreach ($qobuzDefaults as $param => $default) {
	if (!isset($cfgQobuz[$param])) {
		sqlInsert('cfg_qobuz', $dbh, "'" . $param . "', '" . $default . "'");
		$cfgQobuz[$param] = $default;
	}
}

// One control-API read for everything on this screen that needs the daemon.
$qbzStatus = array();
if ($_SESSION['qobuzsvc'] == '1') {
	$result = sysCmd('curl -s --max-time 2 http://127.0.0.1:8182/api/status');
	$decoded = json_decode(implode('', $result), true);
	if (is_array($decoded)) {
		$qbzStatus = $decoded;
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

// Local pairing supplies the account (the casting app hands over its own
// session), so the fixed-account Login is gated while it is on.
$_qobuz_login_disabled = '';
$_qobuz_login_hint = '';
if ($cfgQobuz['pairing'] == 'Yes') {
	$_qobuz_login_disabled = 'disabled';
	$_qobuz_login_hint = '<span class="config-help-static">No login needed: Local pairing is on, ' .
		'so the Qobuz app hands this player its own account when casting. ' .
		'To use a fixed account instead, set Local pairing to No and Save.</span>';
}

$_select['quality'] .= "<option value=\"mp3\" " . (($cfgQobuz['quality'] == 'mp3') ? "selected" : "") . ">MP3 320 kbps</option>\n";
$_select['quality'] .= "<option value=\"cd\" " . (($cfgQobuz['quality'] == 'cd') ? "selected" : "") . ">CD 16 bit / 44.1 kHz</option>\n";
$_select['quality'] .= "<option value=\"hires\" " . (($cfgQobuz['quality'] == 'hires') ? "selected" : "") . ">Hi-Res 24 bit / 96 kHz</option>\n";
$_select['quality'] .= "<option value=\"hires_plus\" " . (($cfgQobuz['quality'] == 'hires_plus') ? "selected" : "") . ">Hi-Res 24 bit / 192 kHz (Default)</option>\n";
$_select['pairing'] .= "<option value=\"Yes\" " . (($cfgQobuz['pairing'] == 'Yes') ? "selected" : "") . ">Yes (Default)</option>\n";
$_select['pairing'] .= "<option value=\"No\" "  . (($cfgQobuz['pairing'] == 'No')  ? "selected" : "") . ">No</option>\n";
// The gapless prefetch is a no-op in streaming-only mode, so with caching off
// gapless cannot happen at all. Lock the control and show the value actually in
// force rather than leaving a stored "Yes" on screen that does nothing. A
// disabled select posts nothing, so the stored preference survives untouched
// and comes back as soon as caching is turned on again.
$_gapless_disabled = $cfgQobuz['track_cache'] == 'Yes' ? '' : 'disabled';
$_gapless_hint = '';
if ($_gapless_disabled == '') {
	$_select['gapless'] .= "<option value=\"Yes\" " . (($cfgQobuz['gapless'] == 'Yes') ? "selected" : "") . ">Yes (Default)</option>\n";
	$_select['gapless'] .= "<option value=\"No\" "  . (($cfgQobuz['gapless'] == 'No')  ? "selected" : "") . ">No</option>\n";
} else {
	$_select['gapless'] .= "<option value=\"No\" selected>No</option>\n";
	$_gapless_hint = '<span class="config-help-static">Not available: Track cache is set to ' .
		'stream only, and gapless needs the next track cached ahead of time.</span>';
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

// In-memory track cache. "Auto" reads this box's RAM (17 %, capped at 400 MB):
// ~157 MB on a 1 GB Pi, ~338 MB on a 2 GB one. The explicit sizes exist for a
// Pi that is also doing something else. Below ~120 MB a Hi-Res track no longer
// fits in the cache and Hi-Res gapless stops working, so the small values say
// so rather than looking like free wins.
$qobuzCacheSizes = array('auto' => 'Auto, sized from this player\'s RAM (Default)',
	'400' => '400 MB', '300' => '300 MB', '200' => '200 MB',
	'150' => '150 MB', '100' => '100 MB (no Hi-Res gapless)',
	'50' => '50 MB (no Hi-Res gapless)');
foreach ($qobuzCacheSizes as $value => $label) {
	$_select['memory_cache_mb'] .= "<option value=\"" . $value . "\" " .
		(($cfgQobuz['memory_cache_mb'] == $value) ? "selected" : "") . ">" . $label . "</option>\n";
}

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

// Account: login status is read from the qbzd control API (only available when the service is on)
$_qobuz_login_hide = 'hide';
$_qobuz_logout_hide = 'hide';
$_qobuz_login_url_msg = '';
if ($_SESSION['qobuzsvc'] == '1') {
	$status = $qbzStatus;
	if (isset($status['auth']['state']) && $status['auth']['state'] != 'needs_auth') {
		$_qobuz_logout_hide = '';
		$_qobuz_account_status = 'Logged in' .
			(empty($status['auth']['subscription']) ? '' : ' (' . $status['auth']['subscription'] . ')');
	} else {
		$_qobuz_login_hide = '';
		$_qobuz_account_status = 'Not logged in';
		// A login in progress prints its URL to the login log
		$loginLog = file_exists(QOBUZ_LOGIN_LOG) ? file_get_contents(QOBUZ_LOGIN_LOG) : '';
		if (preg_match('#https?://\S+#', $loginLog, $matches) === 1) {
			$_qobuz_login_url_msg = '<span class="config-help-static">' .
				'<a class="target-blank-link" href="' . $matches[0] . '" target="_blank">' . $matches[0] . '</a><br>' .
				'Open this link in your browser to complete the Qobuz login, then refresh this screen.</span>';
		}
	}
} else {
	$_qobuz_account_status = 'Turn the renderer on in Renderer Config to log in.';
}

waitWorker('qbz_config');

$tpl = "qbz-config.html";
$section = basename(__FILE__, '.php');
storeBackLink($section, $tpl);

include('header.php');
eval("echoTemplate(\"" . getTemplate("templates/$tpl") . "\");");
include('footer.php');
